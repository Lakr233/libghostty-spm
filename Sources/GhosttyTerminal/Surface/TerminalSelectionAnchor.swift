//
//  TerminalSelectionAnchor.swift
//  libghostty-spm
//

import Foundation

enum TerminalSelectionAnchor {
    /// Map a quicklook word back into an `NSRange` inside the viewport text
    /// snapshot, suitable for direct assignment to
    /// `UITextView.selectedRange`.
    ///
    /// `offsetStart` is ghostty's `ghostty_text_s.offset_start`: the word's
    /// first cell as a linear index into the viewport grid
    /// (`row * columns + column`, Surface.zig `dumpTextLocked`), and `columns`
    /// is the grid width from `TerminalSurface.size()`. Both are cell counts,
    /// so window padding, the text baseline and the display scale never enter.
    ///
    /// Strategy: derive `row` and the expected UTF-16 column from the offset;
    /// collect every literal occurrence of `word` in that row and pick the
    /// match whose `location` is closest to the column. This resolves
    /// substring ambiguity (e.g. `catalog cat` long-pressed at the end picks
    /// the standalone `cat`, not the prefix of `catalog`) without depending
    /// on word boundaries — which would fail for tokens like `/foo` whose
    /// first character is a non-word character.
    ///
    /// Known limitation: when the target row contains CJK full-width
    /// characters before the match, cell columns and UTF-16 offsets diverge
    /// (CJK = 2 cells, 1 UTF-16 unit), so disambiguation between duplicates
    /// may pick the wrong occurrence. ASCII-only scenarios are exact.
    static func resolveRange(
        in text: String,
        word: String,
        offsetStart: UInt32,
        columns: UInt32
    ) -> NSRange? {
        guard columns > 0 else { return nil }
        return resolveRange(
            in: text,
            word: word,
            row: Int(offsetStart / columns),
            expectedColumnUTF16: Int(offsetStart % columns)
        )
    }

    private static func resolveRange(
        in text: String,
        word: String,
        row: Int,
        expectedColumnUTF16: Int
    ) -> NSRange? {
        guard !word.isEmpty else { return nil }

        let nsText = text as NSString
        let lines = nsText.components(separatedBy: "\n")
        guard row >= 0, row < lines.count else { return nil }

        let line = lines[row] as NSString
        let wordNS = word as NSString

        var matches: [NSRange] = []
        var searchLocation = 0
        while searchLocation < line.length {
            let searchRange = NSRange(
                location: searchLocation,
                length: line.length - searchLocation
            )
            let hit = line.range(of: word, options: .literal, range: searchRange)
            if hit.location == NSNotFound { break }
            matches.append(hit)
            searchLocation = NSMaxRange(hit)
            if wordNS.length == 0 { break }
        }
        guard !matches.isEmpty else { return nil }

        let chosen = matches.min { lhs, rhs in
            abs(lhs.location - expectedColumnUTF16) < abs(rhs.location - expectedColumnUTF16)
        }!

        var offset = 0
        for i in 0 ..< row {
            offset += (lines[i] as NSString).length + 1 // +1 for "\n"
        }

        let result = NSRange(location: offset + chosen.location, length: chosen.length)
        guard NSMaxRange(result) <= nsText.length else { return nil }
        return result
    }
}
