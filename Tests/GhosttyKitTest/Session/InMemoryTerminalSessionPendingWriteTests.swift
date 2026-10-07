import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// A session's transport does not pause while a view (re)builds its surface:
/// bytes that land in that gap — a daemon reattach replay, mostly — must wait
/// for the next surface instead of vanishing. These tests pin the pending
/// buffer that closes the gap.
struct InMemoryTerminalSessionPendingWriteTests {
    @Test
    func `bytes received before a surface attaches flush into it in order`() {
        let writes = LockedValues<String>()
        let session = makeSession { _, data in
            writes.append(String(decoding: data, as: UTF8.self))
        }

        session.receive("early ")
        session.receive("bytes")
        session.setSurface(testSurface(0x10))
        session.receive("later")
        session.waitForPendingOutput()

        #expect(writes.values == ["early bytes", "later"])
    }

    @Test
    func `bytes received after a surface detach wait for the next one`() {
        let writes = LockedValues<String>()
        let surface = SendableSurface(testSurface(0x20))
        let session = makeSession { _, data in
            writes.append(String(decoding: data, as: UTF8.self))
        }

        session.setSurface(surface.rawValue)
        session.receive("first")
        session.waitForPendingOutput()
        session.clearSurface(ifMatches: surface.rawValue)

        session.receive("while detached")
        session.setSurface(testSurface(0x30))
        session.waitForPendingOutput()

        #expect(writes.values == ["first", "while detached"])
    }

    /// The shell ends in the same gap its last output lands in: a `finish`
    /// with no surface must reach the next one, after the buffered bytes,
    /// or the host keeps a dead session open as live.
    @Test
    func `process exit received while detached follows the buffered bytes into the next surface`() {
        let events = LockedValues<String>()
        let surface = SendableSurface(testSurface(0x50))
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, data in
                events.append(String(decoding: data, as: UTF8.self))
            },
            processExit: { _, exitCode, runtimeMilliseconds in
                events.append("exit:\(exitCode):\(runtimeMilliseconds)")
            },
        )

        session.setSurface(surface.rawValue)
        session.receive("first")
        session.waitForPendingOutput()
        session.clearSurface(ifMatches: surface.rawValue)

        session.receive("logout\r\n")
        session.finish(exitCode: 0, runtimeMilliseconds: 5)
        session.clearSurface(ifMatches: nil)
        session.setSurface(testSurface(0x60))
        session.waitForPendingOutput()

        #expect(events.values == ["first", "logout\r\n", "exit:0:5"])
    }

    /// Detached or attached, the next surface sees the host's calls in the
    /// order they were made, and every exit among them.
    @Test
    func `output and exits received while detached keep their order`() {
        let events = LockedValues<String>()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, data in
                events.append(String(decoding: data, as: UTF8.self))
            },
            processExit: { _, exitCode, _ in
                events.append("exit:\(exitCode)")
            },
        )

        session.receive("a")
        session.finish(exitCode: 0, runtimeMilliseconds: 0)
        session.receive("b")
        session.finish(exitCode: 1, runtimeMilliseconds: 0)
        session.setSurface(testSurface(0x70))
        session.waitForPendingOutput()

        #expect(events.values == ["a", "exit:0", "b", "exit:1"])
    }

    /// Bytes waiting for a surface are not parsed, so a host that waits on
    /// them to mark a replay done must learn the wait did not cover them.
    @Test
    func `waiting for output reports bytes that still wait for a surface`() {
        let writes = LockedValues<String>()
        let session = makeSession { _, data in
            writes.append(String(decoding: data, as: UTF8.self))
        }

        #expect(session.waitForPendingOutput())
        session.receive("\u{1b}[c")
        #expect(session.waitForPendingOutput() == false)
        #expect(writes.values.isEmpty)

        session.setSurface(testSurface(0x80))
        #expect(session.waitForPendingOutput())
        #expect(writes.values == ["\u{1b}[c"])
    }

    @Test
    func `pending bytes are bounded and keep the newest tail`() {
        let writes = LockedValues<Data>()
        let session = makeSession { _, data in
            writes.append(data)
        }

        let limit = 1 << 20
        session.receive(Data(repeating: UInt8(ascii: "a"), count: limit))
        session.receive(Data(repeating: UInt8(ascii: "b"), count: 4096))
        session.setSurface(testSurface(0x40))
        session.waitForPendingOutput()

        let flushed = writes.values
        #expect(flushed.count == 1)
        #expect(flushed.first?.count == limit)
        #expect(flushed.first?.suffix(4096) == Data(repeating: UInt8(ascii: "b"), count: 4096))
    }
}

private func makeSession(
    surfaceWrite: @escaping InMemoryTerminalSurfaceAccess.Write,
) -> InMemoryTerminalSession {
    InMemoryTerminalSession(
        write: { _ in },
        resize: { _ in },
        surfaceWrite: surfaceWrite,
    )
}

private func testSurface(_ address: Int) -> ghostty_surface_t {
    UnsafeMutableRawPointer(bitPattern: address)!
}

private struct SendableSurface: @unchecked Sendable {
    let rawValue: ghostty_surface_t

    init(_ rawValue: ghostty_surface_t) {
        self.rawValue = rawValue
    }
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
