import AppKit
import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// An app wakeup only drains Ghostty's mailbox. On AppKit the renderer thread draws by itself, so
/// a wakeup must not schedule a coordinator tick: that is a refresh plus a synchronous draw on the
/// main thread, for every surface, and the renderer posts a wakeup for each frame it draws.
@Suite("TerminalWakeupRender", .serialized)
struct TerminalWakeupRenderTests {
    @Test
    @MainActor
    func `an app wakeup schedules no tick on AppKit`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let controller = TerminalController()
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let platformView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let coordinator = Self.coordinator(platformView: platformView)
        coordinator.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        coordinator.controller = controller
        try #require(coordinator.surface != nil)

        // The rebuild asked for one tick; take it.
        coordinator.tick()
        #expect(!coordinator.testHooks_pendingImmediateTick)

        controller.handleWakeup()
        #expect(!coordinator.testHooks_pendingImmediateTick)

        // A render action still schedules one.
        coordinator.bridge.onRenderRequest?()
        #expect(coordinator.testHooks_pendingImmediateTick)
        withExtendedLifetime(platformView) {}
    }

    @MainActor
    private static func coordinator(platformView: NSView) -> TerminalSurfaceCoordinator {
        let coordinator = TerminalSurfaceCoordinator()
        platformView.wantsLayer = true
        coordinator.isAttached = { true }
        coordinator.scaleFactor = { 1 }
        coordinator.viewSize = { [weak platformView] in
            guard let platformView else { return (0, 0) }
            return (platformView.bounds.width, platformView.bounds.height)
        }
        coordinator.platformSetup = { [weak platformView] config in
            guard let platformView else { return }
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform = ghostty_platform_u(
                macos: ghostty_platform_macos_s(
                    nsview: Unmanaged.passUnretained(platformView).toOpaque(),
                ),
            )
        }
        return coordinator
    }
}
