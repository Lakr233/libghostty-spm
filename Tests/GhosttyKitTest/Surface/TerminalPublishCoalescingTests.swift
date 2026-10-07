import Combine
import Foundation
@testable import GhosttyTerminal
import Testing

/// A program can retitle its window tens of thousands of times a second. One
/// main-queue block per title outran SwiftUI's flush, and the backlog kept a
/// host's main thread busy for minutes after the output stopped. These tests
/// pin the bound: one flush per turn, newest value per property.
@MainActor
@Suite(.serialized)
struct TerminalPublishCoalescingTests {
    @Test
    func `a title flood in one turn publishes once and lands on the newest title`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let state = TerminalViewState(controller: TerminalController())
        var changes = 0
        let observation = state.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        for index in 0 ..< 20000 {
            state.terminalDidChangeTitle("title-\(index)")
        }
        #expect(state.title == "")
        await LifecycleStress.drainMainQueue(turns: 1)

        #expect(state.title == "title-19999")
        #expect(changes == 1)
    }

    /// Latest-wins must not reorder: X→Y→X in one turn ends at X, and the
    /// no-change check still runs against the value at apply time.
    @Test
    func `a change back to the published value in the same turn is not lost`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let state = TerminalViewState(controller: TerminalController())
        state.terminalDidChangeTitle("X")
        await LifecycleStress.drainMainQueue(turns: 1)

        state.terminalDidChangeTitle("Y")
        state.terminalDidChangeTitle("X")
        await LifecycleStress.drainMainQueue(turns: 1)
        #expect(state.title == "X")
    }

    @Test
    func `bells coalesced into one flush are all counted`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let state = TerminalViewState(controller: TerminalController())
        for _ in 0 ..< 500 {
            state.terminalDidRingBell()
        }
        await LifecycleStress.drainMainQueue(turns: 1)
        #expect(state.bellCount == 500)
        #expect(state.lastBellAt != nil)

        state.terminalDidRingBell()
        await LifecycleStress.drainMainQueue(turns: 1)
        #expect(state.bellCount == 501)
    }

    @Test
    func `different properties in one turn all apply in one flush`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let state = TerminalViewState(controller: TerminalController())
        var changes = 0
        let observation = state.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        for index in 0 ..< 1000 {
            state.terminalDidChangeWorkingDirectory("/tmp/\(index)")
            state.terminalDidChangeTitle("t\(index)")
            state.terminalDidFinishCommand(exitCode: index, durationNanos: UInt64(index))
        }
        await LifecycleStress.drainMainQueue(turns: 1)

        #expect(state.workingDirectory == "/tmp/999")
        #expect(state.title == "t999")
        #expect(state.lastCommandExitCode == 999)
        #expect(state.lastCommandDurationNanos == 999)
        // One publish per property set in the flush, not one per event.
        #expect(changes <= 4)
    }

    /// End to end: OSC 2 parsed off the main thread, wakeups from ghostty's
    /// threads, ticks on main, the state's flush. The title must settle on
    /// the last one soon after the bytes are parsed, and the main queue must
    /// not be left holding a block per title.
    @Test
    func `an OSC 2 flood through a real surface settles on the last title`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        guard harness.surface != nil else { return }
        let state = try TerminalViewState(controller: #require(harness.coordinator.controller))
        harness.coordinator.delegate = state
        var changes = 0
        let observation = state.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        let titles = 20000
        var flood = ""
        for index in 0 ..< titles {
            flood += "\u{1B}]2;flood-\(index)\u{07}"
        }
        harness.session.receive(Data(flood.utf8))
        harness.session.waitForPendingOutput()

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while clock.now < deadline, state.title != "flood-\(titles - 1)" {
            await LifecycleStress.drainMainQueue(turns: 1)
        }
        #expect(state.title == "flood-\(titles - 1)")
        #expect(changes < titles / 10)

        // Nothing left behind: a handful of turns drains whatever remains.
        let settled = changes
        await LifecycleStress.drainMainQueue(turns: 5)
        #expect(changes - settled <= 1)
    }
}

struct TerminalWakeupGateTests {
    @Test
    func `only the first wakeup of a burst schedules a tick`() {
        let gate = TerminalWakeupGate()
        #expect(gate.claim())
        #expect(!gate.claim())
        #expect(!gate.claim())
        gate.release()
        #expect(gate.claim())
    }

    @Test
    func `concurrent wakeups claim exactly once until released`() {
        let gate = TerminalWakeupGate()
        let claims = LockedCounter()
        DispatchQueue.concurrentPerform(iterations: 10000) { _ in
            if gate.claim() {
                claims.increment()
            }
        }
        #expect(claims.value == 1)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
