import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// The view state's link closures: the link under the pointer, and a link
/// the user activated, which Ghostty opens itself only while the host has
/// no closure for it.
@Suite("TerminalViewStateLink", .serialized)
@MainActor
struct TerminalViewStateLinkTests {
    @Test
    func `Ghostty opens a URL itself until the host takes it`() {
        let state = TerminalViewState()
        let bridge = TerminalCallbackBridge(delegate: state)
        #expect(!bridge.handlesOpenURL)

        state.onOpenURL = { _, _ in }
        #expect(bridge.handlesOpenURL)

        state.onOpenURL = nil
        #expect(!bridge.handlesOpenURL)
    }

    @Test
    func `an activated link reaches the host`() {
        let state = TerminalViewState()
        var opened: [String] = []
        state.onOpenURL = { url, _ in opened.append(url) }

        Self.openURL("https://example.com/pull/1", through: TerminalCallbackBridge(delegate: state))

        #expect(opened == ["https://example.com/pull/1"])
    }

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
        state.onOpenURL = { url, _ in opened.append(url) }
        harness.coordinator.delegate = state
        harness.receive("\u{1B}]8;;https://example.com/pull/1\u{1B}\\the pull request\u{1B}]8;;\u{1B}\\ end")
        _ = await harness.drain()
        let surface = harness.surface

        surface?.sendMousePos(x: 30, y: 8, modifiers: .super_)
        surface?.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, modifiers: .super_)
        surface?.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, modifiers: .super_)

        #expect(opened == ["https://example.com/pull/1"])
    }

    private static func openURL(_ url: String, through bridge: TerminalCallbackBridge) {
        url.withCString { pointer in
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_OPEN_URL
            action.action.open_url.url = pointer
            action.action.open_url.len = numericCast(url.utf8.count)
            bridge.handleAction(action)
        }
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
