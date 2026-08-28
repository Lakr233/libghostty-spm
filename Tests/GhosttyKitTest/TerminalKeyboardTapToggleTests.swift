import Combine
@testable import GhosttyTerminal
import Testing

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
#endif

@Suite("TerminalKeyboardTapToggle")
struct TerminalKeyboardTapToggleTests {
    @Test
    @MainActor
    func `tap toggle defaults to enabled`() {
        let state = TerminalViewState()
        #expect(state.isKeyboardTapToggleEnabled)
    }

    @Test
    @MainActor
    func `platform view factory defaults to the base class`() {
        let state = TerminalViewState()
        #expect(state.makePlatformView == nil)
    }

    @Test
    @MainActor
    func `disabling the tap toggle publishes a change`() {
        let state = TerminalViewState()
        var notified = false
        let cancellable = state.objectWillChange.sink { notified = true }
        state.isKeyboardTapToggleEnabled = false
        #expect(notified)
        #expect(!state.isKeyboardTapToggleEnabled)
        _ = cancellable
    }

    #if canImport(AppKit) && !canImport(UIKit)
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
