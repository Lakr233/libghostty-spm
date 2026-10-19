//
//  TerminalInputText.swift
//  libghostty-spm
//
//  Reference:
//  - ghostty-org/ghostty
//  - macos/Sources/Ghostty/NSEvent+Extension.swift
//  Keep the AppKit text filtering here aligned with Ghostty's native
//  `ghosttyCharacters` behavior so future upstream syncs stay mechanical.

import Foundation

enum TerminalInputText {
    static func filteredFunctionKeyText(_ text: String?) -> String? {
        guard let text else { return nil }
        if isUIKitNamedFunctionKey(text) {
            return nil
        }
        guard text.count == 1, let scalar = text.unicodeScalars.first else {
            return text
        }

        if isPrivateUseFunctionKey(scalar) {
            return nil
        }

        return text
    }

    /// The text a hardware key event carries, or nil when it is empty or
    /// starts with an ASCII control character (C0 or DEL): Return's `\r`,
    /// Tab, Escape, Backspace. Ghostty encodes those from the key and its
    /// modifiers. Sent as text, they make the kitty encoder strip the
    /// modifiers marked consumed, so under the protocol Claude Code turns on
    /// Shift+Enter reached the program as a bare `\r` and submitted. Ghostty's
    /// macOS app sends no text for them either (`String.keyEventText`).
    static func keyEventText(_ text: String?) -> String? {
        guard let text, let scalar = text.unicodeScalars.first else { return nil }
        if scalar.value < 0x20 || scalar.value == 0x7F {
            return nil
        }
        return text
    }

    static func lineCount(in text: String) -> Int {
        text.reduce(into: 0) { count, character in
            if character == "\n" {
                count += 1
            }
        }
    }

    static func isPrivateUseFunctionKey(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 0xF700 && scalar.value <= 0xF8FF
    }

    static func isUIKitNamedFunctionKey(_ text: String) -> Bool {
        text.hasPrefix("UIKeyInput")
    }
}

enum TerminalSoftwareKeyCommitRoute: Sendable, Equatable {
    case suppressHardwareDuplicate
    case semanticEnter
    case text
}

enum TerminalSoftwareKeyCommitRouter {
    static func route(
        text: String,
        hasMarkedText: Bool,
        hardwareKeyHandled: Bool,
    ) -> TerminalSoftwareKeyCommitRoute {
        if hardwareKeyHandled {
            return .suppressHardwareDuplicate
        }
        if !hasMarkedText, text == "\n" || text == "\r" {
            return .semanticEnter
        }
        return .text
    }
}
