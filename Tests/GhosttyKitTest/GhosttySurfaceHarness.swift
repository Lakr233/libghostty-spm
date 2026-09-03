import AppKit
import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// One Ghostty app/surface at a time. Parallel `ghostty_app_new` aborts.
@MainActor
final class GhosttySurfaceHarness {
    private static let createLock = NSLock()

    let session: InMemoryTerminalSession
    let coordinator = TerminalSurfaceCoordinator()
    private let platformView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    private let outbound = LockedBytes()
    private var holdsCreateLock = false

    init() {
        Self.createLock.lock()
        holdsCreateLock = true
        let outbound = outbound
        session = InMemoryTerminalSession(
            write: { outbound.append($0) },
            resize: { _ in }
        )
        platformView.wantsLayer = true
        coordinator.isAttached = { true }
        coordinator.scaleFactor = { 1 }
        coordinator.viewSize = { (800, 500) }
        coordinator.platformSetup = { [platformView] config in
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform = ghostty_platform_u(
                macos: ghostty_platform_macos_s(
                    nsview: Unmanaged.passUnretained(platformView).toOpaque()
                )
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
        if holdsCreateLock {
            holdsCreateLock = false
            Self.createLock.unlock()
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
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
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
