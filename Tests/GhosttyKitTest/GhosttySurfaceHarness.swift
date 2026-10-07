import AppKit
import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// One Ghostty app/surface at a time. Parallel `ghostty_app_new` aborts.
///
/// Tests wait for their turn by suspending, not by blocking: every test runs
/// on the main actor, so a blocking lock taken while the holder is suspended
/// in an `await` stalls the main thread the holder needs to finish.
@MainActor
final class GhosttySurfaceHarness {
    private static var isOccupied = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    static func make() async -> GhosttySurfaceHarness {
        if isOccupied {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isOccupied = true
        }
        return GhosttySurfaceHarness()
    }

    /// Hands the turn straight to the next waiter, so it stays occupied.
    private static func leave() {
        if waiters.isEmpty {
            isOccupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    let session: InMemoryTerminalSession
    let coordinator = TerminalSurfaceCoordinator()
    private let platformView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    private let outbound = LockedBytes()
    private var holdsTurn = true

    private init() {
        let outbound = outbound
        session = InMemoryTerminalSession(
            write: { outbound.append($0) },
            resize: { _ in },
        )
        platformView.wantsLayer = true
        coordinator.isAttached = { true }
        coordinator.scaleFactor = { 1 }
        coordinator.viewSize = { (800, 500) }
        coordinator.platformSetup = { [platformView] config in
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform = ghostty_platform_u(
                macos: ghostty_platform_macos_s(
                    nsview: Unmanaged.passUnretained(platformView).toOpaque(),
                ),
            )
        }
        coordinator.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        coordinator.controller = TerminalController()
        if coordinator.surface == nil {
            Issue.record("surface must build for the harness")
        }
    }

    var surface: TerminalSurface? {
        coordinator.surface
    }

    func tearDown() {
        coordinator.freeSurface()
        if holdsTurn {
            holdsTurn = false
            Self.leave()
        }
    }

    func receive(_ text: String) {
        session.receive(Data(text.utf8))
        session.waitForPendingOutput()
        outbound.removeAll()
    }

    func drain() async -> Data {
        session.receive(Data("\u{1B}[c".utf8))
        session.waitForPendingOutput()

        let marker = Data("\u{1B}[?62;22".utf8)
        // An upper bound, not a wait: the loop returns as soon as the reply
        // lands. A loaded CI runner took longer than 2 s for one.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(15)
        while clock.now < deadline {
            let bytes = outbound.bytes
            if let reply = bytes.range(of: marker) {
                return Data(bytes[..<reply.lowerBound])
            }
            await Task.yield()
        }
        Issue.record("device attributes reply never arrived")
        return outbound.bytes
    }

    /// The outbound bytes since the last take, then a clean slate: `drain`
    /// alone stops at the first device-attributes reply in the buffer, so a
    /// second drain without clearing would return the first one's bytes.
    func takeOutbound() async -> Data {
        let bytes = await drain()
        receive("")
        return bytes
    }
}

final class LockedBytes: @unchecked Sendable {
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

    func removeAll() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

extension Data {
    func count(of needle: String) -> Int {
        let needle = Data(needle.utf8)
        var count = 0
        var searchRange = startIndex ..< endIndex
        while let found = range(of: needle, in: searchRange) {
            count += 1
            searchRange = found.upperBound ..< endIndex
        }
        return count
    }
}
