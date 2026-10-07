import Foundation
@testable import GhosttyTerminal
import Testing

struct TerminalInputDocumentTests {
    /// UIKit ends a held software-keyboard Delete when the selection starts
    /// at `beginningOfDocument`; at an empty prompt the caret must not.
    @Test
    func `empty document keeps the caret off its beginning`() {
        let document = TerminalInputDocument(anchorLength: 1, markedLength: 0)

        #expect(document.length == 1)
        #expect(document.position(ofMarkedOffset: 0) == 1)
    }

    @Test
    func `positions round trip through marked offsets`() {
        let document = TerminalInputDocument(anchorLength: 1, markedLength: 4)

        for offset in 0 ... 4 {
            #expect(document.markedOffset(of: document.position(ofMarkedOffset: offset)) == offset)
        }
    }

    @Test
    func `positions outside the marked text clamp to its ends`() {
        let document = TerminalInputDocument(anchorLength: 1, markedLength: 4)

        #expect(document.markedOffset(of: 0) == 0)
        #expect(document.markedOffset(of: -3) == 0)
        #expect(document.markedOffset(of: 99) == 4)
        #expect(document.position(ofMarkedOffset: -3) == 1)
        #expect(document.position(ofMarkedOffset: 99) == 5)
    }

    @Test(arguments: [
        (NSRange(location: 0, length: 1), NSRange(location: 0, length: 0)),
        (NSRange(location: 0, length: 3), NSRange(location: 0, length: 2)),
        (NSRange(location: 2, length: 2), NSRange(location: 1, length: 2)),
        (NSRange(location: 1, length: 4), NSRange(location: 0, length: 4)),
        (NSRange(location: 4, length: 9), NSRange(location: 3, length: 1)),
        (NSRange(location: 7, length: 2), NSRange(location: 4, length: 0)),
        (NSRange(location: 3, length: -2), NSRange(location: 2, length: 0)),
    ])
    func `marked range keeps only the part over the marked text`(
        documentRange: NSRange,
        markedRange: NSRange,
    ) {
        let document = TerminalInputDocument(anchorLength: 1, markedLength: 4)

        #expect(document.markedRange(of: documentRange) == markedRange)
    }

    @Test
    func `without an anchor document positions are marked offsets`() {
        let document = TerminalInputDocument(anchorLength: 0, markedLength: 3)

        #expect(document.length == 3)
        #expect(document.position(ofMarkedOffset: 2) == 2)
        #expect(document.markedRange(of: NSRange(location: 1, length: 2)) == NSRange(location: 1, length: 2))
    }
}
