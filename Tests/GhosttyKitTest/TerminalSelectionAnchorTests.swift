import Foundation
@testable import GhosttyTerminal
import Testing

// The anchor is ghostty's `offset_start`, the word's first cell as a linear
// index into the viewport grid (`row * columns + column`), together with the
// grid width. Both are cell counts: window padding, the font baseline and
// the display scale never enter, which is why the pixel variant below is only
// exercised for its input guards. An 80-column grid unless noted.

struct TerminalSelectionAnchorTests {
    @Test
    func `single line ASCII`() {
        let range = TerminalSelectionAnchor.resolveRange(
            in: "hello world",
            word: "world",
            offsetStart: 6, columns: 80
        )
        #expect(range == NSRange(location: 6, length: 5))
    }

    @Test
    func `multi line locates row`() {
        let range = TerminalSelectionAnchor.resolveRange(
            in: "aaa\nbbb\nworld",
            word: "world",
            offsetStart: 2 * 80, columns: 80
        )
        #expect(range == NSRange(location: 8, length: 5))
    }

    @Test
    func `same word across rows only picks target row`() {
        let range = TerminalSelectionAnchor.resolveRange(
            in: "foo\nfoo\nfoo",
            word: "foo",
            offsetStart: 1 * 80, columns: 80
        )
        #expect(range == NSRange(location: 4, length: 3))
    }

    @Test
    func `empty rows preserved`() {
        let range = TerminalSelectionAnchor.resolveRange(
            in: "\n\nhello",
            word: "hello",
            offsetStart: 2 * 80, columns: 80
        )
        #expect(range == NSRange(location: 2, length: 5))
    }

    @Test
    func `offset in the middle of a row maps to that row and column`() {
        // Row 2, column 37 in an 80-column grid, with the same word earlier
        // on the row and the snapshot lines far shorter than the grid: the
        // row comes from the grid width, the pick from the column.
        let row2 = "   cat" + String(repeating: " ", count: 31) + "cat"
        let text = "row0\nrow1\n" + row2
        let range = TerminalSelectionAnchor.resolveRange(
            in: text,
            word: "cat",
            offsetStart: 2 * 80 + 37, columns: 80
        )
        #expect(range == NSRange(location: 10 + 37, length: 3))
    }

    @Test
    func `row follows the grid width, not the line length`() {
        // A 10-column grid: offset 10 is the first cell of row 1 even though
        // row 0 is shorter than the grid.
        let range = TerminalSelectionAnchor.resolveRange(
            in: "ab\nabc",
            word: "abc",
            offsetStart: 10, columns: 10
        )
        #expect(range == NSRange(location: 3, length: 3))
    }

    @Test
    func `word not found returns nil`() {
        let range = TerminalSelectionAnchor.resolveRange(
            in: "abc",
            word: "xyz",
            offsetStart: 0, columns: 80
        )
        #expect(range == nil)
    }

    @Test
    func `row out of bounds returns nil`() {
        let range = TerminalSelectionAnchor.resolveRange(
            in: "abc",
            word: "abc",
            offsetStart: 5 * 80, columns: 80
        )
        #expect(range == nil)
    }

    @Test
    func `zero columns returns nil`() {
        let range = TerminalSelectionAnchor.resolveRange(
            in: "abc",
            word: "abc",
            offsetStart: 0, columns: 0
        )
        #expect(range == nil)
    }

    @Test
    func `emoji surrogate pair`() {
        let text = "hi 👋"
        let range = TerminalSelectionAnchor.resolveRange(
            in: text,
            word: "👋",
            offsetStart: 3, columns: 80
        )
        let nsText = text as NSString
        #expect(range != nil)
        if let r = range {
            #expect(r == NSRange(location: 3, length: 2))
            #expect(NSMaxRange(r) <= nsText.length)
        }
    }

    @Test
    func `cjk full width`() {
        let range = TerminalSelectionAnchor.resolveRange(
            in: "你好 world",
            word: "你好",
            offsetStart: 0, columns: 80
        )
        #expect(range == NSRange(location: 0, length: 2))
    }

    @Test
    func `empty word`() {
        let range = TerminalSelectionAnchor.resolveRange(
            in: "abc", word: "",
            offsetStart: 0, columns: 80
        )
        #expect(range == nil)
    }

    @Test
    func `substring disambiguation by column`() {
        // `catalog cat` long-pressed at the end `cat` (column 8) — must pick
        // the standalone `cat` at location 8, not the prefix inside `catalog`
        // at location 0. literals at {0, 8}, expectedColumn=8 → 8.
        let range = TerminalSelectionAnchor.resolveRange(
            in: "catalog cat",
            word: "cat",
            offsetStart: 8, columns: 80
        )
        #expect(range == NSRange(location: 8, length: 3))
    }

    @Test
    func `triple repeat picked by column`() {
        // literals at {0, 4, 8}, expectedColumn=8 → 8.
        let range = TerminalSelectionAnchor.resolveRange(
            in: "cat cat cat",
            word: "cat",
            offsetStart: 8, columns: 80
        )
        #expect(range == NSRange(location: 8, length: 3))
    }

    @Test
    func `non word characters in token`() {
        // literals at {4, 15}, expectedColumn=15 → 15.
        let range = TerminalSelectionAnchor.resolveRange(
            in: "see /usr/local /usr/local",
            word: "/usr/local",
            offsetStart: 15, columns: 80
        )
        #expect(range == NSRange(location: 15, length: 10))
    }

    @Test
    func `non word prefix token`() {
        // literals at {1, 6}, expectedColumn=6 → 6.
        let range = TerminalSelectionAnchor.resolveRange(
            in: "x/foo /foo",
            word: "/foo",
            offsetStart: 6, columns: 80
        )
        #expect(range == NSRange(location: 6, length: 4))
    }
}
