//
//  TerminalSurfaceViewDelegate.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import CoreGraphics
import Foundation
import GhosttyKit

@MainActor
public protocol TerminalSurfaceViewDelegate: AnyObject {}

@MainActor
public protocol TerminalSurfaceTitleDelegate: TerminalSurfaceViewDelegate {
    func terminalDidChangeTitle(_ title: String)
}

@MainActor
public protocol TerminalSurfaceGridResizeDelegate: TerminalSurfaceViewDelegate {
    func terminalDidResize(_ size: TerminalGridMetrics)
}

@MainActor
public protocol TerminalSurfaceResizeDelegate: TerminalSurfaceViewDelegate {
    func terminalDidResize(columns: Int, rows: Int)
}

@MainActor
public protocol TerminalSurfaceFocusDelegate: TerminalSurfaceViewDelegate {
    func terminalDidChangeFocus(_ focused: Bool)
}

@MainActor
public protocol TerminalSurfaceBellDelegate: TerminalSurfaceViewDelegate {
    func terminalDidRingBell()
}

@MainActor
public protocol TerminalSurfaceCloseDelegate: TerminalSurfaceViewDelegate {
    func terminalDidClose(processAlive: Bool)
}

/// The operation that caused Ghostty to request a clipboard decision.
public enum TerminalClipboardRequestKind: Sendable {
    case paste
    case osc52Read
    case osc52Write

    init?(_ rawValue: ghostty_clipboard_request_e) {
        switch rawValue {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
            self = .paste
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
            self = .osc52Read
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
            self = .osc52Write
        default:
            return nil
        }
    }
}

/// A one-shot host decision for an unsafe or otherwise protected clipboard
/// request. Hosts must call ``respond(allow:)`` exactly once. Dropping an
/// unanswered request cancels it.
@MainActor
public final class TerminalClipboardConfirmationRequest {
    public let contents: String
    public let kind: TerminalClipboardRequestKind

    private var completion: ((Bool) -> Void)?

    init(
        contents: String,
        kind: TerminalClipboardRequestKind,
        completion: @escaping (Bool) -> Void
    ) {
        self.contents = contents
        self.kind = kind
        self.completion = completion
    }

    public func respond(allow: Bool) {
        guard let completion else { return }
        self.completion = nil
        completion(allow)
    }

    deinit {
        MainActor.assumeIsolated {
            completion?(false)
        }
    }
}

/// Lets an embedding host own confirmation UI for unsafe paste and protected
/// OSC 52 operations. If the delegate does not implement this protocol, the
/// request is denied.
@MainActor
public protocol TerminalSurfaceClipboardConfirmationDelegate: TerminalSurfaceViewDelegate {
    func terminalDidRequestClipboardConfirmation(
        _ request: TerminalClipboardConfirmationRequest
    )
}

// MARK: - Extended action delegates

/// State of an OSC 9;4 / DECSET progress report.
public enum TerminalProgressState: Sendable {
    case remove
    case set
    case error
    case indeterminate
    case pause

    init?(_ raw: ghostty_action_progress_report_state_e) {
        switch raw {
        case GHOSTTY_PROGRESS_STATE_REMOVE: self = .remove
        case GHOSTTY_PROGRESS_STATE_SET: self = .set
        case GHOSTTY_PROGRESS_STATE_ERROR: self = .error
        case GHOSTTY_PROGRESS_STATE_INDETERMINATE: self = .indeterminate
        case GHOSTTY_PROGRESS_STATE_PAUSE: self = .pause
        default: return nil
        }
    }
}

/// OSC 9;4 progress report (state + 0-100 percent, nil percent when the
/// emitter didn't provide one — e.g. INDETERMINATE / REMOVE).
@MainActor
public protocol TerminalSurfaceProgressReportDelegate: TerminalSurfaceViewDelegate {
    func terminalDidReportProgress(state: TerminalProgressState, percent: Int?)
}

/// Fires when a shell-integration-aware command exits. `exitCode` is nil
/// when not reported; `duration` is the wall clock in nanoseconds.
@MainActor
public protocol TerminalSurfaceCommandFinishedDelegate: TerminalSurfaceViewDelegate {
    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64)
}

/// OSC 9 (iTerm2) / OSC 777 (rxvt-unicode) desktop notification.
/// Empty title/body surface as empty strings rather than nil.
@MainActor
public protocol TerminalSurfaceDesktopNotificationDelegate: TerminalSurfaceViewDelegate {
    func terminalDidRequestDesktopNotification(title: String, body: String)
}

public enum TerminalOpenURLKind: Sendable {
    case unknown
    case text
    case html

    init(_ raw: ghostty_action_open_url_kind_e) {
        switch raw {
        case GHOSTTY_ACTION_OPEN_URL_KIND_TEXT: self = .text
        case GHOSTTY_ACTION_OPEN_URL_KIND_HTML: self = .html
        default: self = .unknown
        }
    }
}

/// User activated (cmd-clicked) a hyperlink inside the terminal grid.
@MainActor
public protocol TerminalSurfaceOpenURLDelegate: TerminalSurfaceViewDelegate {
    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind)
}

/// Mouse hovered over a recognized hyperlink. nil = hover ended / link lost.
@MainActor
public protocol TerminalSurfaceHoverLinkDelegate: TerminalSurfaceViewDelegate {
    func terminalDidUpdateHoverLink(_ url: String?)
}

/// Ghostty mouse cursor shape (OSC 22 / application request).
public enum TerminalMouseShape: Sendable, Equatable {
    case `default`
    case pointer
    case text
    case notAllowed
    case other

    init(_ raw: ghostty_action_mouse_shape_e) {
        switch raw {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT:
            self = .default
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            self = .pointer
        case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT, GHOSTTY_MOUSE_SHAPE_CELL:
            self = .text
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP:
            self = .notAllowed
        default:
            self = .other
        }
    }
}

@MainActor
public protocol TerminalSurfaceMouseShapeDelegate: TerminalSurfaceViewDelegate {
    func terminalDidChangeMouseShape(_ shape: TerminalMouseShape)
}

/// OSC 7 working-directory update.
@MainActor
public protocol TerminalSurfacePwdDelegate: TerminalSurfaceViewDelegate {
    func terminalDidChangeWorkingDirectory(_ path: String)
}

/// Scrollbar geometry reported by the terminal, in rows: `offset` rows are
/// scrolled off above the viewport, `len` rows are visible, out of `total`
/// rows of content (scrollback + screen).
public struct TerminalScrollbar: Equatable, Sendable {
    public let total: UInt64
    public let offset: UInt64
    public let len: UInt64

    public init(total: UInt64, offset: UInt64, len: UInt64) {
        self.total = total
        self.offset = offset
        self.len = len
    }
}

/// The scrollbar geometry changed (the viewport scrolled or the content grew).
@MainActor
public protocol TerminalSurfaceScrollbarDelegate: TerminalSurfaceViewDelegate {
    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar)
}

/// User long-pressed to request a selection-page presentation.
public struct TerminalTextSelectionRequest: Sendable {
    /// Viewport text snapshot. Lines separated by `\n`.
    public let text: String

    /// Recommended pre-selection range in UTF-16 units, suitable for direct
    /// assignment to `UITextView.selectedRange`. `nil` means the host should
    /// `selectAll` instead.
    public let anchorRange: NSRange?

    /// Long-press point in the terminal view's coordinate space (points).
    /// Hosts may use this as a popover anchor.
    public let sourcePoint: CGPoint
}

@MainActor
public protocol TerminalSurfaceTextSelectionRequestDelegate: TerminalSurfaceViewDelegate {
    func terminalDidRequestTextSelection(_ request: TerminalTextSelectionRequest)
}

/// Notifies a delegate when the underlying ``TerminalSurface`` is created or
/// torn down. Useful when a consumer needs surface-level APIs (e.g.
/// ``TerminalSurface/sendText(_:)``) reachable from outside the platform view.
@MainActor
public protocol TerminalSurfaceLifecycleDelegate: TerminalSurfaceViewDelegate {
    func terminalDidAttachSurface(_ surface: TerminalSurface)
    func terminalDidDetachSurface()
}
