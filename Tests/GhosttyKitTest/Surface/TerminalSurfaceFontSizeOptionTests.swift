@testable import GhosttyTerminal
import Testing

/// Ghostty snaps a surface it considers unadjusted back to the config's
/// `font-size` on every config reload. A size the host asked for through
/// `TerminalSurfaceOptions.fontSize` is a choice, like a zoom, and must
/// survive a reload that has nothing to do with it.
@Suite("TerminalSurfaceFontSizeOption", .serialized)
struct TerminalSurfaceFontSizeOptionTests {
    @Test
    @MainActor
    func `the fontSize option survives a config reload`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let coordinator = harness.coordinator
        coordinator.configuration.fontSize = 30
        let optionCell = coordinator.surface?.size()?.cellHeightPixels

        let reloaded = coordinator.controller?.setTerminalConfiguration(
            TerminalConfiguration { $0.withCursorStyle(.bar) }
        )

        #expect(reloaded == true)
        #expect(optionCell != nil)
        #expect(coordinator.surface?.size()?.cellHeightPixels == optionCell)
    }

    @Test
    @MainActor
    func `a surface without the option follows the config's font size`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let coordinator = harness.coordinator
        let configCell = coordinator.surface?.size()?.cellHeightPixels

        coordinator.controller?.setTerminalConfiguration(
            TerminalConfiguration { $0.withFontSize(30) }
        )

        #expect(configCell != nil)
        #expect(coordinator.surface?.size()?.cellHeightPixels != configCell)
    }
}
