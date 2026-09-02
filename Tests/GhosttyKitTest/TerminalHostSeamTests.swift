import Foundation
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

    @Test
    @MainActor
    func `a change reverted within one turn publishes the reverted value`() async {
        let state = TerminalViewState()
        state.terminalDidChangeTitle("~")
        await nextMainQueueTurn()
        #expect(state.title == "~")
        #expect(!state.isFocused)

        state.terminalDidChangeTitle("ls")
        state.terminalDidChangeTitle("~")
        state.terminalDidChangeFocus(true)
        state.terminalDidChangeFocus(false)
        await nextMainQueueTurn()

        #expect(state.title == "~")
        #expect(!state.isFocused)
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

/// Resumes once every block the main queue held when this was called has
/// run — the queue is FIFO, so a deferred publish lands before this does.
private func nextMainQueueTurn() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
