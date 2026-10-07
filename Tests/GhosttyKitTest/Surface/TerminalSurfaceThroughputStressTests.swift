import Foundation
@testable import GhosttyTerminal
import ShellCraftKit
import Testing

/// The same host-managed output path as the stand-in tests, against a real
/// Ghostty surface: the parser must reassemble UTF-8 that a transport split
/// anywhere, keep up with multi-megabyte bursts, and survive its surface
/// being rebuilt or resized while another thread keeps writing.
@Suite("TerminalSurfaceThroughputStress", .serialized)
struct TerminalSurfaceThroughputStressTests {
    private static let sample = "h\u{E9}llo \u{4E16}\u{754C} \u{1F389}\u{1F44D}\u{1F3FD} e\u{301} ok"

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `utf-8 split at every byte boundary renders the same line`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let session = harness.session
        await settleGrid(harness)
        let bytes = Array(Self.sample.utf8)

        for split in 1 ..< bytes.count {
            session.receive(Data("\u{1B}[2J\u{1B}[H".utf8) + Data(bytes[..<split]))
            session.receive(Data(bytes[split...]))
            session.waitForPendingOutput()
            let row = viewportRows(session).first
            #expect(row == Self.sample, "split at byte \(split)")
        }
    }

    /// Lines of mixed-width text cut into prime-sized chunks, so chunk edges
    /// land inside every kind of multi-byte sequence many times over.
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `a multi-megabyte utf-8 burst in odd chunks ends on the expected lines`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let session = harness.session
        await settleGrid(harness)

        let lineCount = 40000
        var stream = Data()
        for index in 0 ..< lineCount {
            stream.append(Data("\(index) \(Self.sample)\r\n".utf8))
        }
        stream.append(Data("end".utf8))
        #expect(stream.count > 1_000_000)

        var offset = 0
        let chunkSizes = [4093, 1, 2, 3, 65521, 7, 509]
        var step = 0
        while offset < stream.count {
            let end = min(offset + chunkSizes[step % chunkSizes.count], stream.count)
            session.receive(stream.subdata(in: offset ..< end))
            offset = end
            step += 1
        }
        session.waitForPendingOutput()

        let rows = viewportRows(session).reversed().drop(while: \.isEmpty).reversed()
        let tail = Array(rows.suffix(4))
        #expect(tail == [
            "\(lineCount - 3) \(Self.sample)",
            "\(lineCount - 2) \(Self.sample)",
            "\(lineCount - 1) \(Self.sample)",
            "end",
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `ten megabytes parse within a generous bound`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let session = harness.session
        await settleGrid(harness)

        let line = Data((String(repeating: "0123456789abcdef", count: 4) + "\r\n").utf8)
        var chunk = Data()
        while chunk.count + line.count <= 64 * 1024 {
            chunk.append(line)
        }
        let chunks = (10 * 1024 * 1024) / chunk.count

        let elapsed = ContinuousClock().measure {
            for _ in 0 ..< chunks {
                session.receive(chunk)
            }
            session.receive("done")
            session.waitForPendingOutput()
        }

        #expect(viewportRows(session).contains("done"))
        #expect(elapsed < .seconds(30), "10 MiB took \(elapsed)")
    }

    /// A view rebuilds its surface while the host transport keeps writing
    /// from its own thread. Every rebuild must hand the queued output on,
    /// and the last surface must show the stream's end.
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `surface rebuilds while output flows end on the stream tail`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let coordinator = harness.coordinator
        let session = harness.session

        // The pump holds back its last line until the rebuilds stop, so the
        // final surface always has the stream's end to show — a rebuild after
        // the last byte drained would rightly leave it blank.
        let lines = 20000
        let pump = PumpFlag()
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for index in 0 ..< lines - 1 {
                session.receive("line \(index)\r\n")
            }
            pump.reachEnd()
            release.wait()
            session.receive("line \(lines - 1)\r\n")
            pump.finish()
        }

        var rebuilds = 0
        while !pump.hasReachedEnd || rebuilds < 10 {
            coordinator.freeSurface()
            coordinator.rebuildIfReady()
            #expect(coordinator.surface != nil)
            rebuilds += 1
        }
        release.signal()
        while !pump.isFinished {
            await Task.yield()
        }
        await settleGrid(harness)
        session.receive("done")
        session.waitForPendingOutput()

        // Whatever the last surface received is the stream's contiguous tail.
        let rows = Array(viewportRows(session).drop(while: \.isEmpty).reversed().drop(while: \.isEmpty).reversed())
        #expect(rows.last == "done")
        let numbers = rows.dropLast().compactMap { Int($0.dropFirst("line ".count)) }
        #expect(numbers.count == rows.count - 1)
        #expect(numbers.last == lines - 1)
        #expect(zip(numbers, numbers.dropFirst()).allSatisfy { $1 == $0 + 1 })
    }

    /// The sample apps' setup under load: ShellCraftKit's shell answering a
    /// flood of commands typed from another thread while the view rebuilds
    /// its surface. Output the shell prints during a rebuild waits for the
    /// next surface, and the shell must still answer afterwards.
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `shell session keeps answering across surface rebuilds while commands flood in`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let coordinator = harness.coordinator
        let shell = ShellSession(shell: defaultSandboxShell)
        let session = shell.terminalSession
        coordinator.configuration.backend = .inMemory(session)
        shell.start()

        let pump = PumpFlag()
        DispatchQueue.global().async {
            for index in 0 ..< 500 {
                session.sendInput(Data("echo n\(index)\r".utf8))
            }
            pump.finish()
        }

        var rebuilds = 0
        while !pump.isFinished || rebuilds < 10 {
            coordinator.freeSurface()
            coordinator.rebuildIfReady()
            #expect(coordinator.surface != nil)
            rebuilds += 1
            await Task.yield()
        }

        session.sendInput(Data("echo FINAL\r".utf8))
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        var answered = false
        while clock.now < deadline, !answered {
            session.waitForPendingOutput()
            answered = viewportRows(session).contains("FINAL")
            if !answered {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(answered)
        withExtendedLifetime(shell) {}
    }

    /// Resizes reflow the screen on the main thread while the IO thread
    /// parses output from another; both must finish and agree on the end.
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `resize storm while output flows ends on the stream tail`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer {
            harness.coordinator.viewSize = { (800, 500) }
            harness.tearDown()
        }
        let coordinator = harness.coordinator
        let session = harness.session

        let lines = 20000
        let pump = PumpFlag()
        DispatchQueue.global().async {
            for index in 0 ..< lines {
                session.receive("row \(index) \(Self.sample)\r\n")
            }
            pump.finish()
        }

        var step = 0
        while !pump.isFinished || step < 200 {
            let width = Double(400 + (step * 37) % 600)
            let height = Double(200 + (step * 53) % 400)
            coordinator.viewSize = { (width, height) }
            coordinator.synchronizeMetrics()
            coordinator.tick()
            step += 1
        }
        coordinator.viewSize = { (800, 500) }
        coordinator.synchronizeMetrics()
        await settleGrid(harness)
        session.receive("done")
        session.waitForPendingOutput()

        let rows = viewportRows(session).reversed().drop(while: \.isEmpty).reversed()
        #expect(Array(rows.suffix(2)) == ["row \(lines - 1) \(Self.sample)", "done"])
    }
}

/// Waits until the terminal's own grid matches the size the surface reports.
/// Ghostty's IO thread applies a resize behind a coalescing timer, so right
/// after a surface builds or resizes, `ghostty_surface_size` (which
/// `readViewportText` reads rows by) can be ahead of the screen the parser
/// writes into. The cursor position report comes from the screen itself.
@MainActor
func settleGrid(_ harness: GhosttySurfaceHarness) async {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    var reported = ""
    while clock.now < deadline {
        guard let size = harness.surface?.size() else { break }
        harness.receive("")
        harness.session.receive("\u{1B}7\u{1B}[999;999H\u{1B}[6n\u{1B}8")
        reported = await String(decoding: harness.drain(), as: UTF8.self)
        if reported.hasSuffix("\u{1B}[\(size.rows);\(size.columns)R") {
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("terminal grid never matched the surface size: \(reported.debugDescription)")
}

/// Viewport rows with trailing blanks trimmed.
@MainActor
func viewportRows(_ session: InMemoryTerminalSession) -> [String] {
    guard let text = session.readViewportText() else {
        Issue.record("viewport read failed")
        return []
    }
    return text.components(separatedBy: "\n").map { line in
        String(line.reversed().drop(while: { $0 == " " }).reversed())
    }
}

private final class PumpFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var reachedEnd = false

    var hasReachedEnd: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachedEnd
    }

    func reachEnd() {
        lock.lock()
        reachedEnd = true
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}
