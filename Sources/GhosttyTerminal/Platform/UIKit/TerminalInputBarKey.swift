//
//  TerminalInputBarKey.swift
//  libghostty-spm
//

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    public enum TerminalInputAccessoryItem: Equatable, Sendable {
        case esc
        case ctrl
        case alt
        case command
        case tab
        case arrowLeft
        case arrowUp
        case arrowDown
        case arrowRight
        case symbol(String)
        case paste
        case divider

        public static let defaultItems: [TerminalInputAccessoryItem] = [
            .esc,
            .ctrl,
            .alt,
            .command,
            .divider,
            .tab,
            .arrowLeft,
            .arrowUp,
            .arrowDown,
            .arrowRight,
            .divider,
            .symbol("|"),
            .symbol("/"),
            .symbol("~"),
            .symbol("-"),
            .symbol("_"),
            .symbol("`"),
            .symbol("'"),
            .symbol("\""),
            .paste,
        ]
    }

    enum TerminalInputBarKey {
        case esc
        case tab
        case arrowLeft
        case arrowUp
        case arrowDown
        case arrowRight
        case symbol(String)
        case paste
    }
#endif
