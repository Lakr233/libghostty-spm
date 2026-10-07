import Foundation
@testable import GhosttyTerminal
import Testing

struct TerminalPasteboardContentTests {
    @Test
    func `a file url beats the string a Finder copy puts beside it`() {
        let text = TerminalPasteboardContent.text(
            string: "Screenshot 2026-08-29 at 12.12.09 AM",
            urls: [URL(fileURLWithPath: "/Users/me/Desktop/Screenshot 2026-08-29 at 12.12.09 AM.png")],
        )
        #expect(text == "/Users/me/Desktop/Screenshot\\ 2026-08-29\\ at\\ 12.12.09\\ AM.png")
    }

    @Test
    func `several file urls paste space separated`() {
        let text = TerminalPasteboardContent.text(
            string: nil,
            urls: [URL(fileURLWithPath: "/tmp/a b"), URL(fileURLWithPath: "/tmp/c")],
        )
        #expect(text == "/tmp/a\\ b /tmp/c")
    }

    @Test
    func `other urls paste verbatim`() throws {
        let url = try #require(URL(string: "https://example.com/path?q=1"))
        #expect(TerminalPasteboardContent.text(string: "ignored", urls: [url]) == "https://example.com/path?q=1")
    }

    @Test
    func `the string is the fallback and empty means nothing`() {
        #expect(TerminalPasteboardContent.text(string: "ls -la", urls: []) == "ls -la")
        #expect(TerminalPasteboardContent.text(string: "", urls: []) == nil)
        #expect(TerminalPasteboardContent.text(string: nil, urls: []) == nil)
    }
}

#if !canImport(UIKit) && canImport(AppKit)
    import AppKit

    /// A mode 5522 list request reports presence only; `hasText(in:)`
    /// answers it without reading the contents and agrees with `text(from:)`.
    struct TerminalPasteboardPresenceTests {
        @Test
        func `presence follows what the text reader would find`() {
            let pasteboard = NSPasteboard(name: .init("ghostty-test-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }

            pasteboard.clearContents()
            #expect(!TerminalPasteboardContent.hasText(in: pasteboard))
            #expect(TerminalPasteboardContent.text(from: pasteboard) == nil)

            pasteboard.clearContents()
            pasteboard.setString("ls -la", forType: .string)
            #expect(TerminalPasteboardContent.hasText(in: pasteboard))

            pasteboard.clearContents()
            pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a b") as NSURL])
            #expect(TerminalPasteboardContent.hasText(in: pasteboard))
            #expect(TerminalPasteboardContent.text(from: pasteboard) == "/tmp/a\\ b")

            pasteboard.clearContents()
            pasteboard.setData(Data([0x89, 0x50]), forType: .png)
            #expect(!TerminalPasteboardContent.hasText(in: pasteboard))
        }
    }
#endif
