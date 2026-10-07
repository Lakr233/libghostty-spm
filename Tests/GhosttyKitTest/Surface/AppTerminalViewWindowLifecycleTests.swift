#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    @testable import GhosttyTerminal
    import Testing

    @Suite("AppTerminalViewWindowLifecycle", .serialized)
    @MainActor
    struct AppTerminalViewWindowLifecycleTests {
        @Test
        func `an occluded window stops the view rendering`() {
            let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
            // Never ordered in: AppKit reports it as not visible.
            let window = NSWindow(
                contentRect: view.frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false,
            )
            window.contentView = view
            #expect(!window.occlusionState.contains(.visible))
            #expect(view.core.testHooks_canRenderFrame)

            NotificationCenter.default.post(
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window,
            )

            #expect(!view.core.testHooks_isWindowVisible)
            #expect(!view.core.testHooks_canRenderFrame)

            // Detaching resets it: the next window reports its own state.
            window.contentView = nil
            #expect(view.core.testHooks_isWindowVisible)
        }

        @Test
        func `window occlusion does not overwrite host-declared visibility`() async {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let coordinator = harness.coordinator

            coordinator.setWindowVisible(false)
            #expect(!coordinator.testHooks_canRenderFrame)

            // The host saying "visible" does not un-hide an occluded window.
            coordinator.setDisplayVisible(true)
            #expect(!coordinator.testHooks_canRenderFrame)

            coordinator.setWindowVisible(true)
            #expect(coordinator.testHooks_canRenderFrame)

            // And the window coming back does not un-hide a host-hidden pane.
            coordinator.setDisplayVisible(false)
            coordinator.setWindowVisible(false)
            coordinator.setWindowVisible(true)
            #expect(!coordinator.testHooks_canRenderFrame)
        }

        @Test
        func `updating tracking areas keeps areas the view does not own`() {
            let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
            let owner = NSObject()
            let foreign = NSTrackingArea(
                rect: view.bounds,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: owner,
                userInfo: nil,
            )
            view.addTrackingArea(foreign)

            view.updateTrackingAreas()
            view.updateTrackingAreas()

            #expect(view.trackingAreas.contains { $0 === foreign })
            #expect(view.trackingAreas.count { $0.owner === view } == 1)
        }
    }
#endif
