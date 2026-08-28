@testable import GhosttyTerminal
import Testing

@MainActor
struct TerminalLifecycleTests {
    @Test
    func `failed surface creation does not retain bridge`() {
        let controller = TerminalController()
        let bridge = TerminalCallbackBridge()

        let surface = controller.createSurface(
            bridge: bridge,
            configuration: .init()
        ) { _ in }

        #expect(surface == nil)
        #expect(controller.retainedBridgeCount == 0)
    }

    @Test
    func `switching controllers removes bridge from old controller`() {
        let oldController = TerminalController()
        let newController = TerminalController()
        let coordinator = TerminalSurfaceCoordinator()

        coordinator.isAttached = { false }
        oldController.retain(coordinator.bridge)
        #expect(oldController.retainedBridgeCount == 1)

        coordinator.controller = oldController
        #expect(oldController.retainedBridgeCount == 0)

        oldController.retain(coordinator.bridge)
        #expect(oldController.retainedBridgeCount == 1)

        coordinator.controller = newController

        #expect(oldController.retainedBridgeCount == 0)
        #expect(newController.retainedBridgeCount == 0)
    }

    @Test
    func `free surface removes retained bridge`() {
        let controller = TerminalController()
        let coordinator = TerminalSurfaceCoordinator()

        coordinator.isAttached = { false }
        coordinator.controller = controller

        controller.retain(coordinator.bridge)
        #expect(controller.retainedBridgeCount == 1)

        coordinator.freeSurface()

        #expect(controller.retainedBridgeCount == 0)
    }

    @Test
    func `suspended wakeup does not schedule render`() {
        let controller = TerminalController()
        let token = WakeupToken()
        var wakeups = 0

        controller.addWakeupObserver(
            ObjectIdentifier(token),
            shouldProcess: { false },
            onWakeup: { wakeups += 1 }
        )

        controller.handleWakeup()

        #expect(wakeups == 0)
    }

    @Test
    func `wakeup reaches every observer`() {
        let controller = TerminalController()
        let first = WakeupToken()
        let second = WakeupToken()
        var firstWakeups = 0
        var secondWakeups = 0

        controller.addWakeupObserver(
            ObjectIdentifier(first),
            shouldProcess: { true },
            onWakeup: { firstWakeups += 1 }
        )
        controller.addWakeupObserver(
            ObjectIdentifier(second),
            shouldProcess: { true },
            onWakeup: { secondWakeups += 1 }
        )

        controller.handleWakeup()

        #expect(firstWakeups == 1)
        #expect(secondWakeups == 1)
    }

    @Test
    func `removing one observer keeps the others awake`() {
        let controller = TerminalController()
        let first = WakeupToken()
        let second = WakeupToken()
        var firstWakeups = 0
        var secondWakeups = 0

        controller.addWakeupObserver(
            ObjectIdentifier(first),
            shouldProcess: { true },
            onWakeup: { firstWakeups += 1 }
        )
        controller.addWakeupObserver(
            ObjectIdentifier(second),
            shouldProcess: { false },
            onWakeup: { secondWakeups += 1 }
        )

        controller.removeWakeupObserver(ObjectIdentifier(second))
        controller.handleWakeup()

        #expect(firstWakeups == 1)
        #expect(secondWakeups == 0)
    }

    @Test
    func `application active state controls immediate ticks`() async {
        let coordinator = TerminalSurfaceCoordinator()
        var renders = 0

        coordinator.isAttached = { true }
        coordinator.onPostRender = {
            renders += 1
        }

        coordinator.setApplicationActive(false)
        coordinator.requestImmediateTick()
        await Task.yield()

        #expect(renders == 0)

        coordinator.setApplicationActive(true)
        await Task.yield()

        #expect(renders == 1)
    }
}

private final class WakeupToken {}
