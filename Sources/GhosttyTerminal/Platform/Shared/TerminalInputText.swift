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
    static let directPasteMinimumBytes = 16 * 1024

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

    static func lineCount(in text: String) -> Int {
        text.reduce(into: 0) { count, character in
            if character == "\n" {
                count += 1
            }
        }
    }

    static func shouldSendPasteDirectly(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if lineCount(in: text) > 0 {
            return true
        }
        return text.utf8.count >= directPasteMinimumBytes
    }

    static func isPrivateUseFunctionKey(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 0xF700 && scalar.value <= 0xF8FF
    }

    static func isUIKitNamedFunctionKey(_ text: String) -> Bool {
        text.hasPrefix("UIKeyInput")
    }
}
