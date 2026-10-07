import AppKit
import Combine
@testable import GhosttyTerminal
import SwiftUI
import Testing

/// One `TerminalSurfaceView` whose `context` argument changes without an
/// `.id`: SwiftUI keeps the platform view and runs the update pass, so the
/// view must move to the new state — delegate, surface and attached view.
@Suite("TerminalSurfaceContextSwap", .serialized)
struct TerminalSurfaceContextSwapTests {
    @Test
    @MainActor
    func `a context with another session takes the rebuilt surface`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let first = Self.state(controller: TerminalController())
        let second = Self.state(controller: TerminalController())
        let host = SwapHost(first)
        host.pump()
        let view = first.attachedView
        #expect(view != nil)
        #expect(first.surface != nil)

        host.selection.state = second
        host.pump()

        #expect(second.attachedView === view)
        #expect(second.surface != nil)
        #expect(second.surface === view?.surface)
        #expect(first.surface == nil)
        #expect(first.attachedView == nil)
        #expect(view?.delegate === second)
    }

    @Test
    @MainActor
    func `a context with an equivalent surface takes the current one`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let controller = TerminalController()
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let first = TerminalViewState(controller: controller)
        let second = TerminalViewState(controller: controller)
        first.configuration.backend = .inMemory(session)
        second.configuration.backend = .inMemory(session)
        let host = SwapHost(first)
        host.pump()
        let surface = first.surface
        #expect(surface != nil)

        host.selection.state = second
        host.pump()

        #expect(second.surface === surface)
        #expect(first.surface == nil)
        #expect(first.attachedView == nil)
        #expect(second.attachedView?.delegate === second)
    }

    @MainActor
    private static func state(controller: TerminalController) -> TerminalViewState {
        let state = TerminalViewState(controller: controller)
        state.configuration.backend = .inMemory(
            InMemoryTerminalSession(write: { _ in }, resize: { _ in }),
        )
        return state
    }
}

@MainActor
private final class Selection: ObservableObject {
    @Published var state: TerminalViewState

    init(_ state: TerminalViewState) {
        self.state = state
    }
}

private struct SelectedPane: View {
    @ObservedObject var selection: Selection

    var body: some View {
        TerminalSurfaceView(context: selection.state)
            .frame(width: 320, height: 240)
    }
}

@MainActor
private final class SwapHost {
    let selection: Selection
    private let window: NSWindow

    init(_ state: TerminalViewState) {
        selection = Selection(state)
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SelectedPane(selection: selection))
        window.orderFront(nil)
    }

    func pump() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
    }

    deinit {
        MainActor.assumeIsolated {
            window.contentView = nil
            window.orderOut(nil)
        }
    }
}
