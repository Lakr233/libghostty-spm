import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// The view state's link closures on a live surface: the link under the
/// pointer, and a Cmd-click's way from Ghostty to `onOpenURL`. What the
/// closure's answer means is in `TerminalOpenURLDelegateTests`.
@Suite("TerminalViewStateLink", .serialized)
@MainActor
struct TerminalViewStateLinkTests {
    @Test
    func `a link under the pointer reaches the host, and its end as nil`() {
        let state = TerminalViewState()
        var hovered: [String?] = []
        state.onHoverLink = { hovered.append($0) }
        let bridge = TerminalCallbackBridge(delegate: state)

        Self.hover("https://example.com/a", through: bridge)
        Self.hover("", through: bridge)

        #expect(hovered == ["https://example.com/a", nil])
    }

    @Test
    func `an OSC 8 hyperlink under a Cmd-held pointer reports its URI before the move returns, and nil after it leaves`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let state = TerminalViewState()
        var hovered: [String?] = []
        state.onHoverLink = { hovered.append($0) }
        harness.coordinator.delegate = state
        harness.receive("\u{1B}]8;;https://example.com/pull/1\u{1B}\\the pull request\u{1B}]8;;\u{1B}\\ end")
        _ = await harness.drain()
        let surface = harness.surface

        surface?.sendMousePos(x: 30, y: 8, modifiers: .super_)
        #expect(hovered == ["https://example.com/pull/1"])

        surface?.sendMousePos(x: 30, y: 200, modifiers: .super_)
        #expect(hovered == ["https://example.com/pull/1", nil])
    }

    @Test
    func `a Cmd-click on an OSC 8 hyperlink hands its URI to the host`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let state = TerminalViewState()
        var opened: [String] = []
        state.onOpenURL = { url, _ in
            opened.append(url)
            return true
        }
        harness.coordinator.delegate = state
        harness.receive("\u{1B}]8;;https://example.com/pull/1\u{1B}\\the pull request\u{1B}]8;;\u{1B}\\ end")
        _ = await harness.drain()
        let surface = harness.surface

        surface?.sendMousePos(x: 30, y: 8, modifiers: .super_)
        surface?.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, modifiers: .super_)
        surface?.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, modifiers: .super_)

        #expect(opened == ["https://example.com/pull/1"])
    }

    @Test
    func `a link probe captures detected and OSC 8 links without notifying hover or mouse shape`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let state = TerminalViewState()
        var hovered: [String?] = []
        var shapes: [ghostty_action_mouse_shape_e] = []
        var opened: [String] = []
        state.onHoverLink = { hovered.append($0) }
        state.onOpenURL = { url, _ in
            opened.append(url)
            return true
        }
        harness.coordinator.delegate = state
        harness.coordinator.bridge.onMouseShape = { shapes.append($0) }
        harness.receive(
            "https://example.com/web\r\n"
                + "\u{1B}]8;;https://example.com/osc8\u{1B}\\osc8-web\u{1B}]8;;\u{1B}\\\r\n"
                + "\u{1B}]8;;mailto:test@example.com\u{1B}\\mail-link\u{1B}]8;;\u{1B}\\\r\n"
                + "plain text only",
        )
        _ = await harness.drain()
        let surface = harness.surface
        let metrics = surface?.size()
        let rowHeight = Double(metrics?.cellHeightPixels ?? 16)

        func probe(row: Int, click: Bool = false) -> TerminalLinkProbe {
            let y = (Double(row) + 0.5) * rowHeight
            surface?.sendMousePos(x: -1, y: -1, mods: GHOSTTY_MODS_NONE)
            harness.coordinator.bridge.linkProbe = TerminalLinkProbe()
            defer {
                surface?.sendMousePos(x: -1, y: -1, mods: GHOSTTY_MODS_NONE)
                harness.coordinator.bridge.linkProbe = nil
            }
            surface?.sendMousePos(x: 20, y: y, modifiers: .super_)
            if click {
                surface?.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, modifiers: .super_)
                surface?.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, modifiers: .super_)
            }
            return harness.coordinator.bridge.linkProbe ?? TerminalLinkProbe()
        }

        // Settle initial off-view state before counting stray notifications.
        surface?.sendMousePos(x: -1, y: -1, mods: GHOSTTY_MODS_NONE)
        hovered.removeAll()
        shapes.removeAll()

        let webFirst = probe(row: 0)
        let webSecond = probe(row: 0, click: true)
        let osc8Web = probe(row: 1, click: true)
        let osc8Mail = probe(row: 2)
        let plain = probe(row: 3)

        #expect(webFirst.found)
        #expect(webFirst.url == "https://example.com/web")
        #expect(!webFirst.opened)
        #expect(webSecond.found)
        #expect(webSecond.url == "https://example.com/web")
        #expect(webSecond.opened)
        #expect(osc8Web.found)
        #expect(osc8Web.url == "https://example.com/osc8")
        #expect(osc8Web.opened)
        #expect(osc8Mail.found)
        #expect(osc8Mail.url == "mailto:test@example.com")
        #expect(!plain.found)
        #expect(plain.url == nil)
        #expect(opened == ["https://example.com/web", "https://example.com/osc8"])
        #expect(hovered.isEmpty)
        #expect(shapes.isEmpty)

        // When the host declines or leaves onOpenURL nil, opened stays false.
        state.onOpenURL = nil
        let unhandled = probe(row: 0, click: true)
        #expect(unhandled.found)
        #expect(unhandled.url == "https://example.com/web")
        #expect(!unhandled.opened)
    }

    private static func hover(_ url: String, through bridge: TerminalCallbackBridge) {
        url.withCString { pointer in
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_MOUSE_OVER_LINK
            action.action.mouse_over_link.url = pointer
            action.action.mouse_over_link.len = numericCast(url.utf8.count)
            bridge.handleAction(action)
        }
    }
}
