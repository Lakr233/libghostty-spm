#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    @testable import GhosttyTerminal
    import Testing

    /// A trackpad scroll moves the viewport by the pixel
    /// (Patches/ghostty/0022), and hit testing counts in whole rows: when
    /// the scroll ends, the view's settler scrolls the part of a row left
    /// over to a whole row — the nearer one when the fingers had stopped,
    /// the one ahead when the viewport was still moving. The position is
    /// the engine's own (`ghostty_surface_smooth_scroll`).
    @Suite("AppTerminalViewSmoothScroll", .serialized)
    @MainActor
    struct AppTerminalViewSmoothScrollTests {
        @Test(.timeLimit(.minutes(1)))
        func `dragged to a stop a third of a row past, it settles back on that row`() async throws {
            try await checkLift(tenthsOfARow: 33, landsOn: 3, draggedToAStop: true)
        }

        @Test(.timeLimit(.minutes(1)))
        func `dragged to a stop two thirds of a row past, it settles on the next row`() async throws {
            try await checkLift(tenthsOfARow: 37, landsOn: 4, draggedToAStop: true)
        }

        /// The nearer row is behind it here; the viewport was still moving,
        /// so it goes on to the row ahead.
        @Test(.timeLimit(.minutes(1)))
        func `a lift with the viewport still moving goes on to the next row`() async throws {
            try await checkLift(tenthsOfARow: 33, landsOn: 4, draggedToAStop: false)
        }

        /// The next touch cuts momentum short while it still moves the
        /// viewport. Snapping to the nearer row would take it back, and the
        /// new gesture forward again: a string of flicks on a Magic Mouse
        /// jumped back and forth that way.
        @Test(.timeLimit(.minutes(1)))
        func `momentum cut short settles on the row ahead, not back`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }
            let before = try #require(rig.firstVisibleLine)

            let row = rig.cellHeight
            try rig.scroll(0, phase: .began)
            for _ in 0 ..< 4 {
                try rig.scroll(pixels: row / 2, phase: .changed)
            }
            try rig.scroll(0, phase: .ended)
            try rig.scroll(pixels: row / 10, momentum: .begin)
            for _ in 0 ..< 2 {
                try rig.scroll(pixels: row / 10, momentum: .continuing)
            }
            // Less than half a row past a row: the nearer row is behind.
            let past = rig.sentPixels % row
            try #require(past != 0 && past * 2 < row, "\(rig.sentPixels) px over \(row) px rows")
            var furthest = try rig.pixels()

            try rig.scroll(0, momentum: .end)
            while rig.settler.isSnapping {
                let now = try rig.pixels()
                #expect(now <= furthest, "the snap went back by \(now - furthest) px")
                furthest = min(furthest, now)
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(await rig.settles())
            #expect(before - (rig.firstVisibleLine ?? before) == rig.sentPixels / row + 1)
        }

        /// Momentum follows the lift: nothing snaps while it runs, and the
        /// lift's pending settle is cancelled by its first event.
        @Test(.timeLimit(.minutes(1)))
        func `momentum is left alone until it ends`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }

            let row = rig.cellHeight
            try rig.scroll(0, phase: .began)
            for _ in 0 ..< 4 {
                try rig.scroll(pixels: row / 2, phase: .changed)
            }
            try rig.scroll(0, phase: .ended)
            try rig.scroll(pixels: row * 2 / 5, momentum: .begin)
            for _ in 0 ..< 10 {
                try rig.scroll(pixels: row * 2 / 5, momentum: .continuing)
            }
            // Longer than the lift waits for momentum.
            try await Task.sleep(for: .milliseconds(150))
            #expect(!rig.settler.isSnapping)
            #expect(rig.fraction != 0)

            try rig.scroll(0, momentum: .end)
            #expect(await rig.settles())
            #expect(rig.fraction == 0)
        }

        /// Past the top and back past the bottom: the engine stops at the
        /// edge and keeps no part of a row, and neither does the view.
        @Test(.timeLimit(.minutes(1)))
        func `the ends of the scrollback leave nothing to settle`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig(lines: 60)
            defer { rig.tearDown() }
            let bottom = try #require(rig.firstVisibleLine)

            try rig.scroll(0, phase: .began)
            for _ in 0 ..< 60 {
                try rig.scroll(pixels: rig.cellHeight * 2 + 3, phase: .changed)
            }
            try rig.scroll(0, phase: .ended)
            #expect(await rig.settles())
            #expect(rig.firstVisibleLine == 0)
            #expect(rig.position?.row == 0)

            try rig.scroll(0, phase: .began)
            for _ in 0 ..< 60 {
                try rig.scroll(pixels: -(rig.cellHeight * 2 + 3), phase: .changed)
            }
            try rig.scroll(0, phase: .ended)
            #expect(await rig.settles())
            #expect(rig.firstVisibleLine == bottom)
            #expect(rig.position?.isAtBottom == true)
        }

        /// A program tracking the mouse gets the scroll as it came, and the
        /// view keeps no position for it.
        @Test(.timeLimit(.minutes(1)))
        func `a scroll reported to the program is not settled`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }
            let before = try #require(rig.firstVisibleLine)

            rig.receive("\u{1B}[?1000h\u{1B}[?1006h")
            try rig.scroll(0, phase: .began)
            try rig.scroll(pixels: rig.cellHeight * 5 / 2, phase: .changed)
            try rig.scroll(0, phase: .ended)
            try await Task.sleep(for: .milliseconds(300))

            #expect(rig.firstVisibleLine == before)
            #expect(rig.position?.isAvailable == false)
            #expect(rig.fraction == 0)
            #expect(!rig.settler.isSnapping)
        }

        /// A precise event with no phase — a synthesized pixel scroll, a
        /// smooth-scrolling utility — has no lift to wait for: it is
        /// settled once the events stop, on the way it was going.
        @Test(.timeLimit(.minutes(1)))
        func `a precise scroll with no phase settles when it stops`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }
            let before = try #require(rig.firstVisibleLine)

            // Three rows and a third, so no cell height sums to whole rows.
            let total = rig.cellHeight * 10 / 3
            for step in 0 ..< 6 {
                try rig.scroll(pixels: total * (step + 1) / 6 - total * step / 6)
            }
            try #require(rig.fraction != 0, "\(rig.sentPixels) px over \(rig.cellHeight) px rows")
            #expect(await rig.settles())
            #expect(before - (rig.firstVisibleLine ?? before) == rig.sentPixels / rig.cellHeight + 1)
        }

        /// A host's own precision scroll through the public API is settled
        /// like the trackpad's.
        @Test(.timeLimit(.minutes(1)))
        func `a host's precision scroll settles too`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }

            rig.view.sendMouseScroll(x: 0, y: Double(rig.cellHeight * 5 / 2))
            try #require(rig.fraction != 0)
            #expect(await rig.settles())
        }

        /// The fraction belongs to the viewport it was left in. Paging away
        /// and back to the same row is another viewport: nothing of it
        /// comes back.
        @Test(.timeLimit(.minutes(1)))
        func `moving the viewport any other way drops the fraction for good`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }

            try rig.scroll(0, phase: .began)
            try rig.scroll(pixels: rig.cellHeight * 33 / 10, phase: .changed)
            try #require(rig.fraction != 0)
            let row = try #require(rig.position?.row)

            // Paging goes through the IO thread: wait for each move.
            #expect(rig.view.performBindingAction("scroll_page_up"))
            let paged = await ScrollRig.wait(seconds: 5) { [rig] in rig.position.map { $0.row < row } ?? false }
            try #require(paged)
            #expect(rig.view.performBindingAction("scroll_page_down"))
            let back = await ScrollRig.wait(seconds: 5) { [rig] in rig.position?.row == row }
            try #require(back)
            #expect(rig.fraction == 0)
            try rig.scroll(0, phase: .ended)
            #expect(await rig.settles())
        }

        /// A new cell height is another viewport too: a fraction of the old
        /// row could be past the end of the new one.
        @Test(.timeLimit(.minutes(1)))
        func `a font size change drops the fraction`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }

            try rig.scroll(0, phase: .began)
            try rig.scroll(pixels: rig.cellHeight * 39 / 10, phase: .changed)
            try #require(rig.fraction != 0)
            #expect(rig.view.performBindingAction("decrease_font_size:4"))
            let resized = await ScrollRig.wait(seconds: 5) { [rig] in
                (rig.position?.cellHeight ?? rig.cellHeight) != rig.cellHeight
            }
            try #require(resized)
            #expect(rig.fraction == 0)
            try rig.scroll(0, phase: .ended)
        }

        /// The engine scales a precision scroll by
        /// `mouse-scroll-multiplier`; the settle reads where that left the
        /// viewport and still lands on a row.
        @Test(.timeLimit(.minutes(1)))
        func `a scroll multiplier still settles on a row`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig(config: [("mouse-scroll-multiplier", "precision:1.7")])
            defer { rig.tearDown() }
            let before = try #require(rig.firstVisibleLine)

            try rig.scroll(0, phase: .began)
            for _ in 0 ..< 5 {
                try rig.scroll(pixels: rig.cellHeight / 2, phase: .changed)
            }
            try #require(rig.fraction != 0)
            try rig.scroll(0, phase: .ended)
            #expect(await rig.settles())
            // 2.5 rows sent, 4.25 moved: on to the fifth.
            #expect(before - (rig.firstVisibleLine ?? before) == 5)
        }

        /// With `mouse-reporting = false` a program asking for the mouse
        /// does not get it, and the scroll is the viewport's.
        @Test(.timeLimit(.minutes(1)))
        func `mouse reporting turned off leaves the scroll to the viewport`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig(config: [("mouse-reporting", "false")])
            defer { rig.tearDown() }
            let before = try #require(rig.firstVisibleLine)

            rig.receive("\u{1B}[?1000h\u{1B}[?1006h")
            try rig.scroll(0, phase: .began)
            try rig.scroll(pixels: rig.cellHeight * 5 / 2, phase: .changed)
            #expect(rig.position?.isAvailable == true)
            #expect(rig.fraction != 0)
            try rig.scroll(0, phase: .ended)
            #expect(await rig.settles())
            #expect(before - (rig.firstVisibleLine ?? before) == 3)
        }

        /// Smooth scrolling is the views' to turn on: a surface left off
        /// scrolls a whole row at a time, as upstream does.
        @Test(.timeLimit(.minutes(1)))
        func `a surface not opted in scrolls by the row`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }
            let before = try #require(rig.firstVisibleLine)

            rig.view.surface?.setSmoothScrolling(false)
            try rig.scroll(0, phase: .began)
            try rig.scroll(pixels: rig.cellHeight * 13 / 10, phase: .changed)
            #expect(rig.position?.isAvailable == false)
            #expect(rig.fraction == 0)
            #expect(before - (rig.firstVisibleLine ?? before) == 1)
            try rig.scroll(0, phase: .ended)
        }

        /// `draggedToAStop`: the last two events move one point each, the
        /// fingers all but still when they lift.
        private func checkLift(tenthsOfARow tenths: Int, landsOn rows: Int, draggedToAStop: Bool) async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }
            let before = try #require(rig.firstVisibleLine)

            let slow = draggedToAStop ? 2 * rig.pixelsPerPoint : 0
            let total = rig.cellHeight * tenths / 10 - slow
            let steps = 8
            try rig.scroll(0, phase: .began)
            for step in 0 ..< steps {
                try rig.scroll(pixels: total * (step + 1) / steps - total * step / steps, phase: .changed)
            }
            if draggedToAStop {
                for _ in 0 ..< 2 {
                    try rig.scroll(pixels: rig.pixelsPerPoint, phase: .changed)
                }
            }
            // Between rows while the fingers are down.
            #expect(rig.fraction != 0)

            try rig.scroll(0, phase: .ended)
            #expect(await rig.settles())
            #expect(rig.fraction == 0)
            #expect(before - (rig.firstVisibleLine ?? before) == rows, "\(rig.sentPixels) px over \(rig.cellHeight) px rows")

            // And stays there.
            try await Task.sleep(for: .milliseconds(300))
            #expect(before - (rig.firstVisibleLine ?? before) == rows)
        }
    }

    /// An ``AppKitInputRig`` on screen with scrollback, fed trackpad events.
    /// The window is ordered in: the scrollbar the view scrolls against is
    /// reported by the renderer, which draws nothing for a window that is
    /// not.
    @MainActor
    final class ScrollRig {
        enum Phase: Int64 { case began = 1, changed = 2, ended = 4 }
        enum Momentum: Int64 { case begin = 1, continuing = 2, end = 3 }

        let rig: AppKitInputRig
        let cellHeight: Int
        private let scale: Double
        private(set) var sentPixels = 0
        /// Pixels asked for that did not make a whole point yet.
        private var unsentPixels = 0

        var view: AppTerminalView {
            rig.view
        }

        var settler: TerminalSmoothScrollSettler {
            rig.view.core.scrollSettler
        }

        /// Where the engine has the viewport now.
        var position: TerminalSmoothScrollPosition? {
            rig.view.surface?.smoothScrollPosition()
        }

        var fraction: Double {
            position?.fraction ?? 0
        }

        func pixels() throws -> Double {
            try #require(position).pixels
        }

        var pixelsPerPoint: Int {
            Int(scale)
        }

        init(lines: Int = 300, config: [(key: String, value: String)] = []) async throws {
            rig = AppKitInputRig(config: config)
            rig.window.orderFront(nil)
            // The grid a window reports as it comes on screen is not yet
            // the one it keeps: wait for it to hold before filling it.
            var grid = rig.view.surface?.size()
            var heldSince = ContinuousClock.now
            while ContinuousClock.now - heldSince < .milliseconds(400) {
                try await Task.sleep(for: .milliseconds(20))
                let now = rig.view.surface?.size()
                if now != grid {
                    grid = now
                    heldSince = ContinuousClock.now
                }
            }
            rig.receive((0 ..< lines).map { "line \($0)\r\n" }.joined())
            let metrics = try #require(rig.view.surface?.size())
            cellHeight = Int(metrics.cellHeightPixels)
            scale = rig.view.currentScaleFactor()
            let reported = await Self.wait(seconds: 10) { [rig] in
                rig.view.core.bridge.scrollbar.map { $0.total > $0.len && $0.offset + $0.len >= $0.total } ?? false
            }
            try #require(reported, "the renderer never reported the scrollback")
        }

        func tearDown() {
            rig.window.orderOut(nil)
            rig.tearDown()
        }

        func receive(_ text: String) {
            rig.receive(text)
        }

        /// The number in the viewport's first row of `line N` output.
        var firstVisibleLine: Int? {
            rig.session.readViewportText()?
                .components(separatedBy: "\n").first?
                .split(separator: " ").last
                .flatMap { Int($0) }
        }

        /// One trackpad event of `pixels` toward the scrollback. An event
        /// carries whole points; what is left of the pixels joins the next.
        func scroll(pixels: Int = 0, phase: Phase? = nil, momentum: Momentum? = nil) throws {
            unsentPixels += pixels
            let points = (Double(unsentPixels) / scale).rounded(.towardZero)
            unsentPixels -= Int(points * scale)
            let source = try #require(CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: Int32(points), wheel2: 0, wheel3: 0,
            ))
            source.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            source.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(points))
            source.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase?.rawValue ?? 0)
            source.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum?.rawValue ?? 0)
            let event = try #require(NSEvent(cgEvent: source))
            try #require(event.hasPreciseScrollingDeltas)
            sentPixels += Int(points * scale)
            rig.view.scrollWheel(with: event)
        }

        func scroll(_ pixels: Int, phase: Phase? = nil, momentum: Momentum? = nil) throws {
            try scroll(pixels: pixels, phase: phase, momentum: momentum)
        }

        /// The snap has run its course: nothing pending, no part of a row.
        func settles() async -> Bool {
            await Self.wait(seconds: 3) { [self] in
                !settler.isSnapping && fraction == 0
            }
        }

        static func wait(seconds: Double, until condition: @MainActor () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while !condition() {
                if ContinuousClock.now > deadline { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return true
        }
    }
#endif
