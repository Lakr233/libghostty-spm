#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    import GhosttyKit
    @testable import GhosttyTerminal
    import Testing

    /// Ghostty's IO thread queues a child's exit on the app mailbox with the
    /// surface's raw pointer, and the app checks that pointer only by
    /// membership when it drains. The allocator hands a freed surface's
    /// address straight to the next one, so an exit still queued when the
    /// surface goes lands on its replacement: the live child reads as
    /// exited, and the next key closes the surface instead of reaching it.
    /// Nothing here pumps the run loop, which keeps the wakeup that would
    /// have drained the exit from running.
    @Suite("TerminalSurfaceReplacement", .serialized)
    @MainActor
    struct TerminalSurfaceReplacementTests {
        @Test
        func `an exit queued by the old surface does not reach its replacement`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }

            let controller = TerminalController { $0.withCustom("shell-integration", "none") }
            let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
            view.controller = controller
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            defer { window.contentView = nil }

            for _ in 0 ..< 5 {
                try replaceExitedSurface(on: view, controller: controller)
            }
        }

        /// Synchronous on purpose: an `await` here would let the wakeup run.
        private func replaceExitedSurface(on view: AppTerminalView, controller: TerminalController) throws {
            view.configuration = TerminalSurfaceOptions(command: "/usr/bin/true", waitAfterCommand: true)
            Thread.sleep(forTimeInterval: 0.2)
            view.configuration = TerminalSurfaceOptions(command: "/bin/cat", waitAfterCommand: true)
            controller.tick()

            let replacement = try #require(view.surface?.rawValue)
            #expect(ghostty_surface_process_exited(replacement) == false)
        }
    }
#endif
