@testable import GhosttyTerminal
import SwiftUI
import Testing

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("unsupported platform")
#endif

/// Mounts two surfaces the way a tabbed host does — every tab stays in the
/// tree, the hidden one behind `opacity(0)` — and checks that a change to
/// `TerminalViewState.isSurfaceVisible` reaches the platform view.
@Suite("TerminalSurfaceVisibilityDelivery", .serialized)
struct TerminalSurfaceVisibilityDeliveryTests {
    @Test
    @MainActor
    func `swapping the flags reaches both views, opacity untouched`() {
        let host = Host()
        host.pump()
        #expect(host.front.attachedView != nil)
        #expect(host.back.attachedView != nil)
        #expect(host.front.attachedView?.core.hostDeclaredDisplayVisible == true)
        #expect(host.back.attachedView?.core.hostDeclaredDisplayVisible == false)

        host.front.isSurfaceVisible = false
        host.back.isSurfaceVisible = true
        host.pump()

        #expect(host.front.attachedView?.core.hostDeclaredDisplayVisible == false)
        #expect(host.back.attachedView?.core.hostDeclaredDisplayVisible == true)
    }

    @Test
    @MainActor
    func `a tab switch in one turn reaches both views`() {
        let host = Host()
        host.pump()

        // The host order: the active id flips and its didSet swaps the flags.
        host.tabs.activeID = 1
        host.front.isSurfaceVisible = false
        host.back.isSurfaceVisible = true
        host.pump()

        #expect(host.front.attachedView?.core.hostDeclaredDisplayVisible == false)
        #expect(host.back.attachedView?.core.hostDeclaredDisplayVisible == true)
    }

    @Test
    @MainActor
    func `the visible tab alone hears its own flag`() {
        let host = Host()
        host.pump()

        host.front.isSurfaceVisible = false
        host.pump()

        #expect(host.front.attachedView?.core.hostDeclaredDisplayVisible == false)
    }
}

@MainActor
private final class Host {
    let front = TerminalViewState()
    let back = TerminalViewState()
    let tabs: Tabs
    #if canImport(UIKit)
        private let window: UIWindow
    #elseif canImport(AppKit)
        private let window: NSWindow
    #endif

    init() {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        front.configuration.backend = .inMemory(session)
        back.configuration.backend = .inMemory(session)
        back.isSurfaceVisible = false
        tabs = Tabs(tabs: [Tab(id: 0, state: front), Tab(id: 1, state: back)], activeID: 0)
        let frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        #if canImport(UIKit)
            window = UIWindow(frame: frame)
            window.rootViewController = UIHostingController(rootView: Panes(tabs: tabs))
            window.makeKeyAndVisible()
        #elseif canImport(AppKit)
            window = NSWindow(
                contentRect: frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(rootView: Panes(tabs: tabs))
            window.orderFront(nil)
        #endif
    }

    func pump() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
    }
}

private struct Tab: Identifiable {
    let id: Int
    let state: TerminalViewState
}

@MainActor
private final class Tabs: ObservableObject {
    @Published var tabs: [Tab]
    @Published var activeID: Int?

    init(tabs: [Tab], activeID: Int?) {
        self.tabs = tabs
        self.activeID = activeID
    }
}

/// The tabbed layout: `TerminalSurfaceView` per tab, focus bound, hidden
/// tabs at `opacity(0)`.
private struct Panes: View {
    @ObservedObject var tabs: Tabs
    @FocusState private var focusedTab: Int?

    var body: some View {
        ZStack {
            ForEach(tabs.tabs) { tab in
                let isActive = tab.id == tabs.activeID
                TerminalSurfaceView(context: tab.state)
                    .terminalFocused($focusedTab, equals: tab.id)
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
            }
        }
        .frame(width: 320, height: 240)
    }
}
