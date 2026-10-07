import AppKit
@testable import GhosttyTerminal
import Testing

@MainActor
@Suite(.serialized)
struct TerminalBackgroundColorTests {
    private static let theme = TerminalTheme(
        light: TerminalConfiguration().background("#112233"),
        dark: TerminalConfiguration().background("#445566"),
    )

    @Test
    func `the controller reads the effective background back from ghostty`() {
        let controller = TerminalController(theme: Self.theme)
        #expect(controller.backgroundColor == TerminalColor(red: 0x11, green: 0x22, blue: 0x33))

        controller.setColorScheme(.dark)
        #expect(controller.backgroundColor == TerminalColor(red: 0x44, green: 0x55, blue: 0x66))
    }

    @Test
    func `the state follows a scheme the view sets for another delegate`() async {
        let state = TerminalViewState(theme: Self.theme)
        let delegate = ColorChangeRecorder()
        let view = AppTerminalView(frame: .zero)
        view.appearance = NSAppearance(named: .darkAqua)
        view.delegate = delegate
        view.controller = state.controller

        view.updateColorScheme()

        let dark = TerminalColor(red: 0x44, green: 0x55, blue: 0x66)
        await waitUntil { state.backgroundColor == dark }
        #expect(state.backgroundColor == dark)
    }

    @Test
    func `an OSC 11 background reaches the delegate`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        guard harness.surface != nil else { return }
        let recorder = ColorChangeRecorder()
        harness.coordinator.delegate = recorder

        harness.receive("\u{1B}]11;#123456\u{07}")

        let expected = TerminalColorChange(
            kind: .background,
            color: TerminalColor(red: 0x12, green: 0x34, blue: 0x56),
        )
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while clock.now < deadline, !recorder.changes.contains(expected) {
            await Task.yield()
        }
        #expect(recorder.changes.contains(expected))
    }

    @Test
    func `a reset hands the background back to the config`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        guard let controller = harness.coordinator.controller else { return }
        let state = TerminalViewState(controller: controller)
        harness.coordinator.delegate = state
        let configColor = controller.backgroundColor
        let programColor = TerminalColor(red: 0x12, green: 0x34, blue: 0x56)

        harness.receive("\u{1B}]11;#123456\u{07}")
        await waitUntil { state.backgroundColor == programColor }
        #expect(state.backgroundColor == programColor)

        harness.receive("\u{1B}]111\u{07}")
        await waitUntil { state.backgroundColor == configColor }
        #expect(state.backgroundColor == configColor)

        state.setTheme(Self.theme)
        #expect(state.backgroundColor == TerminalColor(red: 0x11, green: 0x22, blue: 0x33))
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while clock.now < deadline, !condition() {
            await Task.yield()
        }
    }
}

@MainActor
private final class ColorChangeRecorder: TerminalSurfaceColorChangeDelegate {
    var changes: [TerminalColorChange] = []

    func terminalDidChangeColor(_ change: TerminalColorChange) {
        changes.append(change)
    }
}
