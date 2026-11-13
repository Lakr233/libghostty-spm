#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    @testable import GhosttyTerminal
    import Testing

    /// A trackpad's scroll delta arrives in view points and Ghostty reads a
    /// precision delta as pixels, so the view has to scale it: sent as it
    /// came, the content moved half as far as the fingers on a 2x display.
    @Suite("AppTerminalViewScroll", .serialized)
    @MainActor
    struct AppTerminalViewScrollTests {
        /// Ten and a half rows of finger travel scroll ten rows, or eleven
        /// when the engine draws part of a row (pixel smooth scrolling):
        /// within a row of the fingers either way, and five without the
        /// scaling. On a 1x display the scale is 1 and this holds regardless.
        @Test(.timeLimit(.minutes(1)))
        func `a precise scroll moves the content as far as the fingers`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }

            rig.receive((0 ..< 400).map { "line \($0)\r\n" }.joined())
            let metrics = try #require(rig.view.surface?.size())
            let scale = rig.view.currentScaleFactor()
            // An event's delta is in whole points.
            let rowPoints = Double(metrics.cellHeightPixels) / scale
            let points = (10.5 * rowPoints).rounded(.down)
            let before = try #require(firstVisibleLine(of: rig))

            let source = try #require(CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: Int32(points), wheel2: 0, wheel3: 0,
            ))
            let event = try #require(NSEvent(cgEvent: source))
            #expect(event.hasPreciseScrollingDeltas)
            #expect(abs(event.scrollingDeltaY - points) < 0.01)
            rig.view.scrollWheel(with: event)

            let after = try #require(firstVisibleLine(of: rig))
            let scrolled = Double(before - after)
            #expect(
                abs(scrolled - points / rowPoints) < 1,
                "scale \(scale): \(points) pt over \(rowPoints) pt rows scrolled \(scrolled) rows",
            )
        }

        /// The number in the viewport's first row of `line N` output.
        private func firstVisibleLine(of rig: AppKitInputRig) -> Int? {
            rig.session.readViewportText()?
                .components(separatedBy: "\n").first?
                .split(separator: " ").last
                .flatMap { Int($0) }
        }
    }
#endif
