import GhosttyKit

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

// MARK: - InputModifiers

public struct InputModifiers: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let shift = InputModifiers(rawValue: 1 << 0)
    public static let ctrl = InputModifiers(rawValue: 1 << 1)
    public static let alt = InputModifiers(rawValue: 1 << 2)
    public static let super_ = InputModifiers(rawValue: 1 << 3)
    public static let caps = InputModifiers(rawValue: 1 << 4)
    public static let num = InputModifiers(rawValue: 1 << 5)
    public static let shiftRight = InputModifiers(rawValue: 1 << 6)
    public static let ctrlRight = InputModifiers(rawValue: 1 << 7)
    public static let altRight = InputModifiers(rawValue: 1 << 8)
    public static let superRight = InputModifiers(rawValue: 1 << 9)

    public var ghosttyMods: ghostty_input_mods_e {
        ghostty_input_mods_e(rawValue)
    }

    #if canImport(UIKit)
        public init(from flags: UIKeyModifierFlags) {
            var mods = InputModifiers()
            if flags.contains(.shift) { mods.insert(.shift) }
            if flags.contains(.control) { mods.insert(.ctrl) }
            if flags.contains(.alternate) { mods.insert(.alt) }
            if flags.contains(.command) { mods.insert(.super_) }
            if flags.contains(.alphaShift) { mods.insert(.caps) }
            if flags.contains(.numericPad) { mods.insert(.num) }
            self = mods
        }

    #elseif canImport(AppKit)
        public init(from flags: NSEvent.ModifierFlags) {
            var mods = InputModifiers()
            if flags.contains(.shift) { mods.insert(.shift) }
            if flags.contains(.control) { mods.insert(.ctrl) }
            if flags.contains(.option) { mods.insert(.alt) }
            if flags.contains(.command) { mods.insert(.super_) }
            if flags.contains(.capsLock) { mods.insert(.caps) }
            if flags.contains(.numericPad) { mods.insert(.num) }
            self = mods
        }
    #endif
}

// MARK: - InputKey

public enum InputKey: Sendable {
    #if canImport(UIKit)
        public static func from(_ usage: UIKeyboardHIDUsage) -> ghostty_input_key_e {
            switch usage {
            case .keyboardA: GHOSTTY_KEY_A
            case .keyboardB: GHOSTTY_KEY_B
            case .keyboardC: GHOSTTY_KEY_C
            case .keyboardD: GHOSTTY_KEY_D
            case .keyboardE: GHOSTTY_KEY_E
            case .keyboardF: GHOSTTY_KEY_F
            case .keyboardG: GHOSTTY_KEY_G
            case .keyboardH: GHOSTTY_KEY_H
            case .keyboardI: GHOSTTY_KEY_I
            case .keyboardJ: GHOSTTY_KEY_J
            case .keyboardK: GHOSTTY_KEY_K
            case .keyboardL: GHOSTTY_KEY_L
            case .keyboardM: GHOSTTY_KEY_M
            case .keyboardN: GHOSTTY_KEY_N
            case .keyboardO: GHOSTTY_KEY_O
            case .keyboardP: GHOSTTY_KEY_P
            case .keyboardQ: GHOSTTY_KEY_Q
            case .keyboardR: GHOSTTY_KEY_R
            case .keyboardS: GHOSTTY_KEY_S
            case .keyboardT: GHOSTTY_KEY_T
            case .keyboardU: GHOSTTY_KEY_U
            case .keyboardV: GHOSTTY_KEY_V
            case .keyboardW: GHOSTTY_KEY_W
            case .keyboardX: GHOSTTY_KEY_X
            case .keyboardY: GHOSTTY_KEY_Y
            case .keyboardZ: GHOSTTY_KEY_Z
            case .keyboard0: GHOSTTY_KEY_DIGIT_0
            case .keyboard1: GHOSTTY_KEY_DIGIT_1
            case .keyboard2: GHOSTTY_KEY_DIGIT_2
            case .keyboard3: GHOSTTY_KEY_DIGIT_3
            case .keyboard4: GHOSTTY_KEY_DIGIT_4
            case .keyboard5: GHOSTTY_KEY_DIGIT_5
            case .keyboard6: GHOSTTY_KEY_DIGIT_6
            case .keyboard7: GHOSTTY_KEY_DIGIT_7
            case .keyboard8: GHOSTTY_KEY_DIGIT_8
            case .keyboard9: GHOSTTY_KEY_DIGIT_9
            case .keyboardReturnOrEnter: GHOSTTY_KEY_ENTER
            case .keyboardEscape: GHOSTTY_KEY_ESCAPE
            case .keyboardDeleteOrBackspace: GHOSTTY_KEY_BACKSPACE
            case .keyboardTab: GHOSTTY_KEY_TAB
            case .keyboardSpacebar: GHOSTTY_KEY_SPACE
            case .keyboardHyphen: GHOSTTY_KEY_MINUS
            case .keyboardEqualSign: GHOSTTY_KEY_EQUAL
            case .keyboardOpenBracket: GHOSTTY_KEY_BRACKET_LEFT
            case .keyboardCloseBracket: GHOSTTY_KEY_BRACKET_RIGHT
            case .keyboardBackslash: GHOSTTY_KEY_BACKSLASH
            case .keyboardSemicolon: GHOSTTY_KEY_SEMICOLON
            case .keyboardQuote: GHOSTTY_KEY_QUOTE
            case .keyboardGraveAccentAndTilde: GHOSTTY_KEY_BACKQUOTE
            case .keyboardComma: GHOSTTY_KEY_COMMA
            case .keyboardPeriod: GHOSTTY_KEY_PERIOD
            case .keyboardSlash: GHOSTTY_KEY_SLASH
            case .keyboardCapsLock: GHOSTTY_KEY_CAPS_LOCK
            case .keyboardF1: GHOSTTY_KEY_F1
            case .keyboardF2: GHOSTTY_KEY_F2
            case .keyboardF3: GHOSTTY_KEY_F3
            case .keyboardF4: GHOSTTY_KEY_F4
            case .keyboardF5: GHOSTTY_KEY_F5
            case .keyboardF6: GHOSTTY_KEY_F6
            case .keyboardF7: GHOSTTY_KEY_F7
            case .keyboardF8: GHOSTTY_KEY_F8
            case .keyboardF9: GHOSTTY_KEY_F9
            case .keyboardF10: GHOSTTY_KEY_F10
            case .keyboardF11: GHOSTTY_KEY_F11
            case .keyboardF12: GHOSTTY_KEY_F12
            case .keyboardF13: GHOSTTY_KEY_F13
            case .keyboardF14: GHOSTTY_KEY_F14
            case .keyboardF15: GHOSTTY_KEY_F15
            case .keyboardF16: GHOSTTY_KEY_F16
            case .keyboardF17: GHOSTTY_KEY_F17
            case .keyboardF18: GHOSTTY_KEY_F18
            case .keyboardF19: GHOSTTY_KEY_F19
            case .keyboardF20: GHOSTTY_KEY_F20
            case .keyboardPrintScreen: GHOSTTY_KEY_PRINT_SCREEN
            case .keyboardScrollLock: GHOSTTY_KEY_SCROLL_LOCK
            case .keyboardPause: GHOSTTY_KEY_PAUSE
            case .keyboardInsert: GHOSTTY_KEY_INSERT
            case .keyboardHome: GHOSTTY_KEY_HOME
            case .keyboardPageUp: GHOSTTY_KEY_PAGE_UP
            case .keyboardDeleteForward: GHOSTTY_KEY_DELETE
            case .keyboardEnd: GHOSTTY_KEY_END
            case .keyboardPageDown: GHOSTTY_KEY_PAGE_DOWN
            case .keyboardRightArrow: GHOSTTY_KEY_ARROW_RIGHT
            case .keyboardLeftArrow: GHOSTTY_KEY_ARROW_LEFT
            case .keyboardDownArrow: GHOSTTY_KEY_ARROW_DOWN
            case .keyboardUpArrow: GHOSTTY_KEY_ARROW_UP
            case .keypadNumLock: GHOSTTY_KEY_NUM_LOCK
            case .keypadSlash: GHOSTTY_KEY_NUMPAD_DIVIDE
            case .keypadAsterisk: GHOSTTY_KEY_NUMPAD_MULTIPLY
            case .keypadHyphen: GHOSTTY_KEY_NUMPAD_SUBTRACT
            case .keypadPlus: GHOSTTY_KEY_NUMPAD_ADD
            case .keypadEnter: GHOSTTY_KEY_NUMPAD_ENTER
            case .keypad0: GHOSTTY_KEY_NUMPAD_0
            case .keypad1: GHOSTTY_KEY_NUMPAD_1
            case .keypad2: GHOSTTY_KEY_NUMPAD_2
            case .keypad3: GHOSTTY_KEY_NUMPAD_3
            case .keypad4: GHOSTTY_KEY_NUMPAD_4
            case .keypad5: GHOSTTY_KEY_NUMPAD_5
            case .keypad6: GHOSTTY_KEY_NUMPAD_6
            case .keypad7: GHOSTTY_KEY_NUMPAD_7
            case .keypad8: GHOSTTY_KEY_NUMPAD_8
            case .keypad9: GHOSTTY_KEY_NUMPAD_9
            case .keypadPeriod: GHOSTTY_KEY_NUMPAD_DECIMAL
            case .keypadEqualSign: GHOSTTY_KEY_NUMPAD_EQUAL
            case .keyboardLeftShift: GHOSTTY_KEY_SHIFT_LEFT
            case .keyboardLeftControl: GHOSTTY_KEY_CONTROL_LEFT
            case .keyboardLeftAlt: GHOSTTY_KEY_ALT_LEFT
            case .keyboardLeftGUI: GHOSTTY_KEY_META_LEFT
            case .keyboardRightShift: GHOSTTY_KEY_SHIFT_RIGHT
            case .keyboardRightControl: GHOSTTY_KEY_CONTROL_RIGHT
            case .keyboardRightAlt: GHOSTTY_KEY_ALT_RIGHT
            case .keyboardRightGUI: GHOSTTY_KEY_META_RIGHT
            case .keyboardNonUSBackslash: GHOSTTY_KEY_INTL_BACKSLASH
            case .keyboardApplication: GHOSTTY_KEY_CONTEXT_MENU
            case .keyboardPower: GHOSTTY_KEY_POWER
            case .keyboardHelp: GHOSTTY_KEY_HELP
            case .keyboardMute: GHOSTTY_KEY_AUDIO_VOLUME_MUTE
            case .keyboardVolumeUp: GHOSTTY_KEY_AUDIO_VOLUME_UP
            case .keyboardVolumeDown: GHOSTTY_KEY_AUDIO_VOLUME_DOWN
            default: GHOSTTY_KEY_UNIDENTIFIED
            }
        }

    #elseif canImport(AppKit)
        public static func from(keyCode: UInt16) -> ghostty_input_key_e {
            switch keyCode {
            case 0: GHOSTTY_KEY_A
            case 1: GHOSTTY_KEY_S
            case 2: GHOSTTY_KEY_D
            case 3: GHOSTTY_KEY_F
            case 4: GHOSTTY_KEY_H
            case 5: GHOSTTY_KEY_G
            case 6: GHOSTTY_KEY_Z
            case 7: GHOSTTY_KEY_X
            case 8: GHOSTTY_KEY_C
            case 9: GHOSTTY_KEY_V
            case 11: GHOSTTY_KEY_B
            case 12: GHOSTTY_KEY_Q
            case 13: GHOSTTY_KEY_W
            case 14: GHOSTTY_KEY_E
            case 15: GHOSTTY_KEY_R
            case 16: GHOSTTY_KEY_Y
            case 17: GHOSTTY_KEY_T
            case 18: GHOSTTY_KEY_DIGIT_1
            case 19: GHOSTTY_KEY_DIGIT_2
            case 20: GHOSTTY_KEY_DIGIT_3
            case 21: GHOSTTY_KEY_DIGIT_4
            case 22: GHOSTTY_KEY_DIGIT_6
            case 23: GHOSTTY_KEY_DIGIT_5
            case 24: GHOSTTY_KEY_EQUAL
            case 25: GHOSTTY_KEY_DIGIT_9
            case 26: GHOSTTY_KEY_DIGIT_7
            case 27: GHOSTTY_KEY_MINUS
            case 28: GHOSTTY_KEY_DIGIT_8
            case 29: GHOSTTY_KEY_DIGIT_0
            case 30: GHOSTTY_KEY_BRACKET_RIGHT
            case 31: GHOSTTY_KEY_O
            case 32: GHOSTTY_KEY_U
            case 33: GHOSTTY_KEY_BRACKET_LEFT
            case 34: GHOSTTY_KEY_I
            case 35: GHOSTTY_KEY_P
            case 36: GHOSTTY_KEY_ENTER
            case 37: GHOSTTY_KEY_L
            case 38: GHOSTTY_KEY_J
            case 39: GHOSTTY_KEY_QUOTE
            case 40: GHOSTTY_KEY_K
            case 41: GHOSTTY_KEY_SEMICOLON
            case 42: GHOSTTY_KEY_BACKSLASH
            case 43: GHOSTTY_KEY_COMMA
            case 44: GHOSTTY_KEY_SLASH
            case 45: GHOSTTY_KEY_N
            case 46: GHOSTTY_KEY_M
            case 47: GHOSTTY_KEY_PERIOD
            case 48: GHOSTTY_KEY_TAB
            case 49: GHOSTTY_KEY_SPACE
            case 50: GHOSTTY_KEY_BACKQUOTE
            case 51: GHOSTTY_KEY_BACKSPACE
            case 53: GHOSTTY_KEY_ESCAPE
            case 56: GHOSTTY_KEY_SHIFT_LEFT
            case 57: GHOSTTY_KEY_CAPS_LOCK
            case 58: GHOSTTY_KEY_ALT_LEFT
            case 59: GHOSTTY_KEY_CONTROL_LEFT
            case 60: GHOSTTY_KEY_SHIFT_RIGHT
            case 61: GHOSTTY_KEY_ALT_RIGHT
            case 62: GHOSTTY_KEY_CONTROL_RIGHT
            case 64: GHOSTTY_KEY_F17
            case 65: GHOSTTY_KEY_NUMPAD_DECIMAL
            case 67: GHOSTTY_KEY_NUMPAD_MULTIPLY
            case 69: GHOSTTY_KEY_NUMPAD_ADD
            case 71: GHOSTTY_KEY_NUM_LOCK
            case 75: GHOSTTY_KEY_NUMPAD_DIVIDE
            case 76: GHOSTTY_KEY_NUMPAD_ENTER
            case 78: GHOSTTY_KEY_NUMPAD_SUBTRACT
            case 79: GHOSTTY_KEY_F18
            case 80: GHOSTTY_KEY_F19
            case 81: GHOSTTY_KEY_NUMPAD_EQUAL
            case 82: GHOSTTY_KEY_NUMPAD_0
            case 83: GHOSTTY_KEY_NUMPAD_1
            case 84: GHOSTTY_KEY_NUMPAD_2
            case 85: GHOSTTY_KEY_NUMPAD_3
            case 86: GHOSTTY_KEY_NUMPAD_4
            case 87: GHOSTTY_KEY_NUMPAD_5
            case 88: GHOSTTY_KEY_NUMPAD_6
            case 89: GHOSTTY_KEY_NUMPAD_7
            case 90: GHOSTTY_KEY_F20
            case 91: GHOSTTY_KEY_NUMPAD_8
            case 92: GHOSTTY_KEY_NUMPAD_9
            case 96: GHOSTTY_KEY_F5
            case 97: GHOSTTY_KEY_F6
            case 98: GHOSTTY_KEY_F7
            case 99: GHOSTTY_KEY_F3
            case 100: GHOSTTY_KEY_F8
            case 101: GHOSTTY_KEY_F9
            case 103: GHOSTTY_KEY_F11
            case 105: GHOSTTY_KEY_F13
            case 106: GHOSTTY_KEY_F16
            case 107: GHOSTTY_KEY_F15
            case 109: GHOSTTY_KEY_F10
            case 111: GHOSTTY_KEY_F12
            case 113: GHOSTTY_KEY_F14
            case 114: GHOSTTY_KEY_INSERT
            case 115: GHOSTTY_KEY_HOME
            case 116: GHOSTTY_KEY_PAGE_UP
            case 117: GHOSTTY_KEY_DELETE
            case 118: GHOSTTY_KEY_F4
            case 119: GHOSTTY_KEY_END
            case 120: GHOSTTY_KEY_F2
            case 121: GHOSTTY_KEY_PAGE_DOWN
            case 122: GHOSTTY_KEY_F1
            case 123: GHOSTTY_KEY_ARROW_LEFT
            case 124: GHOSTTY_KEY_ARROW_RIGHT
            case 125: GHOSTTY_KEY_ARROW_DOWN
            case 126: GHOSTTY_KEY_ARROW_UP
            default: GHOSTTY_KEY_UNIDENTIFIED
            }
        }
    #endif
}

// MARK: - ScrollModifiers

public struct ScrollModifiers: Sendable {
    public let rawValue: ghostty_input_scroll_mods_t

    public init(rawValue: ghostty_input_scroll_mods_t = 0) {
        self.rawValue = rawValue
    }

    public init(precision: Bool, momentum: Momentum = .none) {
        var value: Int32 = 0
        if precision { value |= 1 }
        value |= momentum.rawValue << 1
        rawValue = value
    }

    public var precision: Bool {
        (rawValue & 1) != 0
    }

    public var momentum: Momentum {
        Momentum(rawValue: (rawValue >> 1) & 0x3) ?? .none
    }

    public enum Momentum: Int32, Sendable {
        case none = 0
        case began = 1
        case stationary = 2
        case changed = 3
    }

    #if canImport(AppKit) && !canImport(UIKit)
        static func momentumFrom(phase: NSEvent.Phase) -> Momentum {
            if phase.contains(.began) { return .began }
            if phase.contains(.stationary) { return .stationary }
            if phase.contains(.changed) { return .changed }
            return .none
        }
    #endif
}
