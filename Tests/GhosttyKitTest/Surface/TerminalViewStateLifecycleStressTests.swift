#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    import Combine
    import Foundation
    @testable import GhosttyTerminal
    import SwiftUI
    import Testing

    /// The host-facing objects — `TerminalViewState`, its controller, the
    /// platform view and the SwiftUI view around it — made, attached to a
    /// window, reconfigured, detached and dropped over and over. Each must
    /// deallocate, and no generated config file may stay behind.
    @Suite("TerminalViewStateLifecycleStress", .serialized)
    @MainActor
    struct TerminalViewStateLifecycleStressTests {
        @Test
        func `platform views attached and dropped release their whole stack`() async {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let window = Self.window()
            defer { window.contentView = nil }
            let ledger = ManagedConfigLedger()
            var references: [WeakReference] = []

            for index in 0 ..< 60 {
                autoreleasepool {
                    references += Self.runViewCycle(index, in: window, ledger: ledger)
                }
                if index.isMultiple(of: 10) {
                    await LifecycleStress.drainMainQueue()
                }
            }
            await LifecycleStress.drainMainQueue()

            #expect(references.count == 60 * 8)
            #expect(LifecycleStress.survivors(references) == [])
            #expect(ledger.leftovers == [])
        }

        @Test
        func `a hosted surface view swapped between states and removed releases them all`() async {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let ledger = ManagedConfigLedger()
            var references: [WeakReference] = []

            for round in 0 ..< 8 {
                references += await Self.runHostingRound(round, ledger: ledger)
            }
            await LifecycleStress.drainMainQueue()

            #expect(references.count == 8 * 15)
            #expect(LifecycleStress.survivors(references) == [])
            #expect(ledger.leftovers == [])
        }

        @Test
        func `state callbacks queued before release do not resurrect it`() async {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            weak var weakState: TerminalViewState?

            do {
                let state = TerminalViewState(controller: TerminalController())
                weakState = state
                // Every one of these queues a closure for the next turn.
                state.terminalDidChangeTitle("queued")
                state.terminalDidRingBell()
                state.terminalDidChangeFocus(true)
                state.terminalDidChangeWorkingDirectory("/tmp")
                state.adoptSoon(terminalColorScheme: .dark)
                state.requestFocus()
            }
            #expect(weakState == nil)
            // Running the queued closures against a dead state must do nothing.
            await LifecycleStress.drainMainQueue()
            #expect(weakState == nil)
        }

        // MARK: - Platform view cycle

        private static func runViewCycle(
            _ index: Int,
            in window: NSWindow,
            ledger: ManagedConfigLedger,
        ) -> [WeakReference] {
            let controller = TerminalController(theme: LifecycleStress.theme(index)) {
                $0.withFontSize(Float(11 + index % 4))
            }
            ledger.record(controller)
            let state = TerminalViewState(controller: controller)
            let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
            state.configuration = TerminalSurfaceOptions(backend: .inMemory(session))

            let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
            view.delegate = state
            view.controller = controller
            view.configuration = state.configuration
            #expect(view.surface == nil, "cycle \(index) built before attach")

            window.contentView = view
            #expect(view.surface != nil, "cycle \(index) built no surface on attach")
            #expect(state.surface === view.surface)
            let firstSurface = view.surface

            session.receive("cycle \(index)\r\n\u{1B}]2;title \(index)\u{07}")
            #expect(session.waitForPendingOutput())

            state.setTheme(LifecycleStress.theme(index + 1))
            ledger.record(controller)
            state.setTerminalConfiguration(TerminalConfiguration { $0.withFontSize(Float(12 + index % 3)) })
            ledger.record(controller)
            state.adopt(terminalColorScheme: index.isMultiple(of: 2) ? .dark : .light)
            ledger.record(controller)
            view.setSurfaceVisible(false)
            view.setSurfaceVisible(true)

            // Surface options rebuild; the state follows the new surface.
            view.configuration.fontSize = Float(10 + index % 5)
            #expect(view.surface !== firstSurface)
            #expect(state.surface === view.surface)
            view.setFrameSize(NSSize(width: 400 + index % 7 * 10, height: 300))

            // Leaving the window keeps the surface: a reattach must not
            // discard scrollback. Only releasing the view frees it.
            let surface = view.surface
            window.contentView = nil
            #expect(view.surface === surface)
            if index.isMultiple(of: 3) {
                window.contentView = view
                #expect(view.surface === surface)
                window.contentView = nil
            }

            var references = [
                WeakReference(controller, "controller \(index)"),
                WeakReference(state, "state \(index)"),
                WeakReference(session, "session \(index)"),
                WeakReference(view, "view \(index)"),
                WeakReference(view.core, "coordinator \(index)"),
                WeakReference(view.core.bridge, "bridge \(index)"),
            ]
            if let firstSurface {
                references.append(WeakReference(firstSurface, "first surface \(index)"))
            }
            if let surface {
                references.append(WeakReference(surface, "surface \(index)"))
            }
            return references
        }

        // MARK: - SwiftUI hosting round

        private static func runHostingRound(
            _ round: Int,
            ledger: ManagedConfigLedger,
        ) async -> [WeakReference] {
            var references: [WeakReference] = []
            let states = (0 ..< 3).map { offset in
                let controller = TerminalController(theme: LifecycleStress.theme(round * 3 + offset))
                ledger.record(controller)
                let state = TerminalViewState(controller: controller)
                state.configuration = TerminalSurfaceOptions(
                    backend: .inMemory(InMemoryTerminalSession(write: { _ in }, resize: { _ in })),
                )
                return state
            }
            for (offset, state) in states.enumerated() {
                references.append(WeakReference(state, "state \(round).\(offset)"))
                references.append(WeakReference(state.controller, "controller \(round).\(offset)"))
                if let session = state.configuration.inMemorySession {
                    references.append(WeakReference(session, "session \(round).\(offset)"))
                }
            }

            var host: HostedPane? = HostedPane(states[0])
            await host?.settle { states[0].surface != nil }
            let view = states[0].attachedView
            #expect(view != nil, "round \(round) mounted no platform view")
            if let view {
                references.append(WeakReference(view, "platform view \(round)"))
                references.append(WeakReference(view.core, "coordinator \(round)"))
            }

            // Swap the context without an `.id`: SwiftUI keeps the platform
            // view and hands it to each state in turn.
            for step in 1 ... 4 {
                let next = states[step % states.count]
                host?.selection.state = next
                await host?.settle { next.surface != nil && next.attachedView === view }
                #expect(next.attachedView === view, "round \(round) step \(step) lost the view")
                #expect(next.surface === view?.surface)
                if let surface = next.surface {
                    references.append(WeakReference(surface, "surface \(round).\(step)"))
                }
                next.setTerminalConfiguration(TerminalConfiguration { $0.withFontSize(Float(11 + step)) })
                ledger.record(next.controller)
            }
            for state in states {
                ledger.record(state.controller)
            }

            host?.remove()
            await host?.settle { true }
            host = nil
            return references
        }

        private static func window() -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                styleMask: [.titled],
                backing: .buffered,
                defer: false,
            )
            window.isReleasedWhenClosed = false
            return window
        }
    }

    @MainActor
    private final class PaneSelection: ObservableObject {
        @Published var state: TerminalViewState

        init(_ state: TerminalViewState) {
            self.state = state
        }
    }

    private struct SelectedPane: View {
        @ObservedObject var selection: PaneSelection

        var body: some View {
            TerminalSurfaceView(context: selection.state)
                .frame(width: 320, height: 240)
        }
    }

    /// A `TerminalSurfaceView` in an `NSHostingView` in an off-screen window.
    /// Ordered front so SwiftUI lays it out; never made key.
    @MainActor
    private final class HostedPane {
        let selection: PaneSelection
        private var window: NSWindow?

        init(_ state: TerminalViewState) {
            selection = PaneSelection(state)
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled],
                backing: .buffered,
                defer: false,
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SelectedPane(selection: selection))
            window.orderFront(nil)
            self.window = window
        }

        /// Runs the runloop until `condition` holds, a short slice at a time,
        /// so a fast machine does not pay a fixed delay per step.
        func settle(timeout: TimeInterval = 2, until condition: () -> Bool) async {
            let deadline = Date(timeIntervalSinceNow: timeout)
            repeat {
                Self.runLoopSlice()
                await Task.yield()
            } while !condition() && Date() < deadline
        }

        private nonisolated static func runLoopSlice() {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }

        func remove() {
            window?.contentView = nil
            window?.orderOut(nil)
            window = nil
        }
    }
#endif
