@testable import GhosttyTerminal
import Testing

/// A tick only an engine wakeup asked for may leave out the refresh and
/// the synchronous draw (`wakeupSkipsDraw`, which UIKit's view answers
/// with whether its system scroll moved just now); one the host side
/// asked for always draws, and the frame left out runs once the scroll
/// rests.
@Suite("TerminalWakeupDraw")
@MainActor
struct TerminalWakeupDrawTests {
    @Test
    func `a wakeup tick while the scroll moves ticks without drawing`() {
        let coordinator = TerminalSurfaceCoordinator()
        var scrolling = true
        var renders = 0
        coordinator.isAttached = { true }
        coordinator.wakeupSkipsDraw = { scrolling }
        coordinator.onPostRender = { renders += 1 }

        // The first frame draws whatever the scroll does.
        #expect(coordinator.testHooks_tickDraws)
        coordinator.tick()
        #expect(renders == 1)
        #expect(!coordinator.testHooks_owesWakeupFrame)

        coordinator.requestWakeupTick()
        #expect(!coordinator.testHooks_tickDraws)
        coordinator.tick()
        #expect(renders == 2, "the app tick still runs")
        #expect(coordinator.testHooks_owesWakeupFrame, "the frame is owed, not dropped")

        // At rest a wakeup draws again.
        coordinator.requestWakeupTick()
        scrolling = false
        #expect(coordinator.testHooks_tickDraws)
        coordinator.tick()
        #expect(!coordinator.testHooks_owesWakeupFrame)
    }

    @Test
    func `the frame left out runs once the scroll rests`() {
        let coordinator = TerminalSurfaceCoordinator()
        var scrolling = true
        var renders = 0
        coordinator.isAttached = { true }
        coordinator.wakeupSkipsDraw = { scrolling }
        coordinator.tick()
        coordinator.onPostRender = { renders += 1 }

        coordinator.requestWakeupTick()
        coordinator.tick()
        #expect(renders == 1)
        // Still moving: an idle frame of the display link does nothing.
        coordinator.tick()
        #expect(renders == 1)
        #expect(coordinator.testHooks_owesWakeupFrame)

        // No further wakeup comes; the next frame of the link pays it.
        scrolling = false
        coordinator.tick()
        #expect(renders == 2)
        #expect(!coordinator.testHooks_owesWakeupFrame)
        coordinator.tick()
        #expect(renders == 2, "paid once")
    }

    @Test
    func `a tick the host asked for draws while the scroll moves`() {
        let coordinator = TerminalSurfaceCoordinator()
        coordinator.isAttached = { true }
        coordinator.wakeupSkipsDraw = { true }
        coordinator.tick()

        coordinator.requestImmediateTick()
        // A wakeup on top does not take the draw away.
        coordinator.requestWakeupTick()
        #expect(coordinator.testHooks_tickDraws)
        coordinator.tick()
        #expect(!coordinator.testHooks_tickDraws)
    }

    /// The Mac's views never set it: every tick draws, as before.
    @Test
    func `by default every wakeup tick draws`() {
        let coordinator = TerminalSurfaceCoordinator()
        coordinator.isAttached = { true }
        coordinator.tick()
        coordinator.requestWakeupTick()
        #expect(coordinator.testHooks_tickDraws)
    }

    /// A scroll that moves keeps the display link running without asking
    /// for a tick: the link holds the display's rate, it draws nothing.
    @Test
    func `a moving scroll holds the display link without owing a tick`() {
        let coordinator = TerminalSurfaceCoordinator()
        var renders = 0
        coordinator.isAttached = { true }
        coordinator.tick()
        coordinator.stopDisplayLink()
        coordinator.onPostRender = { renders += 1 }
        #expect(!coordinator.testHooks_displayLinkIsRunning)

        coordinator.holdDisplayLinkForScroll()
        #expect(coordinator.testHooks_displayLinkIsRunning)
        coordinator.tick()
        #expect(renders == 0, "holding the link is not a frame to render")
    }
}
