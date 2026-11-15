import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// The view state's `onSearch`: every report the bridge hands it, and a
/// search driven by binding actions on a live surface.
@Suite("TerminalViewStateSearch", .serialized)
@MainActor
struct TerminalViewStateSearchTests {
    @Test
    func `every search report reaches the host, in order`() {
        let state = TerminalViewState()
        var events: [TerminalSearchEvent] = []
        state.onSearch = { events.append($0) }
        let bridge = TerminalCallbackBridge(delegate: state)

        "picked".withCString { pointer in
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_START_SEARCH
            action.action.start_search.needle = pointer
            bridge.handleAction(action)
        }
        for total in [2, -1] {
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_SEARCH_TOTAL
            action.action.search_total.total = total
            bridge.handleAction(action)
        }
        for selected in [-1, 0, -1] {
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_SEARCH_SELECTED
            action.action.search_selected.selected = selected
            bridge.handleAction(action)
        }
        var end = ghostty_action_s()
        end.tag = GHOSTTY_ACTION_END_SEARCH
        bridge.handleAction(end)

        #expect(events == [
            .started(needle: "picked"),
            .total(2), .total(nil),
            .selected(nil), .selected(0), .selected(nil),
            .ended,
        ])
    }

    @Test
    func `a search on a live surface reports its count and selection, and its end`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let state = TerminalViewState()
        var events: [TerminalSearchEvent] = []
        state.onSearch = { events.append($0) }
        harness.coordinator.delegate = state
        harness.receive("needle one\r\nhay\r\nNEEDLE two\r\nhay\r\n")
        _ = await harness.drain()
        let surface = harness.surface

        // ASCII case does not count: both lines match.
        #expect(surface?.performBindingAction("search:needle") == true)
        await Self.wait { events.contains(.total(2)) }
        #expect(events.contains(.total(2)))

        #expect(surface?.performBindingAction("navigate_search:next") == true)
        await Self.wait { events.contains(.selected(0)) }
        #expect(events.contains(.selected(0)))

        // A new needle drops the selection before it counts again.
        events.removeAll()
        _ = surface?.performBindingAction("search:needl")
        await Self.wait { events.contains(.total(2)) }
        #expect(events.contains(.selected(nil)))
        #expect(events.contains(.total(2)))

        // An empty needle stops the search; it is not an end.
        events.removeAll()
        _ = surface?.performBindingAction("search:")
        await Self.wait { events.contains(.total(nil)) }
        #expect(events.contains(.total(nil)))
        #expect(!events.contains(.ended))

        // Ended at once: the action and its report are on the main thread.
        _ = surface?.performBindingAction("search:needle")
        await Self.wait { events.contains(.total(2)) }
        events.removeAll()
        _ = surface?.performBindingAction("end_search")
        #expect(events.first == .ended)
    }

    @Test
    func `end_search is reported with no search running`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let state = TerminalViewState()
        var events: [TerminalSearchEvent] = []
        state.onSearch = { events.append($0) }
        harness.coordinator.delegate = state
        _ = await harness.drain()

        _ = harness.surface?.performBindingAction("end_search")

        #expect(events == [.ended])
    }

    private static func wait(until condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
