@testable import GhosttyTerminal
import Testing

#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
#endif

@Suite("TerminalHostSeams")
struct TerminalHostSeamTests {
    @Test
    @MainActor
    func `platform view factory defaults to the base class`() {
        let state = TerminalViewState()
        #expect(state.makePlatformView == nil)
    }

    #if !canImport(UIKit) && canImport(AppKit)
        @Test
        @MainActor
        func `snapshot renders an offscreen view`() {
            let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
            #expect(view.snapshotImage() != nil)
        }

        @Test
        @MainActor
        func `snapshot of a zero-size view is nil`() {
            let view = AppTerminalView(frame: .zero)
            #expect(view.snapshotImage() == nil)
        }
    #endif
}
