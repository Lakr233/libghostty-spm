@testable import GhosttyTerminal
import Testing

/// Font-size tracking against a live surface. Ghostty cannot report its
/// size, so the coordinator keeps it, and these check it moves exactly when
/// Ghostty's does: on build, binding actions, Cmd keys Ghostty binds, and
/// config reloads. The last test checks the tracked number against what
/// Ghostty actually renders.
@Suite("TerminalFontSizeTracking", .serialized)
struct TerminalFontSizeTrackingTests {
    @MainActor
    final class Recorder: TerminalSurfaceFontSizeDelegate {
        var sizes: [Float] = []

        func terminalDidChangeFontSize(_ fontSize: Float) {
            sizes.append(fontSize)
        }
    }

    @Test
    @MainActor
    func `every build reports the size it starts at`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let coordinator = harness.coordinator
        let recorder = Recorder()
        coordinator.delegate = recorder
        let configured = coordinator.controller?.configuredFontSize ?? 0
        #expect(configured > 0)
        #expect(coordinator.fontSize?.points == configured)

        coordinator.surface?.performBindingAction("set_font_size:20")
        coordinator.configuration.workingDirectory = "/tmp"
        #expect(coordinator.fontSize?.points == configured)

        coordinator.configuration.fontSize = 18
        #expect(coordinator.fontSize?.points == 18)

        // A deferred rebuild lands when the view has a size again.
        coordinator.viewSize = { (0, 0) }
        coordinator.configuration.fontSize = nil
        coordinator.viewSize = { (800, 500) }
        coordinator.synchronizeMetrics()
        #expect(recorder.sizes == [20, configured, 18, configured])

        coordinator.freeSurface()
        #expect(coordinator.fontSize == nil)
    }

    @Test
    @MainActor
    func `binding actions move the size and no-ops stay silent`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let coordinator = harness.coordinator
        coordinator.configuration.fontSize = 12
        let recorder = Recorder()
        coordinator.delegate = recorder
        let surface = coordinator.surface

        #expect(surface?.performBindingAction("increase_font_size:2") == true)
        #expect(surface?.performBindingAction("decrease_font_size:0.5") == true)
        #expect(surface?.performBindingAction("set_font_size:30") == true)
        #expect(surface?.performBindingAction("increase_font_size:-1") == true)
        #expect(surface?.performBindingAction("set_font_size:30") == true)
        #expect(surface?.performBindingAction("increase_font_size") == false)
        #expect(surface?.performBindingAction("select_all") == true)
        #expect(recorder.sizes == [14, 13.5, 30])

        #expect(surface?.performBindingAction("set_font_size:255") == true)
        #expect(surface?.performBindingAction("increase_font_size:1") == true)
        #expect(surface?.performBindingAction("reset_font_size") == true)
        let configured = coordinator.controller?.configuredFontSize ?? 0
        #expect(recorder.sizes == [14, 13.5, 30, 255, configured])
    }

    @Test
    @MainActor
    func `Cmd+= Cmd+- and Cmd+0 move the size through the default keybinds`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let coordinator = harness.coordinator
        let configured = coordinator.controller?.configuredFontSize ?? 0
        let surface = coordinator.surface

        surface?.sendKey(.equal, modifiers: .super_)
        surface?.sendKey(.equal, modifiers: .super_)
        #expect(coordinator.fontSize?.points == configured + 2)
        surface?.sendKey(.minus, modifiers: .super_)
        #expect(coordinator.fontSize?.points == configured + 1)
        surface?.sendKey(.digit0, modifiers: .super_)
        #expect(coordinator.fontSize?.points == configured)

        // Not zoom keys: typed, never counted.
        surface?.sendKey(.equal)
        surface?.sendKey(.minus, modifiers: .ctrl)
        #expect(coordinator.fontSize?.points == configured)
    }

    @Test
    @MainActor
    func `a Cmd key that the config leaves unbound leaves the size alone`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let coordinator = harness.coordinator
        coordinator.controller = TerminalController {
            $0.withCustom("keybind", "clear")
        }
        let configured = coordinator.controller?.configuredFontSize
        let cell = coordinator.surface?.size()?.cellHeightPixels
        // Under the kitty keyboard protocol an unbound Cmd key is not left
        // to the system: Ghostty encodes it for the program and reports it
        // handled, so only the binding check tells it from a zoom.
        harness.receive("\u{1B}[>1u")

        coordinator.surface?.sendKey(.equal, modifiers: .super_)
        coordinator.surface?.sendKey(.digit0, modifiers: .super_)
        coordinator.surface?.sendKey(.minus, modifiers: .super_)

        #expect(coordinator.fontSize?.points == configured)
        #expect(cell != nil)
        #expect(coordinator.surface?.size()?.cellHeightPixels == cell)
    }

    @Test
    @MainActor
    func `a config reload moves only an unzoomed size`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let coordinator = harness.coordinator
        let controller = coordinator.controller
        let recorder = Recorder()
        coordinator.delegate = recorder

        controller?.setTerminalConfiguration(TerminalConfiguration { $0.withFontSize(20) })
        #expect(controller?.configuredFontSize == 20)
        #expect(coordinator.fontSize?.points == 20)

        coordinator.surface?.performBindingAction("increase_font_size:1")
        controller?.setTerminalConfiguration(TerminalConfiguration { $0.withFontSize(16) })
        #expect(coordinator.fontSize?.points == 21)

        coordinator.surface?.performBindingAction("reset_font_size")
        #expect(coordinator.fontSize?.points == 16)
        #expect(recorder.sizes == [20, 21, 16])
    }

    /// The tracked number must be the size Ghostty renders: a surface built
    /// at the tracked size has the same cell as the one that was zoomed
    /// there.
    @Test
    @MainActor
    func `the tracked size is the size Ghostty renders`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let coordinator = harness.coordinator
        let surface = coordinator.surface
        surface?.sendKey(.equal, modifiers: .super_)
        surface?.performBindingAction("increase_font_size:7")
        surface?.sendKey(.minus, modifiers: .super_)
        surface?.performBindingAction("decrease_font_size:0.5")
        coordinator.controller?.setTerminalConfiguration(
            TerminalConfiguration { $0.withCursorStyle(.bar) },
        )
        let zoomedCell = surface?.size().map { [$0.cellWidthPixels, $0.cellHeightPixels] }
        let tracked = coordinator.fontSize?.points

        coordinator.configuration.fontSize = tracked
        let builtCell = coordinator.surface?.size().map { [$0.cellWidthPixels, $0.cellHeightPixels] }

        #expect(tracked == (coordinator.controller?.configuredFontSize).map { $0 + 6.5 })
        #expect(zoomedCell != nil)
        #expect(zoomedCell == builtCell)
    }

    @Test
    @MainActor
    func `the view state publishes the size on the next turn`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let state = TerminalViewState(controller: TerminalController())
        state.terminalDidChangeFontSize(18)
        #expect(state.fontSize == nil)
        await LifecycleStress.drainMainQueue(turns: 1)
        #expect(state.fontSize == 18)

        // Latest wins, and the no-change check runs at apply time.
        state.terminalDidChangeFontSize(20)
        state.terminalDidChangeFontSize(18)
        await LifecycleStress.drainMainQueue(turns: 1)
        #expect(state.fontSize == 18)

        harness.coordinator.delegate = state
        harness.surface?.performBindingAction("set_font_size:22")
        await LifecycleStress.drainMainQueue(turns: 1)
        #expect(state.fontSize == 22)
    }
}
