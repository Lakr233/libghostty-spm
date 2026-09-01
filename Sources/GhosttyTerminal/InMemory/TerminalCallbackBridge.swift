//
//  TerminalCallbackBridge.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

/// Dispatches C runtime callbacks to a ``TerminalSurfaceViewDelegate``.
///
/// An instance of this class is passed as the `userdata` pointer in the
/// surface config so that Ghostty callbacks can route actions back to
/// the owning view.
@MainActor
final class TerminalCallbackBridge {
    weak var delegate: (any TerminalSurfaceViewDelegate)?
    /// Raw surface pointer for use in C callbacks (e.g. clipboard).
    nonisolated(unsafe) var rawSurface: ghostty_surface_t?
    var onCellSizeChange: ((UInt32, UInt32) -> Void)?
    var onRenderRequest: (() -> Void)?

    init(delegate: (any TerminalSurfaceViewDelegate)? = nil) {
        self.delegate = delegate
    }

    func handleAction(_ action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            if let cStr = action.action.set_title.title {
                let title = String(cString: cStr)
                TerminalDebugLog.log(
                    .actions,
                    "callback action=set_title title=\(TerminalDebugLog.describe(title))"
                )
                (delegate as? any TerminalSurfaceTitleDelegate)?
                    .terminalDidChangeTitle(title)
            }

        case GHOSTTY_ACTION_CELL_SIZE:
            let cellSize = action.action.cell_size
            TerminalDebugLog.log(
                .actions,
                "callback action=cell_size width=\(cellSize.width) height=\(cellSize.height)"
            )
            onCellSizeChange?(cellSize.width, cellSize.height)

        case GHOSTTY_ACTION_RING_BELL:
            TerminalDebugLog.log(.actions, "callback action=ring_bell")
            (delegate as? any TerminalSurfaceBellDelegate)?
                .terminalDidRingBell()

        case GHOSTTY_ACTION_RENDER:
            TerminalDebugLog.log(.render, "callback action=render")
            onRenderRequest?()

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            // Colors/theme may have changed (e.g. on system appearance
            // toggle). Ghostty applies the new config internally but won't
            // repaint until the next frame — request one so the refreshed
            // theme is visible without waiting for input or layout.
            TerminalDebugLog.log(.actions, "callback action=config_change")
            onRenderRequest?()

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let report = action.action.progress_report
            let state = TerminalProgressState(report.state) ?? .set
            // int8_t -1 signals "no progress provided" — surface as nil.
            let percent: Int? = report.progress < 0 ? nil : Int(report.progress)
            TerminalDebugLog.log(
                .actions,
                "callback action=progress_report state=\(state) percent=\(percent.map { "\($0)" } ?? "nil")"
            )
            (delegate as? any TerminalSurfaceProgressReportDelegate)?
                .terminalDidReportProgress(state: state, percent: percent)

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let finished = action.action.command_finished
            // int16_t -1 signals unknown exit code.
            let exit: Int? = finished.exit_code < 0 ? nil : Int(finished.exit_code)
            TerminalDebugLog.log(
                .actions,
                "callback action=command_finished exit=\(exit.map { "\($0)" } ?? "nil") duration_ns=\(finished.duration)"
            )
            (delegate as? any TerminalSurfaceCommandFinishedDelegate)?
                .terminalDidFinishCommand(
                    exitCode: exit,
                    durationNanos: finished.duration
                )

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let payload = action.action.desktop_notification
            let title = payload.title.map { String(cString: $0) } ?? ""
            let body = payload.body.map { String(cString: $0) } ?? ""
            TerminalDebugLog.log(
                .actions,
                "callback action=desktop_notification title=\(TerminalDebugLog.describe(title)) body=\(TerminalDebugLog.describe(body))"
            )
            (delegate as? any TerminalSurfaceDesktopNotificationDelegate)?
                .terminalDidRequestDesktopNotification(title: title, body: body)

        case GHOSTTY_ACTION_OPEN_URL:
            let payload = action.action.open_url
            let kind = TerminalOpenURLKind(payload.kind)
            let url: String = payload.url.map { ptr in
                // Ghostty provides a length-prefixed string; respect the
                // documented length rather than trusting a NUL terminator.
                let buf = UnsafeBufferPointer(start: ptr, count: Int(payload.len))
                return String(decoding: buf.map(UInt8.init), as: UTF8.self)
            } ?? ""
            TerminalDebugLog.log(
                .actions,
                "callback action=open_url kind=\(kind) url=\(TerminalDebugLog.describe(url))"
            )
            (delegate as? any TerminalSurfaceOpenURLDelegate)?
                .terminalDidRequestOpenURL(url, kind: kind)

        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            let payload = action.action.mouse_over_link
            let url: String? = {
                guard let ptr = payload.url, payload.len > 0 else { return nil }
                let buf = UnsafeBufferPointer(start: ptr, count: Int(payload.len))
                return String(decoding: buf.map(UInt8.init), as: UTF8.self)
            }()
            TerminalDebugLog.log(
                .actions,
                "callback action=mouse_over_link url=\(url.map { TerminalDebugLog.describe($0) } ?? "nil")"
            )
            (delegate as? any TerminalSurfaceHoverLinkDelegate)?
                .terminalDidUpdateHoverLink(url)

        case GHOSTTY_ACTION_PWD:
            let payload = action.action.pwd
            if let cStr = payload.pwd {
                let pwd = String(cString: cStr)
                TerminalDebugLog.log(
                    .actions,
                    "callback action=pwd pwd=\(TerminalDebugLog.describe(pwd))"
                )
                (delegate as? any TerminalSurfacePwdDelegate)?
                    .terminalDidChangeWorkingDirectory(pwd)
            }

        case GHOSTTY_ACTION_SCROLLBAR:
            let payload = action.action.scrollbar
            TerminalDebugLog.log(
                .actions,
                "callback action=scrollbar total=\(payload.total) offset=\(payload.offset) len=\(payload.len)"
            )
            (delegate as? any TerminalSurfaceScrollbarDelegate)?
                .terminalDidUpdateScrollbar(
                    TerminalScrollbar(
                        total: payload.total,
                        offset: payload.offset,
                        len: payload.len
                    )
                )

        default:
            TerminalDebugLog.log(
                .actions,
                "callback action=\(TerminalDebugLog.describe(action.tag))"
            )
        }
    }

    func handleClose(processAlive: Bool) {
        TerminalDebugLog.log(
            .lifecycle,
            "callback close processAlive=\(processAlive)"
        )
        (delegate as? any TerminalSurfaceCloseDelegate)?
            .terminalDidClose(processAlive: processAlive)
    }

    func handleClipboardConfirmation(
        contents: String,
        kind: TerminalClipboardRequestKind,
        completion: @escaping (Bool) -> Void
    ) {
        guard let delegate = delegate as? any TerminalSurfaceClipboardConfirmationDelegate else {
            completion(false)
            return
        }
        delegate.terminalDidRequestClipboardConfirmation(
            TerminalClipboardConfirmationRequest(
                contents: contents,
                kind: kind,
                completion: completion
            )
        )
    }

    // MARK: - Clipboard read confirmation bookkeeping

    /// Requests awaiting the host's answer, keyed by the opaque
    /// `apprt.ClipboardRequest` pointer libghostty gave us. Guarantees
    /// "exactly one of complete/deny fires for every request" even when the
    /// host's confirmation UI never answers — see
    /// ``denyAllPendingClipboardRequests()``.
    ///
    /// `nonisolated(unsafe)` to match `rawSurface` above: the C shims that
    /// touch this run as free functions off the main actor (they can't be
    /// actor-isolated and still be assigned to a `@convention(c)` field),
    /// so this bridge's clipboard bookkeeping follows the same
    /// unsynchronized-by-design convention as the rest of its C-interop
    /// state rather than introducing a second concurrency model here.
    nonisolated(unsafe) private var pendingClipboardRequests: [Int: PendingClipboardRequest] = [:]

    /// Registers a newly received confirm request and returns the token the
    /// caller resolves once the host answers.
    nonisolated func registerPendingClipboardRequest(_ statePtr: UnsafeMutableRawPointer) -> PendingClipboardRequest {
        let token = PendingClipboardRequest(statePtr: statePtr, bridge: self)
        pendingClipboardRequests[Int(bitPattern: statePtr)] = token
        return token
    }

    nonisolated fileprivate func removePendingClipboardRequest(_ statePtr: UnsafeMutableRawPointer) {
        pendingClipboardRequests.removeValue(forKey: Int(bitPattern: statePtr))
    }

    /// Denies every clipboard-read confirmation still waiting on the host's
    /// answer. **Must run while `rawSurface` is still the live surface** —
    /// call before nil-ing it out and before `TerminalSurface.free()`. This
    /// is the wrapper-level backstop for "exactly one of complete/deny
    /// fires for every request": a Pane/Session/Window tearing down while a
    /// confirmation prompt is still open must not leave the requesting
    /// program hanging forever, regardless of whether the host's own UI
    /// (``TerminalClipboardConfirmationRequest``) ever answers or is
    /// released.
    nonisolated func denyAllPendingClipboardRequests() {
        guard !pendingClipboardRequests.isEmpty else { return }
        let tokens = Array(pendingClipboardRequests.values)
        pendingClipboardRequests.removeAll()
        for token in tokens {
            token.forceDeny()
        }
    }

    nonisolated fileprivate func finishClipboardRequest(
        _ statePtr: UnsafeMutableRawPointer,
        allowed: Bool,
        contents: [TerminalClipboardContent],
        available: [String]
    ) {
        guard let surface = rawSurface else {
            TerminalDebugLog.log(.input, "clipboard confirm resolve skipped: missing surface")
            return
        }

        guard allowed else {
            ghostty_surface_deny_clipboard_request(surface, statePtr)
            TerminalDebugLog.log(.input, "clipboard confirm denied")
            return
        }

        withClipboardCompletePayload(
            contents: contents,
            available: available,
            confirmed: true,
            remember: false
        ) { complete in
            ghostty_surface_complete_clipboard_request(surface, complete, statePtr)
        }
        TerminalDebugLog.log(.input, "clipboard confirm allowed")
    }
}

/// Tracks one clipboard-read confirmation from request to answer. Resolves
/// at most once: a second `resolve`/`forceDeny` call (e.g. the host answers
/// after the wrapper already denied at teardown) is a documented no-op, not
/// a double free of libghostty's request state.
///
/// `@unchecked Sendable` so a token created on the (nonisolated) clipboard
/// callback thread can be captured by the main-actor-isolated closure that
/// answers it later — matching `rawSurface`'s `nonisolated(unsafe)` above,
/// this bridge already treats libghostty's callback delivery as
/// effectively single-threaded rather than introducing new synchronization.
final class PendingClipboardRequest: @unchecked Sendable {
    private let statePtr: UnsafeMutableRawPointer
    private weak var bridge: TerminalCallbackBridge?
    private var isResolved = false

    fileprivate init(statePtr: UnsafeMutableRawPointer, bridge: TerminalCallbackBridge) {
        self.statePtr = statePtr
        self.bridge = bridge
    }

    /// Answers the request with the host's decision. Intended to be used as
    /// the completion passed to a ``TerminalClipboardConfirmationRequest``.
    func resolve(_ allowed: Bool, contents: [TerminalClipboardContent], available: [String]) {
        guard !isResolved else { return }
        isResolved = true
        bridge?.finishClipboardRequest(statePtr, allowed: allowed, contents: contents, available: available)
        bridge?.removePendingClipboardRequest(statePtr)
    }

    /// Called by `TerminalCallbackBridge.denyAllPendingClipboardRequests()`
    /// at teardown. Does not itself remove from the bridge's pending map —
    /// the caller already cleared it before invoking this on every token.
    fileprivate func forceDeny() {
        guard !isResolved else { return }
        isResolved = true
        bridge?.finishClipboardRequest(statePtr, allowed: false, contents: [], available: [])
    }
}
