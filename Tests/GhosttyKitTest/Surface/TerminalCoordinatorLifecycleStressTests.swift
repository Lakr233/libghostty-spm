import AppKit
import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// Builds, drives, reconfigures and drops a real controller + coordinator +
/// surface + session many times over. Each object must be gone once the
/// cycle lets go of it, and so must every config file a controller wrote.
@Suite("TerminalCoordinatorLifecycleStress", .serialized)
struct TerminalCoordinatorLifecycleStressTests {
    private static let cycles = 100

    @Test
    @MainActor
    func `repeated build, reconfigure and release leaks nothing`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let ledger = ManagedConfigLedger()
        var references: [WeakReference] = []

        for index in 0 ..< Self.cycles {
            autoreleasepool {
                references += Self.runCycle(index, ledger: ledger)
            }
            if index.isMultiple(of: 10) {
                await LifecycleStress.drainMainQueue()
            }
        }
        await LifecycleStress.drainMainQueue()

        #expect(LifecycleStress.survivors(references) == [])
        #expect(ledger.urls.count >= Self.cycles * 3)
        #expect(ledger.leftovers == [])
    }

    @Test
    @MainActor
    func `callbacks that outlive their coordinator are no-ops`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let controller = TerminalController()
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let tally = CallbackTally()
        var bridge: TerminalCallbackBridge?
        weak var weakCoordinator: TerminalSurfaceCoordinator?
        weak var weakSurface: TerminalSurface?

        do {
            let platformView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
            let probe = CallbackProbe(tally)
            var coordinator: TerminalSurfaceCoordinator? = Self.coordinator(platformView: platformView)
            coordinator?.delegate = probe
            coordinator?.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
            coordinator?.controller = controller
            try #require(coordinator?.surface != nil)
            session.receive("before teardown\r\n")
            #expect(session.waitForPendingOutput())
            bridge = coordinator?.bridge
            weakCoordinator = coordinator
            weakSurface = coordinator?.surface
            // Released while its delegate still listens: deinit is the teardown.
            coordinator = nil
            withExtendedLifetime((platformView, probe)) {}
        }
        await LifecycleStress.drainMainQueue()

        #expect(weakCoordinator == nil)
        #expect(weakSurface == nil)
        #expect(tally.attaches == 1)
        #expect(tally.detaches == 1)
        #expect(controller.retainedBridgeCount == 0)
        #expect(session.currentSurface == nil)
        let orphan = try #require(bridge)
        #expect(orphan.rawSurface == nil)

        // The coordinator's closures held it weakly: nothing to call now.
        orphan.onRenderRequest?()
        orphan.onCellSizeChange?(8, 16)
        orphan.onMouseShape?(GHOSTTY_MOUSE_SHAPE_TEXT)
        // The delegate was held weakly and is gone with its owner.
        #expect(orphan.delegate == nil)
        tally.reset()
        Self.sendTitle("after teardown", through: orphan)
        orphan.handleClose(processAlive: false)
        var answer: Bool?
        orphan.handleClipboardConfirmation(contents: "x", kind: .osc52Read) { answer = $0 }
        #expect(answer == false)
        #expect(tally.titles == [])
        #expect(tally.closes == 0)

        // No observer left behind for the controller's wakeup to reach.
        controller.handleWakeup()
        controller.tick()

        // Output with no surface waits for the next one instead of crashing.
        session.receive("after teardown\r\n")
        session.sendInput(Data("typed".utf8))
        await LifecycleStress.drainMainQueue()
        #expect(tally.attaches == 0)
        #expect(tally.detaches == 0)
    }

    // MARK: - Cycle

    @MainActor
    private static func runCycle(_ index: Int, ledger: ManagedConfigLedger) -> [WeakReference] {
        let controller = TerminalController(theme: LifecycleStress.theme(index)) {
            $0.withFontSize(Float(11 + index % 4))
        }
        ledger.record(controller)
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let platformView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let coordinator = coordinator(platformView: platformView)
        let tally = CallbackTally()
        let probe = CallbackProbe(tally)
        coordinator.delegate = probe
        coordinator.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        coordinator.controller = controller
        #expect(coordinator.surface != nil, "cycle \(index) built no surface")
        let firstSurface = coordinator.surface

        session.receive("cycle \(index)\r\n\u{1B}]2;title \(index)\u{07}\u{1B}[31mred\u{1B}[0m\r\n")
        #expect(session.waitForPendingOutput())

        controller.setTheme(LifecycleStress.theme(index + 1))
        ledger.record(controller)
        controller.setTerminalConfiguration(TerminalConfiguration { $0.withFontSize(Float(13 + index % 3)) })
        ledger.record(controller)
        controller.setColorScheme(index.isMultiple(of: 2) ? .dark : .light)
        ledger.record(controller)
        _ = controller.updateConfigSource(.generated("cursor-style = bar\n"))
        ledger.record(controller)

        // A surface option change rebuilds: the first surface must go too.
        coordinator.configuration.fontSize = Float(10 + index % 5)
        #expect(coordinator.surface != nil)
        #expect(coordinator.surface !== firstSurface)
        coordinator.synchronizeMetrics()
        coordinator.tick()
        #expect(controller.retainedBridgeCount == 1)
        #expect(tally.attaches == 2)
        #expect(tally.detaches == 1)

        // Every third cycle moves to another controller: the old one must
        // let go of the bridge and the new one take it.
        var replacement: TerminalController?
        if index % 3 == 1 {
            let next = TerminalController(theme: LifecycleStress.theme(index + 2))
            ledger.record(next)
            coordinator.controller = next
            #expect(controller.retainedBridgeCount == 0)
            #expect(next.retainedBridgeCount == 1)
            replacement = next
        }

        // Output still in flight when the surface goes.
        session.receive(Data(repeating: UInt8(ascii: "x"), count: 64 * 1024))

        // Half the cycles free explicitly, the rest leave it to deinit.
        if index.isMultiple(of: 2) {
            coordinator.freeSurface()
            #expect((replacement ?? controller).retainedBridgeCount == 0)
            #expect(session.currentSurface == nil)
        }

        var references = [
            WeakReference(controller, "controller \(index)"),
            WeakReference(coordinator, "coordinator \(index)"),
            WeakReference(coordinator.bridge, "bridge \(index)"),
            WeakReference(session, "session \(index)"),
            WeakReference(probe, "delegate \(index)"),
            WeakReference(platformView, "platform view \(index)"),
        ]
        if let replacement {
            references.append(WeakReference(replacement, "replacement controller \(index)"))
        }
        if let firstSurface {
            references.append(WeakReference(firstSurface, "first surface \(index)"))
        }
        if let surface = coordinator.surface {
            references.append(WeakReference(surface, "surface \(index)"))
        }
        withExtendedLifetime(probe) {}
        return references
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

    @MainActor
    private static func sendTitle(_ title: String, through bridge: TerminalCallbackBridge) {
        title.withCString { pointer in
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_SET_TITLE
            action.action.set_title.title = pointer
            bridge.handleAction(action)
        }
    }
}

@MainActor
private final class CallbackTally {
    var attaches = 0
    var detaches = 0
    var titles: [String] = []
    var closes = 0

    func reset() {
        attaches = 0
        detaches = 0
        titles = []
        closes = 0
    }
}

/// Reports into a tally the test keeps, so the delegate itself can die with
/// the cycle that made it.
@MainActor
private final class CallbackProbe:
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceCloseDelegate
{
    let tally: CallbackTally

    init(_ tally: CallbackTally) {
        self.tally = tally
    }

    func terminalDidAttachSurface(_: TerminalSurface) {
        tally.attaches += 1
    }

    func terminalDidDetachSurface() {
        tally.detaches += 1
    }

    func terminalDidChangeTitle(_ title: String) {
        tally.titles.append(title)
    }

    func terminalDidClose(processAlive _: Bool) {
        tally.closes += 1
    }
}
