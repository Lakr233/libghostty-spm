import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// `receiveReplay` feeds bytes the terminal has seen before. They are parsed
/// like any output, in their place among the live writes, through the entry
/// that drops the replies their queries would trigger.
struct InMemoryTerminalSessionReplayTests {
    @Test
    func `a replay keeps its place among live writes and takes the replay entry`() {
        let events = LockedValues<String>()
        let session = makeSession(events)
        session.setSurface(testSurface(0x110))

        session.receive("before")
        session.receiveReplay(Data("history".utf8))
        session.receive("after")
        session.finish(exitCode: 0, runtimeMilliseconds: 0)
        #expect(session.waitForPendingOutput())

        #expect(events.values == ["write:before", "replay:history", "write:after", "exit:0"])
    }

    @Test
    func `an empty replay queues nothing`() {
        let events = LockedValues<String>()
        let session = makeSession(events)
        session.setSurface(testSurface(0x120))

        session.receiveReplay(Data())
        #expect(session.pendingOutputByteCount == 0)
        #expect(session.waitForPendingOutput())
        #expect(events.values.isEmpty)
    }

    /// With no surface the live output is capped at 1 MiB, oldest bytes
    /// first. A replay waiting there is neither cut nor counted against the
    /// cap, and the live bytes on either side of it stay separate writes.
    @Test
    func `a replay received with no surface waits whole for the next one`() {
        let events = LockedValues<String>()
        let sizes = LockedValues<Int>()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, data in
                events.append("write")
                sizes.append(data.count)
            },
            surfaceReplay: { _, data in
                events.append("replay")
                sizes.append(data.count)
            },
        )
        let replay = Data(repeating: 0x72, count: 3 << 20)

        session.receive(Data(repeating: 0x61, count: 512))
        session.receiveReplay(replay)
        session.receive(Data(repeating: 0x62, count: 512))
        #expect(session.pendingOutputByteCount == replay.count + 1024)

        session.setSurface(testSurface(0x130))
        #expect(session.waitForPendingOutput())

        #expect(events.values == ["write", "replay", "write"])
        #expect(sizes.values == [512, replay.count, 512])
        #expect(session.pendingOutputByteCount == 0)
    }

    /// A host pausing its transport on the backlog handler has to hear about
    /// a replay too: it is as many bytes ahead of the parser as live output.
    @Test
    func `a queued replay counts towards the backlog`() {
        let gate = DispatchSemaphore(value: 0)
        let backlog = LockedValues<Bool>()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, _ in gate.wait() },
        )
        session.setOutputBacklogHandler(highWater: 4096, lowWater: 1024) { backlog.append($0) }
        session.setSurface(testSurface(0x140))

        session.receive("x")
        session.receiveReplay(Data(repeating: 0x72, count: 8192))
        #expect(backlog.values == [true])
        #expect(session.pendingOutputByteCount >= 8192)

        gate.signal()
        gate.signal()
        #expect(session.waitForPendingOutput())
        #expect(backlog.values == [true, false])
    }
}

/// The same bytes through both entries of a real surface: the queries are
/// answered when they arrive live and not when they are replayed, and the
/// text between them reaches the screen either way.
@MainActor
struct InMemoryTerminalSessionReplaySurfaceTests {
    /// Cursor position, colour and status queries. Device attributes are
    /// left out: `drain` asks for those itself to mark the end of the
    /// outbound bytes.
    private static let history = "replayed\u{1B}[6n\u{1B}]11;?\u{07}\u{1B}[5n"

    @Test(.timeLimit(.minutes(1)))
    func `queries received live are answered`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }

        _ = await harness.takeOutbound()
        harness.session.receive(Data(Self.history.utf8))
        harness.session.waitForPendingOutput()
        let outbound = await harness.drain()

        #expect(outbound.count(of: "\u{1B}[1;9R") == 1)
        #expect(outbound.count(of: "\u{1B}[0n") == 1)
        #expect(firstLine(of: harness).hasPrefix("replayed"))
    }

    @Test(.timeLimit(.minutes(1)))
    func `queries in a replay are parsed and not answered`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }

        _ = await harness.takeOutbound()
        harness.session.receiveReplay(Data(Self.history.utf8))
        harness.session.waitForPendingOutput()
        let outbound = await harness.drain()

        #expect(outbound.isEmpty)
        #expect(firstLine(of: harness).hasPrefix("replayed"))
    }

    private func firstLine(of harness: GhosttySurfaceHarness) -> String {
        harness.session.readViewportText()?
            .components(separatedBy: "\n").first ?? ""
    }
}

private func makeSession(_ events: LockedValues<String>) -> InMemoryTerminalSession {
    InMemoryTerminalSession(
        write: { _ in },
        resize: { _ in },
        surfaceWrite: { _, data in
            events.append("write:" + String(decoding: data, as: UTF8.self))
        },
        surfaceReplay: { _, data in
            events.append("replay:" + String(decoding: data, as: UTF8.self))
        },
        processExit: { _, exitCode, _ in
            events.append("exit:\(exitCode)")
        },
    )
}

private func testSurface(_ address: Int) -> ghostty_surface_t {
    UnsafeMutableRawPointer(bitPattern: address)!
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
