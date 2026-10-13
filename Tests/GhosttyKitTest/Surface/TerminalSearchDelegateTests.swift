import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// The bridge hands the core's search actions to a `TerminalSurfaceSearchDelegate`,
/// with no live surface behind it.
@MainActor
struct TerminalSearchDelegateTests {
    @Test
    func `start search forwards the needle`() {
        let (bridge, probe) = Self.bridge()

        "marker".withCString { pointer in
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_START_SEARCH
            action.action.start_search.needle = pointer
            bridge.handleAction(action)
        }

        #expect(probe.events == [.start("marker")])
    }

    @Test
    func `start search without a needle arrives as nil`() {
        let (bridge, probe) = Self.bridge()

        var missing = ghostty_action_s()
        missing.tag = GHOSTTY_ACTION_START_SEARCH
        missing.action.start_search.needle = nil
        bridge.handleAction(missing)
        "".withCString { pointer in
            var empty = ghostty_action_s()
            empty.tag = GHOSTTY_ACTION_START_SEARCH
            empty.action.start_search.needle = pointer
            bridge.handleAction(empty)
        }

        #expect(probe.events == [.start(nil), .start(nil)])
    }

    @Test
    func `total and selected forward counts, unknown ones as nil`() {
        let (bridge, probe) = Self.bridge()

        for total in [3, -1] {
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_SEARCH_TOTAL
            action.action.search_total.total = total
            bridge.handleAction(action)
        }
        for selected in [0, -1] {
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_SEARCH_SELECTED
            action.action.search_selected.selected = selected
            bridge.handleAction(action)
        }

        #expect(probe.events == [.total(3), .total(nil), .selected(0), .selected(nil)])
    }

    @Test
    func `end search forwards`() {
        let (bridge, probe) = Self.bridge()

        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_END_SEARCH
        bridge.handleAction(action)

        #expect(probe.events == [.end])
    }

    @Test
    func `a delegate without search conformance is skipped`() {
        let bridge = TerminalCallbackBridge()
        let delegate = PlainDelegate()
        bridge.delegate = delegate

        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_SEARCH_TOTAL
        action.action.search_total.total = 2
        bridge.handleAction(action)

        withExtendedLifetime(delegate) {}
    }

    private static func bridge() -> (TerminalCallbackBridge, SearchProbe) {
        let bridge = TerminalCallbackBridge()
        let probe = SearchProbe()
        bridge.delegate = probe
        return (bridge, probe)
    }
}

@MainActor
private final class SearchProbe: TerminalSurfaceSearchDelegate {
    enum Event: Equatable {
        case start(String?)
        case end
        case total(Int?)
        case selected(Int?)
    }

    var events: [Event] = []

    func terminalDidStartSearch(needle: String?) {
        events.append(.start(needle))
    }

    func terminalDidEndSearch() {
        events.append(.end)
    }

    func terminalDidUpdateSearchTotal(_ total: Int?) {
        events.append(.total(total))
    }

    func terminalDidUpdateSearchSelected(_ selected: Int?) {
        events.append(.selected(selected))
    }
}

private final class PlainDelegate: TerminalSurfaceViewDelegate {}
