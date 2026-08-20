import Foundation
import GhosttyKit

/// Serializes host output while keeping the raw surface alive for each C call.
final class InMemoryTerminalSurfaceAccess: @unchecked Sendable {
    typealias Write = @Sendable (ghostty_surface_t, Data) -> Void
    typealias ProcessExit = @Sendable (ghostty_surface_t, UInt32, UInt64) -> Void

    private let condition = NSCondition()
    private let outputQueue = DispatchQueue(
        label: "com.lakr233.libghostty-spm.in-memory-output",
        qos: .userInitiated
    )
    private let write: Write
    private let processExit: ProcessExit

    private var surface: ghostty_surface_t?
    /// Invalidates work that was enqueued for a surface that has been replaced.
    private var generation: UInt64 = 0
    /// Prevents the caller from freeing a surface while a C operation uses it.
    private var activeOperations = 0
    /// Bytes received while no surface is attached, replayed into the next
    /// one. The host's transport does not pause while a view (re)builds its
    /// surface — a reattach replay that lands in that gap used to be dropped
    /// wholesale, leaving the restored session showing only whatever the
    /// shell printed afterwards. Bounded: oldest bytes go first, matching
    /// what a terminal scrollback would have forgotten anyway.
    private var pendingWrites = Data()
    private static let pendingWriteByteLimit = 1 << 20

    init(
        write: @escaping Write,
        processExit: @escaping ProcessExit
    ) {
        self.write = write
        self.processExit = processExit
    }

    func setSurface(_ surface: ghostty_surface_t?) {
        condition.lock()
        generation &+= 1
        self.surface = nil
        waitForActiveOperations()
        self.surface = surface
        // Flush bytes that arrived surfaceless, ahead of anything received
        // after this call: both ride the same serial queue, so enqueueing
        // here (before the lock drops for good) preserves stream order.
        var flush: Data?
        if surface != nil, !pendingWrites.isEmpty {
            flush = pendingWrites
            pendingWrites = Data()
        }
        let flushGeneration = generation
        condition.unlock()
        if let flush {
            outputQueue.async { [self] in
                withSurface(generation: flushGeneration) { surface in
                    write(surface, flush)
                }
            }
        }
    }

    @discardableResult
    func clearSurface(ifMatches expectedSurface: ghostty_surface_t?) -> Bool {
        condition.lock()
        guard surface == expectedSurface else {
            condition.unlock()
            return false
        }

        generation &+= 1
        surface = nil
        waitForActiveOperations()
        condition.unlock()
        return true
    }

    var currentSurface: ghostty_surface_t? {
        condition.lock()
        defer { condition.unlock() }
        return surface
    }

    @discardableResult
    func enqueueWrite(_ data: Data) -> Bool {
        condition.lock()
        guard surface != nil else {
            pendingWrites.append(data)
            let excess = pendingWrites.count - Self.pendingWriteByteLimit
            if excess > 0 {
                pendingWrites.removeFirst(excess)
            }
            condition.unlock()
            return true
        }
        let writeGeneration = generation
        condition.unlock()
        outputQueue.async { [self] in
            withSurface(generation: writeGeneration) { surface in
                write(surface, data)
            }
        }
        return true
    }

    @discardableResult
    func enqueueProcessExit(
        exitCode: UInt32,
        runtimeMilliseconds: UInt64
    ) -> Bool {
        guard let generation = currentGeneration else { return false }
        outputQueue.async { [self] in
            withSurface(generation: generation) { surface in
                processExit(surface, exitCode, runtimeMilliseconds)
            }
        }
        return true
    }

    func withCurrentSurface<Result>(
        _ operation: (ghostty_surface_t) -> Result
    ) -> Result? {
        condition.lock()
        guard let surface else {
            condition.unlock()
            return nil
        }
        activeOperations += 1
        condition.unlock()

        defer { finishOperation() }
        return operation(surface)
    }

    func waitForPendingOutput() {
        outputQueue.sync {}
    }

    private var currentGeneration: UInt64? {
        condition.lock()
        defer { condition.unlock() }
        return surface == nil ? nil : generation
    }

    private func withSurface(
        generation expectedGeneration: UInt64,
        _ operation: (ghostty_surface_t) -> Void
    ) {
        condition.lock()
        guard generation == expectedGeneration, let surface else {
            condition.unlock()
            return
        }
        activeOperations += 1
        condition.unlock()

        defer { finishOperation() }
        operation(surface)
    }

    private func finishOperation() {
        condition.lock()
        activeOperations -= 1
        if activeOperations == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    private func waitForActiveOperations() {
        while activeOperations > 0 {
            condition.wait()
        }
    }
}
