import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// `readScreenText(fromRow:)` read off a live surface: from a screen row to
/// the end, without touching the selection or the program's input.
@MainActor
struct TerminalReadScreenTextTests {
    private func numberedLines(_ count: Int) -> String {
        (1 ... count).map(String.init).joined(separator: "\r\n")
    }

    @Test
    func `the whole screen from the top of the scrollback`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)
        harness.receive(numberedLines(200))

        let text = try #require(surface.readScreenText())
        #expect(text.hasPrefix("1\n2\n"))
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("\n200"))
    }

    @Test
    func `a row in the scrollback starts the read there`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)
        harness.receive(numberedLines(200))

        let text = try #require(surface.readScreenText(fromRow: 9))
        #expect(text.hasPrefix("10\n11\n"))
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("\n200"))
    }

    @Test
    func `a soft-wrapped row reads as one line`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)
        // The harness never resizes the terminal to the view, so the width
        // rows wrap at is the selection region's, not `size()`'s.
        harness.receive("x")
        #expect(surface.performBindingAction("select_all"))
        let columns = try #require(surface.selectionRegion()).columns
        let long = String(String(repeating: "abcdefghij", count: columns / 10 + 2).prefix(columns + 5))
        harness.receive("\r\n\(long)\r\nnext")

        let text = try #require(surface.readScreenText(fromRow: 1))
        #expect(text.hasPrefix(long + "\nnext"))
    }

    @Test
    func `a row past the screen reads as empty text`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)
        harness.receive(numberedLines(10))

        #expect(surface.readScreenText(fromRow: 100_000) == "")
    }

    @Test
    func `a negative row reads nil`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)

        #expect(surface.readScreenText(fromRow: -1) == nil)
    }

    @Test
    func `reading leaves the selection alone`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)
        harness.receive(numberedLines(5))

        #expect(!surface.hasSelection())
        _ = surface.readScreenText()
        #expect(!surface.hasSelection())

        #expect(surface.performBindingAction("select_all"))
        _ = surface.readScreenText(fromRow: 2)
        #expect(surface.hasSelection())
    }

    @Test
    func `a freed surface reads nil`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        let surface = try #require(harness.surface)
        harness.receive("hello")
        harness.tearDown()

        #expect(surface.readScreenText() == nil)
    }
}
