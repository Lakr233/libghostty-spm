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

        /// Patches/ghostty/0023: a step made with `smoothScrollTracked`
        /// is numbered, and `smoothScrollPresented` turns true once the
        /// renderer has handed over a frame that holds it. iOS system
        /// scrolling waits on that every frame; if it never came true,
        /// every frame there would wait out its budget.
        @Test(.timeLimit(.minutes(1)))
        func `a tracked scroll reports the frame that holds it`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }
            let surface = try #require(rig.view.surface)
            let before = try rig.pixels()

            for step in 1 ... 5 {
                surface.smoothScrollTracked(byPixels: 3)
                // The mark is set on the renderer's side: waiting here, on
                // the main thread, is exactly what the scroll view does.
                let deadline = ContinuousClock.now + .seconds(5)
                while !surface.smoothScrollPresented() {
                    try #require(ContinuousClock.now < deadline, "step \(step): no frame holding it was handed over")
                    usleep(200)
                }
            }
            #expect(try abs(rig.pixels() - before) == 15)
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

        /// A trackpad at 120 Hz moving about 150 pt/s sends a point or two
        /// an event. Lifted like that, the viewport is still moving: it
        /// goes on to the row ahead, and at once rather than after the wait
        /// for momentum. Judged by the last event's size, it settled back
        /// to the nearer row after an 80 ms pause.
        @Test(.timeLimit(.minutes(1)))
        func `a slow lift still moving goes on to the row ahead at once`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }
            let before = try #require(rig.firstVisibleLine)

            let point = rig.pixelsPerPoint
            let row = rig.cellHeight
            try rig.scroll(0, phase: .began)
            var step = 0
            // Two rows and a bit, the last event a single point.
            while rig.sentPixels < 2 * row + max(point, row / 5) {
                try rig.scroll(pixels: (step % 3 == 2 ? 2 : 1) * point, phase: .changed)
                step += 1
                try await Task.sleep(for: .milliseconds(8))
            }
            try rig.scroll(pixels: point, phase: .changed)
            let past = rig.sentPixels % row
            try #require(past * 2 < row, "\(rig.sentPixels) px over \(row) px rows: the nearer row is not behind")
            let start = try rig.pixels()

            try rig.scroll(0, phase: .ended)
            let lifted = ContinuousClock.now
            var firstMove: Duration?
            var furthest = start
            while rig.settler.isSnapping || firstMove == nil, ContinuousClock.now - lifted < .seconds(1) {
                let now = try rig.pixels()
                #expect(now <= furthest + 0.01, "the snap went back by \(now - furthest) px")
                furthest = min(furthest, now)
                if firstMove == nil, start - now > 0.3 { firstMove = ContinuousClock.now - lifted }
                try await Task.sleep(for: .milliseconds(1))
            }
            let moved = try #require(firstMove, "the viewport never went on")
            #expect(moved < .milliseconds(40), "the snap waited \(moved) before it moved")
            #expect(await rig.settles())
            #expect(before - (rig.firstVisibleLine ?? before) == 3)
        }

        /// Fingers held still send no events, so the last one is from
        /// before they stopped. Judged by its size, the viewport was still
        /// moving and went on up to a whole row; by the speed, which fades
        /// once events stop, it had stopped.
        @Test(.timeLimit(.minutes(1)))
        func `fingers held still before the lift settle on the nearer row`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }
            let before = try #require(rig.firstVisibleLine)

            // Four points an event, the last one too, until just past two
            // rows.
            let row = rig.cellHeight
            try rig.scroll(0, phase: .began)
            while rig.sentPixels <= 2 * row {
                try rig.scroll(pixels: 4 * rig.pixelsPerPoint, phase: .changed)
                try await Task.sleep(for: .milliseconds(12))
            }
            try #require(rig.sentPixels % row * 2 < row, "\(rig.sentPixels) px over \(row) px rows")
            try await Task.sleep(for: .milliseconds(150))

            try rig.scroll(0, phase: .ended)
            #expect(await rig.settles())
            #expect(before - (rig.firstVisibleLine ?? before) == 2)
        }

        /// A finger rests on the trackpad while momentum runs (the
        /// momentum ends, the gesture may begin), then lifts without moving
        /// (cancelled). To the nearer row, half the time that went back
        /// against the momentum; it goes on the way the momentum went.
        @Test(.timeLimit(.minutes(1)))
        func `momentum stopped by a touch goes on the way it went`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }
            let before = try #require(rig.firstVisibleLine)

            let row = rig.cellHeight
            try rig.scroll(0, phase: .began)
            try rig.scroll(pixels: row, phase: .changed)
            try rig.scroll(0, phase: .ended)
            try rig.scroll(pixels: row / 2, momentum: .begin)
            while rig.sentPixels < 2 * row + row / 4 {
                try rig.scroll(pixels: 2 * rig.pixelsPerPoint, momentum: .continuing)
                try await Task.sleep(for: .milliseconds(12))
            }
            try #require(rig.sentPixels % row * 2 < row, "\(rig.sentPixels) px over \(row) px rows")
            try rig.scroll(0, momentum: .end)
            try rig.scroll(0, phase: .mayBegin)
            try await Task.sleep(for: .milliseconds(100))

            try rig.scroll(0, phase: .cancelled)
            #expect(await rig.settles())
            #expect(before - (rig.firstVisibleLine ?? before) == 3)
        }

        /// Momentum running out at about 55 pt/s, most of a row short of
        /// the row ahead. Eased out over 180 ms, the snap started at three
        /// times its average and went faster than the momentum had (150
        /// pt/s over its first 50 ms); now it carries on at the momentum's
        /// speed and slows down from there.
        @Test(.timeLimit(.minutes(1)))
        func `the snap after momentum carries on at the momentum's speed`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }
            let before = try #require(rig.firstVisibleLine)

            let point = rig.pixelsPerPoint
            let row = rig.cellHeight
            try rig.scroll(0, phase: .began)
            for _ in 0 ..< 4 {
                try rig.scroll(pixels: row / 2, phase: .changed)
                try await Task.sleep(for: .milliseconds(12))
            }
            try rig.scroll(0, phase: .ended)
            for index in 0 ..< 5 {
                try rig.scroll(pixels: 3 * point, momentum: index == 0 ? .begin : .continuing)
                try await Task.sleep(for: .milliseconds(12))
            }
            // The tail, a point every 18 ms, until most of a row is left
            // to the row ahead.
            var tail: [ContinuousClock.Instant] = []
            while tail.count < 6 || !(0.6 ... 0.9).contains(rig.fraction / Double(row)) {
                try #require(tail.count < 200, "the tail never left most of a row to go")
                try rig.scroll(pixels: point, momentum: .continuing)
                tail.append(.now)
                try await Task.sleep(for: .milliseconds(18))
            }
            let span = try tail[0].duration(to: #require(tail.last))
            let endSpeed = Double((tail.count - 1) * point) / span.seconds
            let start = try rig.pixels()
            let left = rig.fraction

            try rig.scroll(0, momentum: .end)
            var samples: [(time: ContinuousClock.Instant, pixels: Double)] = []
            let ended = ContinuousClock.now
            while ContinuousClock.now - ended < .milliseconds(700) {
                try samples.append((.now, rig.pixels()))
                try await Task.sleep(for: .milliseconds(1))
            }
            var peak = 0.0
            for (index, from) in samples.enumerated() {
                guard let to = samples[index...].first(where: { from.time.duration(to: $0.time) >= .milliseconds(50) })
                else { break }
                peak = max(peak, (from.pixels - to.pixels) / from.time.duration(to: to.time).seconds)
            }
            let back = zip(samples, samples.dropFirst()).reduce(0) { $0 + max(0, $1.1.pixels - $1.0.pixels) }
            #expect(back < 0.01, "the snap went back by \(back) px")
            #expect(abs(start - (samples.last?.pixels ?? start) - left) < 0.5, "did not go on to the row ahead")
            #expect(peak < endSpeed * 1.5, "momentum ended at \(Int(endSpeed)) px/s, the snap reached \(Int(peak)) px/s")
            #expect(await rig.settles())
            #expect(before - (rig.firstVisibleLine ?? before) == (rig.sentPixels + row - 1) / row)
        }

        /// `draggedToAStop`: the last two events move one point each and
        /// the fingers rest a moment before they lift. The viewport counts
        /// as moving by its speed over the last 50 ms, and these events come
        /// back to back.
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
            if draggedToAStop {
                try await Task.sleep(for: .milliseconds(120))
            }

            try rig.scroll(0, phase: .ended)
            #expect(await rig.settles())
            #expect(rig.fraction == 0)
            #expect(before - (rig.firstVisibleLine ?? before) == rows, "\(rig.sentPixels) px over \(rig.cellHeight) px rows")

            // And stays there.
            try await Task.sleep(for: .milliseconds(300))
            #expect(before - (rig.firstVisibleLine ?? before) == rows)
        }
    }

    private extension Duration {
        var seconds: Double {
            Double(components.seconds) + Double(components.attoseconds) * 1e-18
        }
    }

    /// An ``AppKitInputRig`` on screen with scrollback, fed trackpad events.
    /// The window is ordered in: the scrollbar the view scrolls against is
    /// reported by the renderer, which draws nothing for a window that is
    /// not.
    @MainActor
    final class ScrollRig {
        enum Phase: Int64 { case began = 1, changed = 2, ended = 4, cancelled = 8, mayBegin = 128 }
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
