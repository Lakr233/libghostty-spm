//
//  TerminalViewState+Delegate.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

extension TerminalViewState:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceScrollbarDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceTextSelectionRequestDelegate,
    TerminalSurfaceClipboardConfirmationDelegate
{
    public func terminalDidChangeTitle(_ title: String) {
        self.title = title
    }

    public func terminalDidResize(_ size: TerminalGridMetrics) {
        surfaceSize = size
    }

    public func terminalDidChangeFocus(_ focused: Bool) {
        isFocused = focused
    }

    public func terminalDidClose(processAlive: Bool) {
        onClose?(processAlive)
    }

    public func terminalDidRingBell() {
        bellCount += 1
        lastBellAt = Date()
    }

    public func terminalDidRequestDesktopNotification(title: String, body: String) {
        lastDesktopNotificationTitle = title
        lastDesktopNotificationBody = body
        lastDesktopNotificationAt = Date()
    }

    public func terminalDidChangeWorkingDirectory(_ path: String) {
        workingDirectory = path
    }

    public func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
        self.scrollbar = scrollbar
    }

    public func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        lastCommandExitCode = exitCode
        lastCommandDurationNanos = durationNanos
    }

    public func terminalDidRequestTextSelection(_ request: TerminalTextSelectionRequest) {
        onTextSelectionRequest?(request)
    }

    public func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        guard let onClipboardConfirmationRequest else {
            // No host UI to ask. A paste the user started is theirs to
            // make — the host's Paste button always pasted before it ran
            // through the binding, and dropping it silently is worse than
            // what paste protection guards against. A program's own read or
            // write of the clipboard stays denied.
            request.respond(allow: request.kind == .paste)
            return
        }
        onClipboardConfirmationRequest(request)
    }

    public func terminalDidAttachSurface(_ surface: TerminalSurface) {
        self.surface = surface
    }

    public func terminalDidDetachSurface() {
        surface = nil
    }
}
