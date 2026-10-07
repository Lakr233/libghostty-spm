import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// Hosts call `receive` from whatever thread their transport lands on, and the
/// view rebuilds its surface whenever it likes. These tests hammer the output
/// queue from many threads at once against a stand-in surface and check the
/// three things a terminal cannot afford to get wrong: every byte arrives,
/// none arrives twice, and each writer's bytes keep their order.
struct InMemoryTerminalSessionStressTests {
    @Test
    func `concurrent writers lose and duplicate nothing and keep per-writer order`() throws {
        let sink = StressSink()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, data in sink.append(data) },
        )
        session.setSurface(stressSurface(0x100))

        let writers = 16
        let recordsPerWriter = 2000
        DispatchQueue.concurrentPerform(iterations: writers) { writer in
            for sequence in 0 ..< recordsPerWriter {
                session.receive(StressRecord.encode(writer: writer, sequence: sequence))
            }
        }
        #expect(session.waitForPendingOutput())

        let records = try StressRecord.decodeAll(sink.bytes)
        try StressRecord.expectComplete(records, writers: writers, recordsPerWriter: recordsPerWriter)
    }

    /// A rebuild detaches the surface while the transport keeps writing.
    /// Bytes that land in the gap go to the next surface; no write may reach
    /// a surface after `clearSurface` has returned for it, since the caller
    /// frees it right after.
    @Test
    func `surface swaps while writers run keep every byte and never touch a released surface`() throws {
        let sink = StressSink()
        let released = ReleasedSurfaces()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { surface, data in
                if released.contains(surface) {
                    Issue.record("write reached a released surface")
                }
                sink.append(data)
            },
        )

        let writers = 8
        let recordsPerWriter = 1500
        let writersDone = DispatchGroup()
        for writer in 0 ..< writers {
            DispatchQueue.global().async(group: writersDone) {
                for sequence in 0 ..< recordsPerWriter {
                    session.receive(StressRecord.encode(writer: writer, sequence: sequence))
                }
            }
        }

        var address = 0x1000
        var swaps = 0
        while writersDone.wait(timeout: .now()) == .timedOut || swaps < 50 {
            let surface = stressSurface(address)
            session.setSurface(surface)
            if swaps % 3 == 0 {
                sched_yield()
            }
            session.clearSurface(ifMatches: surface)
            released.insert(surface)
            address += 0x10
            swaps += 1
        }
        session.setSurface(stressSurface(address))
        #expect(session.waitForPendingOutput())

        // 12k records of 12 bytes stay well under the 1 MiB detached cap, so
        // nothing may be trimmed.
        let records = try StressRecord.decodeAll(sink.bytes)
        try StressRecord.expectComplete(records, writers: writers, recordsPerWriter: recordsPerWriter)
    }

    /// Detached output is capped; a flood from many threads must leave
    /// exactly the cap behind, ending with the newest bytes intact.
    @Test
    func `detached flood from many threads stays at the pending cap`() throws {
        let sink = StressSink()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, data in sink.append(data) },
        )

        let writers = 8
        let recordsPerWriter = 40000 // 8 × 40k × 12 B ≈ 3.8 MB, past the cap
        DispatchQueue.concurrentPerform(iterations: writers) { writer in
            for sequence in 0 ..< recordsPerWriter {
                session.receive(StressRecord.encode(writer: writer, sequence: sequence))
            }
        }
        session.receive(Data("<end>".utf8))
        #expect(session.waitForPendingOutput() == false)
        #expect(sink.bytes.isEmpty)

        session.setSurface(stressSurface(0x200))
        #expect(session.waitForPendingOutput())

        let flushed = sink.bytes
        #expect(flushed.count == 1 << 20)
        #expect(flushed.suffix(5) == Data("<end>".utf8))

        // Whole records after the first partial one keep per-writer order.
        let body = flushed.dropLast(5)
        let start = body.count % StressRecord.size
        let records = try StressRecord.decodeAll(Data(body.dropFirst(start)))
        var lastSequence = [Int](repeating: -1, count: writers)
        for record in records {
            #expect(record.sequence > lastSequence[record.writer])
            lastSequence[record.writer] = record.sequence
        }
    }

    /// The resize closure runs on Ghostty's IO thread while the host feeds
    /// output from its own. Neither may starve or reorder the other, and the
    /// host must end up told the final size.
    @Test
    func `resize storm interleaved with output delivers every change and every byte`() throws {
        let sink = StressSink()
        let resizes = StressResizes()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { resizes.append($0) },
            surfaceWrite: { _, data in sink.append(data) },
        )
        session.setSurface(stressSurface(0x300))

        let writers = 4
        let recordsPerWriter = 3000
        let resizeCount = 5000
        DispatchQueue.concurrentPerform(iterations: writers + 1) { lane in
            guard lane < writers else {
                for step in 0 ..< resizeCount {
                    session.updateViewport(Self.stormMetrics(step))
                }
                return
            }
            for sequence in 0 ..< recordsPerWriter {
                session.receive(StressRecord.encode(writer: lane, sequence: sequence))
            }
        }
        #expect(session.waitForPendingOutput())

        let records = try StressRecord.decodeAll(sink.bytes)
        try StressRecord.expectComplete(records, writers: writers, recordsPerWriter: recordsPerWriter)

        // Every step changes the grid, so none is deduplicated.
        let delivered = resizes.values
        #expect(delivered.count == resizeCount)
        let last = Self.stormMetrics(resizeCount - 1)
        #expect(delivered.last?.columns == last.columns)
        #expect(delivered.last?.rows == last.rows)
        #expect(zip(delivered, delivered.dropFirst()).allSatisfy { $0 != $1 })
    }

    @Test
    func `ten megabytes in large chunks flow through within a generous bound`() {
        let sink = CountingSink()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, data in sink.add(data) },
        )
        session.setSurface(stressSurface(0x400))

        let chunk = Data(repeating: UInt8(ascii: "x"), count: 64 * 1024)
        let chunks = 160 // 10 MiB
        let elapsed = ContinuousClock().measure {
            for _ in 0 ..< chunks {
                session.receive(chunk)
            }
            session.waitForPendingOutput()
        }

        #expect(sink.byteCount == chunk.count * chunks)
        #expect(sink.writeCount == chunks)
        #expect(elapsed < .seconds(5), "10 MiB took \(elapsed)")
    }

    /// A chatty transport hands over tiny chunks far faster than a parse
    /// drains them, so the queue backs up by tens of thousands of entries.
    /// Draining must stay linear in that depth.
    @Test
    func `a backlog of tiny writes drains in linear time`() {
        let sink = CountingSink()
        let gate = DispatchSemaphore(value: 0)
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, data in
                if sink.writeCount == 0 {
                    gate.wait()
                }
                sink.add(data)
            },
        )
        session.setSurface(stressSurface(0x500))

        // Hold the first write so every later one queues behind it.
        let writes = 200_000
        let byte = Data([UInt8(ascii: "y")])
        for _ in 0 ..< writes {
            session.receive(byte)
        }
        let elapsed = ContinuousClock().measure {
            gate.signal()
            session.waitForPendingOutput()
        }

        #expect(sink.byteCount == writes)
        #expect(elapsed < .seconds(5), "draining \(writes) queued writes took \(elapsed)")
    }

    /// Detached bytes are capped by trimming the oldest; a flood past the cap
    /// must not copy the whole buffer for every chunk it trims.
    @Test
    func `a detached flood past the cap trims without quadratic copying`() {
        let sink = CountingSink()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, data in sink.add(data) },
        )

        let chunk = Data(repeating: UInt8(ascii: "z"), count: 64)
        let chunks = 256 * 1024 // 16 MiB, 16× the cap
        let elapsed = ContinuousClock().measure {
            for _ in 0 ..< chunks {
                session.receive(chunk)
            }
        }
        session.setSurface(stressSurface(0x600))
        session.waitForPendingOutput()

        #expect(sink.byteCount == 1 << 20)
        #expect(elapsed < .seconds(2), "16 MiB detached took \(elapsed)")
    }

    private static func stormMetrics(_ step: Int) -> TerminalGridMetrics {
        let columns = UInt16(40 + step % 120)
        let rows = UInt16(10 + (step / 120) % 50)
        return TerminalGridMetrics(
            columns: columns,
            rows: rows,
            widthPixels: UInt32(columns) * 8,
            heightPixels: UInt32(rows) * 16,
            cellWidthPixels: 8,
            cellHeightPixels: 16,
        )
    }
}

/// `T<writer>:<sequence>;` in a fixed 12-byte layout, so a record split or
/// duplicated anywhere in the stream fails to decode or to count.
private enum StressRecord {
    static let size = 12

    struct Decoded {
        let writer: Int
        let sequence: Int
    }

    struct Malformed: Error {
        let offset: Int
    }

    static func encode(writer: Int, sequence: Int) -> Data {
        Data(String(format: "T%02d:%07d;", writer, sequence).utf8)
    }

    static func decodeAll(_ data: Data) throws -> [Decoded] {
        guard data.count % size == 0 else { throw Malformed(offset: data.count) }
        let bytes = [UInt8](data)
        var records: [Decoded] = []
        records.reserveCapacity(bytes.count / size)
        var offset = 0
        while offset < bytes.count {
            guard bytes[offset] == UInt8(ascii: "T"),
                  bytes[offset + 3] == UInt8(ascii: ":"),
                  bytes[offset + 11] == UInt8(ascii: ";"),
                  let writer = number(bytes[offset + 1 ..< offset + 3]),
                  let sequence = number(bytes[offset + 4 ..< offset + 11])
            else { throw Malformed(offset: offset) }
            records.append(Decoded(writer: writer, sequence: sequence))
            offset += size
        }
        return records
    }

    static func expectComplete(
        _ records: [Decoded],
        writers: Int,
        recordsPerWriter: Int,
    ) throws {
        #expect(records.count == writers * recordsPerWriter)
        var next = [Int](repeating: 0, count: writers)
        for record in records {
            try #require(record.writer < writers)
            try #require(
                record.sequence == next[record.writer],
                "writer \(record.writer) expected \(next[record.writer]) got \(record.sequence)",
            )
            next[record.writer] += 1
        }
        #expect(next.allSatisfy { $0 == recordsPerWriter })
    }

    private static func number(_ digits: ArraySlice<UInt8>) -> Int? {
        var value = 0
        for digit in digits {
            guard (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(digit) else { return nil }
            value = value * 10 + Int(digit - UInt8(ascii: "0"))
        }
        return value
    }
}

private func stressSurface(_ address: Int) -> ghostty_surface_t {
    UnsafeMutableRawPointer(bitPattern: address)!
}

private final class StressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var bytes: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}

private final class CountingSink: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    private var writes = 0

    var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func add(_ data: Data) {
        lock.lock()
        bytes += data.count
        writes += 1
        lock.unlock()
    }
}

private final class StressResizes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [InMemoryTerminalViewport] = []

    var values: [InMemoryTerminalViewport] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ viewport: InMemoryTerminalViewport) {
        lock.lock()
        storage.append(viewport)
        lock.unlock()
    }
}

private final class ReleasedSurfaces: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Set<Int> = []

    func contains(_ surface: ghostty_surface_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.contains(Int(bitPattern: surface))
    }

    func insert(_ surface: ghostty_surface_t) {
        lock.lock()
        storage.insert(Int(bitPattern: surface))
        lock.unlock()
    }
}
