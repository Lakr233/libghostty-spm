import AppKit
@testable import GhosttyTerminal
import SwiftUI
import Testing

/// `terminalFocused` binds a `FocusState` that no `.focused` modifier
/// anchors, so SwiftUI may hold or reset it to nil whatever the view's
/// first-responder status. A body re-run while it reads false must not
/// resign a terminal the user just clicked into.
@Suite("TerminalFocusBindingSync", .serialized)
struct TerminalFocusBindingSyncTests {
    @Test
    @MainActor
    func `an update with the binding out of sync keeps first responder`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let host = FocusHost()
        await host.pump()
        let view = host.state.attachedView
        #expect(view != nil)

        host.window.makeFirstResponder(view)
        await host.pump()
        let focusedAfterClick = host.window.firstResponder === view
        #expect(focusedAfterClick)

        // A representable input changes, so `updateNSView` runs while the
        // binding still reads false.
        host.state.configuration.resizeThrottleMilliseconds = 10
        await host.pump()
        host.state.configuration.resizeThrottleMilliseconds = 20
        await host.pump()

        let focusedAfterUpdates = host.window.firstResponder === view
        #expect(focusedAfterUpdates)
    }
}

private struct FocusedPane: View {
    let state: TerminalViewState
    @FocusState private var focused: Int?

    var body: some View {
        TerminalSurfaceView(context: state)
            .terminalFocused($focused, equals: 0)
            .frame(width: 320, height: 240)
    }
}

@MainActor
private final class FocusHost {
    let state = TerminalViewState()
    let window: NSWindow

    init() {
        state.configuration.backend = .inMemory(
            InMemoryTerminalSession(write: { _ in }, resize: { _ in }),
        )
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: FocusedPane(state: state),
        )
        window.orderFront(nil)
    }

    /// Suspends instead of spinning the run loop: a main-actor test runs
    /// inside a main-queue job, and a nested run never drains the
    /// `DispatchQueue.main.async` hop `synchronizeFocus` takes.
    func pump() async {
        try? await Task.sleep(for: .milliseconds(250))
    }

    deinit {
        MainActor.assumeIsolated {
            window.contentView = nil
            window.orderOut(nil)
        }
    }
}
