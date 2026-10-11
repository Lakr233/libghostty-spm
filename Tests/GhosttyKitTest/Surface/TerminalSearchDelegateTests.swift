@testable import GhosttyTerminal
import Testing

@MainActor
struct TerminalSearchDelegateTests {
    @MainActor
    private final class SearchRecorder: TerminalSurfaceSearchDelegate {
        var startedNeedles: [String] = []
        var endCount = 0
        var totals: [Int?] = []
        var selections: [Int?] = []

        func terminalDidStartSearch(needle: String) {
            startedNeedles.append(needle)
        }

        func terminalDidEndSearch() {
            endCount += 1
        }

        func terminalDidUpdateSearchTotal(_ total: Int?) {
            totals.append(total)
        }

        func terminalDidUpdateSearchSelected(_ selected: Int?) {
            selections.append(selected)
        }
    }

    /// 300 lines with "needle" on three of them.
    private static let output = (1 ... 300).map { line in
        [10, 150, 200].contains(line) ? "line-\(line) needle" : "line-\(line)"
    }.joined(separator: "\r\n")

    private func waitUntil(_ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(15)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func searchForNeedle() async throws -> (GhosttySurfaceHarness, SearchRecorder, TerminalSurface) {
        let harness = await GhosttySurfaceHarness.make()
        let recorder = SearchRecorder()
        harness.coordinator.delegate = recorder
        harness.receive(Self.output)
        let surface = try #require(harness.surface)
        #expect(surface.performBindingAction("search:needle"))
        await waitUntil { recorder.totals.last == .some(3) }
        return (harness, recorder, surface)
    }

    @Test
    func `search reports its total and selects nothing until the host navigates`() async throws {
        let (harness, recorder, _) = try await searchForNeedle()
        defer { harness.tearDown() }

        #expect(recorder.totals.last == .some(3))
        #expect(recorder.selections.allSatisfy { $0 == nil })
    }

    // Ghostty numbers matches from 0, newest first. Moving on from a selected
    // match isn't asserted here: Ghostty can drop and reselect the first match
    // on its search thread right after selecting it.
    @Test
    func `the first next selects the newest match as index 0`() async throws {
        let (harness, recorder, surface) = try await searchForNeedle()
        defer { harness.tearDown() }

        #expect(surface.performBindingAction("navigate_search:next"))

        await waitUntil { recorder.selections.contains(0) }
        #expect(recorder.selections.contains(0))
    }

    @Test
    func `the first previous selects the oldest match as the last index`() async throws {
        let (harness, recorder, surface) = try await searchForNeedle()
        defer { harness.tearDown() }

        #expect(surface.performBindingAction("navigate_search:previous"))

        await waitUntil { recorder.selections.contains(2) }
        #expect(recorder.selections.contains(2))
    }

    @Test
    func `ending the search clears its total and reports the end`() async throws {
        let (harness, recorder, surface) = try await searchForNeedle()
        defer { harness.tearDown() }

        #expect(surface.performBindingAction("end_search"))

        await waitUntil { recorder.totals.last == .some(nil) }
        #expect(recorder.endCount == 1)
        #expect(recorder.totals.last == .some(nil))
    }

    @Test
    func `start_search asks the host for its find UI with an empty needle`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let recorder = SearchRecorder()
        harness.coordinator.delegate = recorder
        let surface = try #require(harness.surface)

        _ = surface.performBindingAction("start_search")

        await waitUntil { !recorder.startedNeedles.isEmpty }
        #expect(recorder.startedNeedles == [""])
    }
}
