//
//  TerminalKeyPress.swift
//  libghostty-spm
//

import GhosttyKit

/// A named key a host can press programmatically.
///
/// `sendText(_:)` rides the paste path, so a shell with bracketed paste on
/// treats a sent `\r` as pasted text. A key event is never paste-framed.
public enum TerminalKeyPress: Sendable, CaseIterable {
    case enter
    case tab
    case escape
    case backspace
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight

    var ghosttyKey: ghostty_input_key_e {
        switch self {
        case .enter: GHOSTTY_KEY_ENTER
        case .tab: GHOSTTY_KEY_TAB
        case .escape: GHOSTTY_KEY_ESCAPE
        case .backspace: GHOSTTY_KEY_BACKSPACE
        case .arrowUp: GHOSTTY_KEY_ARROW_UP
        case .arrowDown: GHOSTTY_KEY_ARROW_DOWN
        case .arrowLeft: GHOSTTY_KEY_ARROW_LEFT
        case .arrowRight: GHOSTTY_KEY_ARROW_RIGHT
        }
    }
}

extension TerminalSurface {
    /// Presses and releases one named key, as if it was typed.
    @discardableResult
    public func sendKeyPress(_ key: TerminalKeyPress) -> Bool {
        var event = ghostty_input_key_s()
        event.keycode = TerminalHardwareKeyRouter.appKitKeyCode(for: key.ghosttyKey)

        event.action = GHOSTTY_ACTION_PRESS
        let pressed = sendKeyEvent(event)
        // The release keeps the kitty keyboard protocol from reporting a
        // key that stays down.
        event.action = GHOSTTY_ACTION_RELEASE
        _ = sendKeyEvent(event)
        return pressed
    }
}
