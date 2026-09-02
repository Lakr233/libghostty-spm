import Foundation
import GhosttyKit

/// Serializes host output while keeping the raw surface alive for each C call.
final class InMemoryTerminalSurfaceAccess: @unchecked Sendable {
    typealias Write = @Sendable (ghostty_surface_t, Data) -> Void
    typealias ProcessExit = @Sendable (ghostty_surface_t, UInt32, UInt64) -> Void
    typealias Tick = @Sendable (ghostty_surface_t) -> Void

    private let condition = NSCondition()
    private let outputQueue = DispatchQueue(
        label: "com.lakr233.libghostty-spm.in-memory-output",
        qos: .userInitiated
    )
    private let write: Write
    private let processExit: ProcessExit
    private let tick: Tick

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
    /// A process exit received while no surface is attached, delivered to
    /// the next one after the pending bytes — the host's shell ends in the
    /// same gap its output lands in.
    private var pendingExit: (exitCode: UInt32, runtimeMilliseconds: UInt64)?
    /// Parsing on the output queue pushes titles, pwd and command marks into
    /// ghostty's 64-slot app mailbox, which only `ghostty_app_tick` drains,
    /// and this package ticks on the main thread alone. A main-thread caller
    /// that blocks on the queue outright therefore waits forever on a write
    /// that is itself waiting for the tick, so the main thread waits in
    /// slices and ticks between them.
    private static let mainThreadPollInterval: TimeInterval = 0.01

    init(
        write: @escaping Write,
        processExit: @escaping ProcessExit,
        tick: @escaping Tick
    ) {
        self.write = write
        self.processExit = processExit
        self.tick = tick
    }

    func setSurface(_ surface: ghostty_surface_t?) {
        condition.lock()
        generation &+= 1
        let previous = self.surface
        self.surface = nil
        waitForActiveOperations(ticking: previous)
        self.surface = surface
        // Flush what arrived surfaceless, ahead of anything received after
        // this call: both ride the same serial queue, so enqueueing while the
        // lock still excludes `enqueueWrite` preserves stream order.
        if surface != nil {
            let flushGeneration = generation
            if !pendingWrites.isEmpty {
                let flush = pendingWrites
                pendingWrites = Data()
                outputQueue.async { [self] in
                    withSurface(generation: flushGeneration) { surface in
                        write(surface, flush)
                    }
                }
            }
            if let exit = pendingExit {
                pendingExit = nil
                outputQueue.async { [self] in
                    withSurface(generation: flushGeneration) { surface in
                        processExit(surface, exit.exitCode, exit.runtimeMilliseconds)
                    }
                }
            }
        }
        condition.unlock()
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
        waitForActiveOperations(ticking: expectedSurface)
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

    func enqueueProcessExit(
        exitCode: UInt32,
        runtimeMilliseconds: UInt64
    ) {
        condition.lock()
        guard surface != nil else {
            pendingExit = (exitCode, runtimeMilliseconds)
            condition.unlock()
            return
        }
        let exitGeneration = generation
        condition.unlock()
        outputQueue.async { [self] in
            withSurface(generation: exitGeneration) { surface in
                processExit(surface, exitCode, runtimeMilliseconds)
            }
        }
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
        guard Thread.isMainThread else {
            outputQueue.sync {}
            return
        }
        let drained = DispatchSemaphore(value: 0)
        outputQueue.async { drained.signal() }
        while drained.wait(timeout: .now() + Self.mainThreadPollInterval) == .timedOut {
            tickCurrentSurface()
        }
    }

    /// Ticks outside the lock and without counting an operation: the tick can
    /// deliver a close, and a host that tears the surface down from that
    /// callback re-enters `clearSurface` on this thread. Teardown is
    /// main-actor work, so the pointer stays valid across a main-thread tick.
    private func tickCurrentSurface() {
        condition.lock()
        let current = surface
        condition.unlock()
        if let current {
            tick(current)
        }
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

    /// Called with the lock held. `previous` is the surface the in-flight
    /// operations use; the caller frees it only after this returns.
    private func waitForActiveOperations(ticking previous: ghostty_surface_t?) {
        while activeOperations > 0 {
            guard Thread.isMainThread, let previous else {
                condition.wait()
                continue
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: Self.mainThreadPollInterval))
            guard activeOperations > 0 else { return }
            condition.unlock()
            tick(previous)
            condition.lock()
        }
    }
}
