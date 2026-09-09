import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// Ghostty encodes mouse protocols. UIKit only translates physical input.
@MainActor
struct TerminalPointerReportingTests {
    @Test
    func `SGR click is encoded when mouse tracking is on`() async {
        let harness = GhosttySurfaceHarness()
        defer { harness.tearDown() }
        guard let surface = harness.surface else { return }
        harness.receive("\u{1B}[?1000h\u{1B}[?1006h")

        surface.sendMousePos(x: 12, y: 12)
        _ = surface.sendMouseButton(
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_LEFT
        )
        _ = surface.sendMouseButton(
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_LEFT
        )

        let bytes = await harness.drain()
        #expect(bytes.contains(Data("\u{1B}[<".utf8)))
    }

    @Test
    func `a click is not a mouse report when tracking is off`() async {
        let harness = GhosttySurfaceHarness()
        defer { harness.tearDown() }
        guard let surface = harness.surface else { return }

        surface.sendMousePos(x: 12, y: 12)
        _ = surface.sendMouseButton(
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_LEFT
        )
        _ = surface.sendMouseButton(
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_LEFT
        )

        let bytes = await harness.drain()
        #expect(!bytes.contains(Data("\u{1B}[<".utf8)))
        #expect(!bytes.contains(Data("\u{1B}[M".utf8)))
    }
}
