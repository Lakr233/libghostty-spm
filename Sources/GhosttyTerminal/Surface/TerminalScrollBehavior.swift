//
//  TerminalScrollBehavior.swift
//  libghostty-spm
//

/// Where a precision scroll — a trackpad, a Magic Mouse, a finger — leaves
/// the viewport.
public enum TerminalScrollBehavior: Sendable {
    /// Moved by the pixel, and brought to a whole row once the scroll stops.
    case settlesOnRow
    /// Moved by the pixel and left where the scroll stopped. It comes to a
    /// row only when what follows counts in rows: on iOS a tap, a touch
    /// selection or the long press's menu (with inline selection on), a
    /// pinch, a finger on a Mac Catalyst touch display, the view going
    /// away. A pointer press does not move it.
    case restsAnywhere
    /// Moved a row at a time, as Ghostty scrolls without smooth scrolling.
    case rowAtATime
}
