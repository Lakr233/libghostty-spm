//
//  TerminalShellEscape.swift
//  libghostty-spm
//
//  Reference:
//  - ghostty-org/ghostty
//  - macos/Sources/Ghostty/Ghostty.Shell.swift
//  Keep the character set aligned with Ghostty's `Shell.escape` so a path
//  pasted here reads the same as one dropped on the macOS app.
//

import Foundation

enum TerminalShellEscape {
    /// Characters a POSIX shell would otherwise interpret in a word.
    private static let escapedCharacters: Set<Character> = [
        "\\", " ", "(", ")", "[", "]", "{", "}", "<", ">", "\"", "'", "`",
        "!", "#", "$", "&", ";", "|", "*", "?", "\t",
    ]

    /// Backslash-escapes every shell-sensitive character, the form a path
    /// takes when typed into a live prompt (as opposed to a quoted form, which
    /// would be right for building a command line to execute).
    static func escape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.utf8.count)
        for character in string {
            if escapedCharacters.contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }
}
