//
//  TerminalInputBarKey.swift
//  libghostty-spm
//

#if canImport(UIKit)
    #if !targetEnvironment(macCatalyst)
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
            /// A `symbol` key that shows `nickname` instead of the text it
            /// sends — `"\u{1b}[A"` as "Up", a long command as a short name.
            /// It sends exactly what `symbol` would.
            case nicknamedSymbol(String, nickname: String)
            case paste
            case divider

            /// A key that sends `text` and is labelled `nickname`; spelled
            /// like `symbol` so a layout reads as one list.
            public static func symbol(_ text: String, nickname: String) -> Self {
                .nicknamedSymbol(text, nickname: nickname)
            }

            /// The English name the accessory bar uses as the button's
            /// accessibility label; `symbol` returns its literal text, a
            /// nicknamed one its nickname, and `divider` has none. Public so a host's bar-configuration UI can
            /// describe items without duplicating this table.
            public var title: String? {
                switch self {
                case .esc: "Escape"
                case .ctrl: "Control"
                case .alt: "Option"
                case .command: "Command"
                case .tab: "Tab"
                case .arrowLeft: "Left Arrow"
                case .arrowUp: "Up Arrow"
                case .arrowDown: "Down Arrow"
                case .arrowRight: "Right Arrow"
                case let .symbol(symbol): symbol
                case .nicknamedSymbol: buttonTitle
                case .paste: "Paste"
                case .divider: nil
                }
            }

            /// The text a `symbol` button shows: all of it, or its nickname,
            /// on one line; the button widens into a capsule to fit. An empty
            /// nickname shows the text. `nil` for items drawn as glyphs or not
            /// drawn at all. Public so a host's
            /// bar-configuration UI labels keys the way the bar does.
            public var buttonTitle: String? {
                switch self {
                case let .symbol(symbol): symbol
                case let .nicknamedSymbol(symbol, nickname): nickname.isEmpty ? symbol : nickname
                default: nil
                }
            }

            /// The SF Symbol the accessory bar renders for this item; nil for
            /// items drawn as text (`symbol`) or non-buttons (`divider`). Public
            /// so a host's bar-configuration UI shows the same glyphs as the bar.
            public var systemImage: String? {
                switch self {
                case .esc: "escape"
                case .ctrl: "control"
                case .alt: "option"
                case .command: "command"
                case .tab: "arrow.right.to.line"
                case .arrowLeft: "arrowtriangle.left.fill"
                case .arrowUp: "arrowtriangle.up.fill"
                case .arrowDown: "arrowtriangle.down.fill"
                case .arrowRight: "arrowtriangle.right.fill"
                case .paste: "doc.on.clipboard"
                case .symbol, .nicknamedSymbol, .divider: nil
                }
            }

            public static let defaultItems: [TerminalInputAccessoryItem] = [
                .esc,
                .tab,
                .ctrl,
                .alt,
                .command,
                .divider,
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
#endif
