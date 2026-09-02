//
//  TerminalController+Callbacks.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

private enum TerminalCallbacks {
    static func wakeup(userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let controller = Unmanaged<TerminalController>.fromOpaque(userdata)
            .takeUnretainedValue()
        terminalRunOnMain {
            controller.handleWakeup()
        }
    }

    static func action(
        appPtr: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        guard let appPtr else { return false }
        guard ghostty_app_userdata(appPtr) != nil else { return false }
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        guard let surfacePtr = target.target.surface else { return false }
        guard let bridgePtr = ghostty_surface_userdata(surfacePtr) else { return false }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(bridgePtr)
            .takeUnretainedValue()
        guard Thread.isMainThread else {
            terminalRunOnMain { bridge.handleAction(action) }
            return false
        }
        return MainActor.assumeIsolated {
            bridge.handleAction(action)
            // Core spawns /usr/bin/open for an open_url reported unhandled,
            // so a host delegate that took the URL is reported as handling
            // it. Both open_url emitters run on the main thread.
            return action.tag == GHOSTTY_ACTION_OPEN_URL
                && bridge.delegate is any TerminalSurfaceOpenURLDelegate
        }
    }

    static func closeSurface(
        userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        guard let userdata else { return }
        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        terminalRunOnMain {
            bridge.handleClose(processAlive: processAlive)
        }
    }

    /// A program wrote the clipboard (OSC 52), or a copy binding did.
    ///
    /// `confirm` is ghostty's `clipboard-write = ask`: the write must not
    /// land until the host has asked. That goes through the same
    /// confirmation delegate as a protected read; a host without one denies
    /// it, as it does the read. The default configuration allows writes
    /// outright, and those land immediately.
    static func writeClipboard(
        userdata: UnsafeMutableRawPointer?,
        clipboard: ghostty_clipboard_e,
        contents: UnsafePointer<ghostty_clipboard_content_s>?,
        contentsLen: Int,
        confirm: Bool
    ) {
        // The selection clipboard is advertised (`supports_selection_clipboard`)
        // so that `copy-on-select` writes there and not to the one pasteboard
        // the user has — otherwise every drag, and every double-click a tap
        // lands within ghostty's click interval, would replace it. Nothing
        // exposes a primary selection, so those writes go nowhere.
        guard clipboard == GHOSTTY_CLIPBOARD_STANDARD else { return }
        guard contentsLen > 0, let contents else { return }
        let entries = UnsafeBufferPointer(start: contents, count: contentsLen)
        // Several representations may arrive together; the pasteboard here
        // only carries text, so the text/plain one wins, else the first.
        let chosen = entries.first { $0.mime.map { String(cString: $0) } == "text/plain" }
            ?? entries[0]
        guard let data = chosen.data else { return }
        let string = String(cString: data)
        TerminalDebugLog.log(
            .input,
            "clipboard write bytes=\(string.utf8.count) confirm=\(confirm)"
        )

        guard confirm else {
            terminalRunOnMain { setPasteboardString(string) }
            return
        }
        guard let userdata else { return }
        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        terminalRunOnMain {
            bridge.handleClipboardConfirmation(contents: string, kind: .osc52Write) { allowed in
                TerminalDebugLog.log(
                    .input,
                    allowed ? "clipboard write allowed" : "clipboard write denied"
                )
                guard allowed else { return }
                setPasteboardString(string)
            }
        }
    }

    @MainActor
    private static func setPasteboardString(_ string: String) {
        #if canImport(UIKit)
            UIPasteboard.general.string = string
        #elseif canImport(AppKit)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(string, forType: .string)
        #endif
    }

    static func readClipboard(
        userdata: UnsafeMutableRawPointer?,
        clipboard: ghostty_clipboard_e,
        opaquePtr: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let userdata, let opaquePtr else { return false }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard let surface = bridge.rawSurface else { return false }
        // Only the standard clipboard exists here: nothing exposes a
        // primary selection, so `paste_from_selection` has nothing to read.
        guard clipboard == GHOSTTY_CLIPBOARD_STANDARD else { return false }

        // Text and file URLs only. This also serves a program's OSC 52 read,
        // which must not write files as a side effect; a host paste that
        // finds image or document data materialises it itself
        // (`UITerminalView.pasteFromPasteboard`).
        guard let text = TerminalPasteboardContent.text() else {
            TerminalDebugLog.log(.input, "clipboard paste read empty")
            return false
        }
        completeClipboardRequest(surface, text: text, opaquePtr: opaquePtr, confirmed: false)
        return true
    }

    /// Hands ghostty the text a clipboard request resolved to (empty when
    /// the pasteboard had nothing, or the host denied it).
    private static func completeClipboardRequest(
        _ surface: ghostty_surface_t,
        text: String,
        opaquePtr: UnsafeMutableRawPointer,
        confirmed: Bool
    ) {
        TerminalDebugLog.log(
            .input,
            "clipboard request complete bytes=\(text.utf8.count) lines=\(TerminalInputText.lineCount(in: text)) confirmed=\(confirmed)"
        )
        text.withCString { cString in
            ghostty_surface_complete_clipboard_request(surface, cString, opaquePtr, confirmed)
        }
    }

    static func confirmReadClipboard(
        userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        opaquePtr: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let userdata, let string, let opaquePtr else { return }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        let text = String(cString: string)
        guard let kind = TerminalClipboardRequestKind(request) else { return }
        let requestState = UInt(bitPattern: opaquePtr)
        TerminalDebugLog.log(
            .input,
            "clipboard paste confirm request=\(request.rawValue) bytes=\(text.utf8.count) lines=\(TerminalInputText.lineCount(in: text))"
        )
        terminalRunOnMain {
            guard let surface = bridge.rawSurface else { return }
            guard let opaquePtr = UnsafeMutableRawPointer(bitPattern: requestState) else {
                return
            }
            bridge.handleClipboardConfirmation(
                contents: text,
                kind: kind
            ) { allowed in
                guard bridge.rawSurface == surface else { return }
                TerminalDebugLog.log(
                    .input,
                    allowed ? "clipboard request allowed" : "clipboard request denied"
                )
                completeClipboardRequest(surface, text: allowed ? text : "", opaquePtr: opaquePtr, confirmed: true)
            }
        }
    }
}

func terminalControllerWakeupCallback(userdata: UnsafeMutableRawPointer?) {
    TerminalCallbacks.wakeup(userdata: userdata)
}

func terminalControllerActionCallback(
    appPtr: ghostty_app_t?,
    target: ghostty_target_s,
    action: ghostty_action_s
) -> Bool {
    TerminalCallbacks.action(appPtr: appPtr, target: target, action: action)
}

func terminalControllerCloseSurfaceCallback(
    userdata: UnsafeMutableRawPointer?,
    processAlive: Bool
) {
    TerminalCallbacks.closeSurface(userdata: userdata, processAlive: processAlive)
}

func terminalControllerWriteClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    contents: UnsafePointer<ghostty_clipboard_content_s>?,
    contentsLen: Int,
    confirm: Bool
) {
    TerminalCallbacks.writeClipboard(
        userdata: userdata,
        clipboard: clipboard,
        contents: contents,
        contentsLen: contentsLen,
        confirm: confirm
    )
}

func terminalControllerReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    opaquePtr: UnsafeMutableRawPointer?
) -> Bool {
    TerminalCallbacks.readClipboard(
        userdata: userdata,
        clipboard: clipboard,
        opaquePtr: opaquePtr
    )
}

func terminalControllerConfirmReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    string: UnsafePointer<CChar>?,
    opaquePtr: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
) {
    TerminalCallbacks.confirmReadClipboard(
        userdata: userdata,
        string: string,
        opaquePtr: opaquePtr,
        request: request
    )
}
