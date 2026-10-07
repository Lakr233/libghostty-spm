import Foundation
import GhosttyKit
@testable import GhosttyTerminal
@testable import ShellCraftKit
import Testing

/// ShellCraftKit's cursor math must agree with the cells Ghostty draws, so
/// each sample is printed on a real surface and its width read back through
/// a cursor position report.
@MainActor
struct ShellCraftGhosttyWidthTests {
    nonisolated static let samples = [
        "abc",
        "你好",
        "e\u{0301}",
        "\u{1F680}",
        "\u{2764}\u{FE0F}",
        "\u{1F44D}\u{1F3FD}",
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
        "\u{1F1EF}\u{1F1F5}",
        "1\u{FE0F}\u{20E3}",
        "\u{1100}\u{1161}\u{11A8}",
        "\u{1F1EF}",
        "\u{231A}\u{FE0E}",
        "a\u{FE0F}",
        "\u{00A9}\u{FE0F}",
        "\u{1B}[1;31m$\u{1B}[0m ",
        "\u{1B}]133;A\u{07}$ ",
        "\u{1B}]2;title\u{1B}\\$ ",
        "\u{1B}(B$ ",
        "a\u{1F44D}\u{1F3FD}b\u{2764}\u{FE0F}c",
    ]

    @Test(arguments: samples)
    func `display width matches the cells Ghostty draws`(_ sample: String) async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        guard harness.surface != nil else { return }

        #expect(await sample.terminalDisplayWidth == drawnWidth(of: sample, in: harness))
    }

    private func drawnWidth(of text: String, in harness: GhosttySurfaceHarness) async -> Int? {
        harness.receive("\u{1B}[H\u{1B}[2J")
        harness.session.receive(Data("\(text)\u{1B}[6n".utf8))
        let reply = await String(decoding: harness.drain(), as: UTF8.self)
        guard let semicolon = reply.lastIndex(of: ";"),
              let end = reply[semicolon...].firstIndex(of: "R"),
              let column = Int(reply[reply.index(after: semicolon) ..< end])
        else {
            Issue.record("no cursor position report in \(reply.debugDescription)")
            return nil
        }
        return column - 1
    }
}
