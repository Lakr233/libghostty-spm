import AppKit
import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// Regressions for the host-managed resize decisions a review found could
/// damage otherwise-working behaviour: a rebuild dropped while a pane is
/// hidden, a throttle timer outliving the surface it was armed for, and a
/// throttle armed against no surface at all.
@MainActor
struct TerminalSurfaceResizeThrottleTests {
    @Test
    func `a deferred rebuild is redeemed once the view has a size again`() {
        let coordinator = TerminalSurfaceCoordinator()
        coordinator.viewSize = { (100, 50) }
        coordinator.isAttached = { true }

        // Stand in for the zero-size guard having deferred a rebuild: the
        // configuration options it carried are consumed only by
        // createSurface, so dropping the request would leave a hidden pane on
        // its old configuration indefinitely.
        coordinator.testHooks_pendingRebuild = true

        coordinator.synchronizeMetrics()

        #expect(!coordinator.testHooks_pendingRebuild)
    }

    @Test
    func `a deferred rebuild is not redeemed while the view is still hidden`() {
        let coordinator = TerminalSurfaceCoordinator()
        coordinator.viewSize = { (0, 0) }
        coordinator.isAttached = { true }
        coordinator.testHooks_pendingRebuild = true

        coordinator.synchronizeMetrics()

        // Still owed — redeeming it here would rebuild against a zero size.
        #expect(coordinator.testHooks_pendingRebuild)
    }

    @Test
    func `the throttle is inert by default`() {
        let coordinator = TerminalSurfaceCoordinator()
        coordinator.viewSize = { (100, 50) }
        coordinator.isAttached = { true }

        // No platform override and no configured window: coalescing is off.
        #expect(coordinator.resizeThrottleInterval == nil)
        #expect(coordinator.configuration.resizeThrottleMilliseconds == 0)
        coordinator.synchronizeMetrics()
        coordinator.synchronizeMetrics()

        // Nothing armed: with the feature off the metrics sync runs inline,
        // exactly as it does upstream.
        #expect(!coordinator.testHooks_throttleArmed)
        #expect(!coordinator.testHooks_throttleTrailing)
    }

    @Test
    func `an enabled throttle does not arm without a surface`() {
        let coordinator = TerminalSurfaceCoordinator()
        coordinator.viewSize = { (100, 50) }
        coordinator.isAttached = { true }
        coordinator.resizeThrottleInterval = 5 // long enough not to fire here

        // This is the creation-time cell_size callback's position: ghostty
        // dispatches it synchronously inside ghostty_surface_new, before the
        // coordinator has the surface. Nothing was sized, so nothing may be
        // armed — an armed gate here would turn the new surface's own first
        // sync into a trailing edge one full window later.
        coordinator.synchronizeMetrics()
        #expect(!coordinator.testHooks_throttleArmed)
        #expect(!coordinator.testHooks_throttleTrailing)
    }

    @Test
    func `a throttled surface is sized at creation, not a window later`() {
        let harness = SurfaceHarness(resizeThrottleInterval: 5)
        defer { harness.tearDown() }

        // The leading edge: the build's own sync sent the size and armed the
        // window behind it. Nothing is owed to a trailing timer.
        #expect(harness.coordinator.syncedViewSize?.width == 800)
        #expect(harness.coordinator.syncedViewSize?.height == 500)
        #expect(harness.coordinator.testHooks_throttleArmed)
        #expect(!harness.coordinator.testHooks_throttleTrailing)
    }

    @Test
    func `an enabled throttle arms once and records a trailing edge`() {
        let harness = SurfaceHarness(resizeThrottleInterval: 5)
        defer { harness.tearDown() }
        let coordinator = harness.coordinator

        #expect(coordinator.testHooks_throttleArmed)
        #expect(!coordinator.testHooks_throttleTrailing)

        coordinator.synchronizeMetrics()
        #expect(coordinator.testHooks_throttleTrailing)
    }

    @Test
    func `the throttle can be configured without rebuilding the surface`() {
        let options = TerminalSurfaceOptions()
        #expect(options.resizeThrottleMilliseconds == 0)

        var throttled = options
        throttled.resizeThrottleMilliseconds = 96

        // Delivery policy is not surface identity: changing only the throttle
        // must not look like a configuration change, or the coordinator would
        // tear down a live surface and discard its grid and scrollback.
        #expect(options.isEquivalent(to: throttled))

        let harness = SurfaceHarness(resizeThrottleMilliseconds: 96)
        defer { harness.tearDown() }
        #expect(harness.coordinator.testHooks_throttleArmed)
    }

    @Test
    func `the platform setter overrides the configured throttle`() {
        // An explicit 0 from the platform layer disables coalescing even
        // though the configuration asks for it.
        let harness = SurfaceHarness(
            resizeThrottleMilliseconds: 5000,
            resizeThrottleInterval: 0
        )
        defer { harness.tearDown() }
        let coordinator = harness.coordinator
        coordinator.synchronizeMetrics()
        #expect(!coordinator.testHooks_throttleArmed)

        // Clearing the override falls back to the configured value.
        coordinator.resizeThrottleInterval = nil
        coordinator.synchronizeMetrics()
        #expect(coordinator.testHooks_throttleArmed)
    }

    @Test
    func `teardown retires an armed throttle instead of leaving it to fire`() {
        let harness = SurfaceHarness(resizeThrottleInterval: 5)
        let coordinator = harness.coordinator

        coordinator.synchronizeMetrics()
        #expect(coordinator.testHooks_throttleArmed)
        #expect(coordinator.testHooks_throttleTrailing)

        let generationBefore = coordinator.testHooks_throttleGeneration
        coordinator.freeSurface()

        // The replacement surface must not inherit the old surface's armed
        // gate — that would suppress its first sizing — and the in-flight
        // timer must no longer match the current generation, so it cannot
        // size or re-arm against the surface that replaced it.
        #expect(!coordinator.testHooks_throttleArmed)
        #expect(!coordinator.testHooks_throttleTrailing)
        #expect(coordinator.testHooks_throttleGeneration != generationBefore)
    }

    @Test
    func `the synced view size is only ever a size the surface was given`() {
        let coordinator = TerminalSurfaceCoordinator()
        coordinator.viewSize = { (100, 50) }
        coordinator.isAttached = { true }

        // No surface: nothing was sized, so a UIKit host reading this to
        // hold its layer must see nothing and place the layer at bounds.
        coordinator.synchronizeMetrics()
        #expect(coordinator.syncedViewSize == nil)

        coordinator.freeSurface()
        #expect(coordinator.syncedViewSize == nil)
    }
}

/// A rebuild runs from `configuration`'s didSet, when the property already
/// names the new backend. The session that must be told the surface is gone
/// is the one the surface was built with.
@MainActor
struct TerminalSurfaceBackendSwapTests {
    @Test
    func `swapping the in-memory session releases the surface from the old one`() {
        let old = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let new = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let harness = SurfaceHarness(session: old)
        defer { harness.tearDown() }
        let coordinator = harness.coordinator

        let first = coordinator.surface?.rawValue
        #expect(first != nil)
        #expect(old.currentSurface == first)

        coordinator.configuration.backend = .inMemory(new)

        // The old session would otherwise keep the freed pointer and hand it
        // to ghostty_surface_write_buffer on its next receive(_:).
        #expect(old.currentSurface == nil)
        #expect(coordinator.surface?.rawValue != nil)
        #expect(new.currentSurface == coordinator.surface?.rawValue)
    }

    @Test
    func `teardown clears the session the surface was built with`() {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let harness = SurfaceHarness(session: session)
        #expect(session.currentSurface != nil)

        harness.tearDown()
        #expect(session.currentSurface == nil)
    }
}

/// A coordinator with a real macOS surface over an in-memory session, so the
/// throttle has a size to send and a session is holding the surface.
@MainActor
private final class SurfaceHarness {
    let coordinator = TerminalSurfaceCoordinator()
    private let platformView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))

    init(
        session: InMemoryTerminalSession = InMemoryTerminalSession(write: { _ in }, resize: { _ in }),
        resizeThrottleMilliseconds: Double = 0,
        resizeThrottleInterval: TimeInterval? = nil
    ) {
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
        coordinator.configuration = TerminalSurfaceOptions(
            backend: .inMemory(session),
            resizeThrottleMilliseconds: resizeThrottleMilliseconds
        )
        coordinator.resizeThrottleInterval = resizeThrottleInterval
        coordinator.controller = TerminalController()
        precondition(coordinator.surface != nil, "surface must build for the harness")
    }

    func tearDown() {
        coordinator.freeSurface()
    }
}
