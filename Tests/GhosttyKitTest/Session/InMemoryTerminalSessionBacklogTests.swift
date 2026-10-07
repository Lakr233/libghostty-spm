import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// `receive` never blocks, so a transport faster than the parser queues output
/// without limit. The backlog accessor and handler are how a host applies
/// backpressure; `waitForPendingOutput` must still cover every earlier write
/// now that one drain block hands over a batch.
struct InMemoryTerminalSessionBacklogTests {
    @Test
    func `the backlog handler reports high water then low water once each`() {
        let gate = DispatchSemaphore(value: 0)
        let events = BacklogEvents()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, _ in gate.wait() },
        )
        session.setOutputBacklogHandler(highWater: 4096, lowWater: 1024) { events.append($0) }
        session.setSurface(backlogSurface)

        let chunk = Data(repeating: 0x61, count: 256)
        for _ in 0 ..< 64 {
            session.receive(chunk)
        }
        #expect(events.values == [true])
        #expect(session.pendingOutputByteCount >= 4096 - 256)

        for _ in 0 ..< 64 {
            gate.signal()
        }
        #expect(session.waitForPendingOutput())
        #expect(session.pendingOutputByteCount == 0)
        #expect(events.values == [true, false])
    }

    @Test
    func `a handler registered over an existing backlog hears it at once`() {
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, _ in },
        )
        // Detached: bytes wait for a surface.
        session.receive(Data(repeating: 0x62, count: 8192))
        let events = BacklogEvents()
        session.setOutputBacklogHandler(highWater: 4096, lowWater: 0) { events.append($0) }
        #expect(events.values == [true])

        session.setSurface(backlogSurface)
        #expect(session.waitForPendingOutput())
        #expect(events.values == [true, false])
    }

    /// More writes than one drain batch, queued behind a blocked first write:
    /// the wait must not return after the first batch.
    @Test
    func `waitForPendingOutput covers writes past one drain batch`() {
        let gate = DispatchSemaphore(value: 0)
        let sink = BacklogSink()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, data in
                if sink.count == 0 {
                    gate.wait()
                }
                sink.append(data)
            },
        )
        session.setSurface(backlogSurface)
        let writes = 1000
        for index in 0 ..< writes {
            session.receive(Data("\(index)\n".utf8))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { gate.signal() }
        #expect(session.waitForPendingOutput())
        #expect(sink.count == writes)
    }

    @Test
    func `a flood of tiny writes drains in order`() {
        let sink = BacklogSink()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, data in sink.append(data) },
        )
        session.setSurface(backlogSurface)
        var expected = Data()
        for index in 0 ..< 50000 {
            let byte = Data([UInt8(truncatingIfNeeded: index)])
            expected.append(byte)
            session.receive(byte)
        }
        #expect(session.waitForPendingOutput())
        #expect(sink.bytes == expected)
    }
}

private var backlogSurface: ghostty_surface_t {
    UnsafeMutableRawPointer(bitPattern: 0x200)!
}

private final class BacklogEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Bool) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class BacklogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private var writes = 0

    var bytes: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        writes += 1
        lock.unlock()
    }
}
