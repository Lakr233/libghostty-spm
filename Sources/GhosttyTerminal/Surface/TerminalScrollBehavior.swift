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
    /// row only when what follows counts in rows: a touch selection, a
    /// pinch, the view going away.
    case restsAnywhere
    /// Moved a row at a time, as Ghostty scrolls without smooth scrolling.
    case rowAtATime
}
