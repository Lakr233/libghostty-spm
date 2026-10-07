import Foundation
@testable import GhosttyTerminal
@testable import ShellCraftKit
import Testing

/// The simulated shell under load: keystrokes from many threads, pastes cut
/// at every UTF-8 boundary, resize storms mid-typing, and multi-megabyte
/// command output. The engine is driven through the same event stream
/// `ShellSession` feeds it, against a stand-in surface that records bytes.
struct ShellCraftStressTests {
    private static let sample = "h\u{E9}llo \u{4E16}\u{754C} \u{1F389}\u{1F44D}\u{1F3FD} e\u{301} \u{0E01}\u{0E31} ok"

    /// Each write is one whole command line, as one paste would deliver it.
    /// Writers race each other, so lines may interleave by writer, but every
    /// line must run exactly once, and each writer's lines in its order.
    @Test(.timeLimit(.minutes(1)))
    func `commands written from many threads each run once in per-writer order`() async throws {
        let rig = StressShellRig()
        let (stream, events) = AsyncStream.makeStream(of: ShellSessionEvent.self)
        events.yield(.start)
        let engine = Task { await rig.engine.run(stream) }

        let writers = 8
        let commandsPerWriter = 150
        DispatchQueue.concurrentPerform(iterations: writers) { writer in
            for index in 0 ..< commandsPerWriter {
                events.yield(.write(Data("echo w\(writer)n\(index)\r".utf8)))
            }
        }
        events.finish()
        await engine.value

        let output = rig.drain()
        for writer in 0 ..< writers {
            var previous = output.startIndex
            for index in 0 ..< commandsPerWriter {
                let line = "\r\nw\(writer)n\(index)\r\n"
                let ranges = output.ranges(of: line)
                try #require(ranges.count == 1, "\(line.debugDescription) ran \(ranges.count) times")
                #expect(ranges[0].lowerBound > previous, "writer \(writer) out of order at \(index)")
                previous = ranges[0].lowerBound
            }
        }
    }

    /// A paste cut into 1…7-byte writes splits every multi-byte sequence
    /// (two-, three- and four-byte, combining marks, emoji modifiers) at
    /// every offset; the command must still receive the exact text.
    @Test(.timeLimit(.minutes(1)))
    func `a paste split at every utf-8 boundary reaches the command intact`() async {
        let rig = StressShellRig()
        await rig.engine.start()
        _ = rig.drain()

        let text = Array(repeating: Self.sample, count: 40).joined(separator: " | ")
        let bytes = Array("echo \(text)\r".utf8)
        var offset = 0
        var size = 1
        while offset < bytes.count {
            let end = min(offset + size, bytes.count)
            await rig.engine.handleOutbound(Data(bytes[offset ..< end]))
            offset = end
            size = size % 7 + 1
        }

        let output = rig.drain()
        #expect(output.hasSuffix("\r\n\(text)\r\n$ "))
    }

    /// Ghostty reports resizes from its IO thread while keystrokes arrive
    /// from the view. However they interleave, the line the user typed must
    /// be the one that runs.
    @Test(.timeLimit(.minutes(1)))
    func `resize storm interleaved with typing keeps the typed line`() async {
        let rig = StressShellRig()
        let (stream, events) = AsyncStream.makeStream(of: ShellSessionEvent.self)
        events.yield(.start)
        let engine = Task { await rig.engine.run(stream) }

        let typed = Array(repeating: "word\u{4E16}\u{1F44D}", count: 60).joined(separator: " ")
        DispatchQueue.concurrentPerform(iterations: 2) { lane in
            if lane == 0 {
                events.yield(.write(Data("echo ".utf8)))
                for character in typed {
                    events.yield(.write(Data(String(character).utf8)))
                }
            } else {
                for step in 0 ..< 3000 {
                    events.yield(.resize(InMemoryTerminalViewport(
                        columns: UInt16(10 + (step * 7) % 150),
                        rows: UInt16(5 + (step * 3) % 60),
                    )))
                }
            }
        }
        events.yield(.resize(InMemoryTerminalViewport(columns: 80, rows: 24)))
        events.yield(.write(Data("\r".utf8)))
        events.finish()
        await engine.value

        #expect(rig.drain().contains("\r\n\(typed)\r\n$ "))
    }

    @Test(.timeLimit(.minutes(1)))
    func `multi-megabyte command output reaches the surface byte-exact and in time`() async {
        let line = "\(Self.sample) \u{2014} 0123456789\r\n"
        let payload = String(repeating: line, count: 4 * 1024 * 1024 / line.utf8.count)
        let rig = StressShellRig {
            ShellCommand("flood", summary: "Print a lot") { _ in .output(payload) }
        }
        await rig.engine.start()
        _ = rig.drain()

        let clock = ContinuousClock()
        let started = clock.now
        await rig.engine.handleOutbound(Data("flood\r".utf8))
        let output = rig.drainData()
        let elapsed = clock.now - started

        // The echo, the move to the line's end, then the output and prompt.
        let expected = Data("\r\n\(payload)$ ".utf8)
        #expect(output.starts(with: Data("flood".utf8)))
        #expect(output.count == expected.count + "flood\u{1B}[8G".utf8.count)
        #expect(output.suffix(expected.count) == expected)
        #expect(elapsed < .seconds(10), "4 MiB of output took \(elapsed)")
    }

    /// Typed input as one long line: each write re-measures the whole line,
    /// so this bounds the per-keystroke cost of a long paste.
    @Test(.timeLimit(.minutes(1)))
    func `a long pasted line in chunks stays within a generous bound`() async {
        let rig = StressShellRig()
        await rig.engine.start()
        _ = rig.drain()

        let text = String(repeating: "abcdefgh \u{4E16}\u{754C} ", count: 2000) // ~ 40 KB
        let bytes = Array(text.utf8)
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + 509, bytes.count)
                await rig.engine.handleOutbound(Data(bytes[offset ..< end]))
                offset = end
            }
        }
        await rig.engine.handleOutbound(Data([0x15])) // ^U clears the line
        let output = rig.drain()

        #expect(output.hasSuffix("$ \u{1B}[3G"))
        #expect(elapsed < .seconds(10), "40 KB paste took \(elapsed)")
    }
}

/// Engine wired to a stand-in surface, without `EngineHarness`'s fixed
/// command set.
private struct StressShellRig {
    let engine: Engine
    private let session: InMemoryTerminalSession
    private let output = CapturedBytes()

    init(@ShellCommandBuilder commands: () -> [ShellCommand] = { [] }) {
        let output = output
        session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, data in output.append(data) },
            processExit: { _, _, _ in },
        )
        session.setSurface(UnsafeMutableRawPointer(bitPattern: 0x20)!)
        let extra = commands()
        let shell = ShellDefinition(prompt: "$ ", welcomeMessage: "") {
            ShellCommand("echo", summary: "Echo text back") { .output($0.arguments + "\r\n") }
            for command in extra {
                command
            }
        }
        engine = Engine(shell: shell, session: session)
    }

    func drainData() -> Data {
        session.waitForPendingOutput()
        return output.take()
    }

    func drain() -> String {
        String(decoding: drainData(), as: UTF8.self)
    }
}

private final class CapturedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func take() -> Data {
        lock.lock()
        defer {
            data.removeAll()
            lock.unlock()
        }
        return data
    }
}
