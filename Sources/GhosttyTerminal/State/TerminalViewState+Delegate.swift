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

    /// Unlike its neighbours here, this one is *scheduled* rather than applied.
    ///
    /// The metrics come from `synchronizeMetrics()`, which runs off the view's
    /// layout — and SwiftUI runs a representable's `layoutSubviews` inside its
    /// own update pass. Assigning a `@Published` property there publishes while
    /// SwiftUI is mid-update, which it reports as "Publishing changes from
    /// within view updates is not allowed, this will cause undefined
    /// behavior." The other callbacks on this type are driven by the terminal's
    /// IO thread and reach the main actor already outside an update, so only
    /// this one needs the hop.
    ///
    /// The cost is one runloop turn before a host sees a new grid size, and it
    /// is invisible: the size reached the engine before this was ever called
    /// (see the comment in `synchronizeMetrics`), so this notification is for
    /// the host's own UI, never for the terminal. The guard keeps a layout pass
    /// that recomputes the same metrics from scheduling anything at all.
    public func terminalDidResize(_ size: TerminalGridMetrics) {
        guard surfaceSize != size else { return }
        terminalRunOnMainNextTurn { [weak self] in
            self?.surfaceSize = size
        }
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
