#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    @testable import GhosttyTerminal
    import Testing

    /// `TerminalSurfaceOptions.scrollBehavior`: a viewport that rests where
    /// the scroll stopped, with presses still landing on the row under the
    /// pointer, and one that moves a row at a time.
    @Suite("AppTerminalViewScrollBehavior", .serialized)
    @MainActor
    struct AppTerminalViewScrollBehaviorTests {
        @Test(.timeLimit(.minutes(1)))
        func `resting anywhere, a scroll dragged to a stop stays between rows`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }
            rig.view.configuration.scrollBehavior = .restsAnywhere

            try drag(rig, tenthsOfARow: 37)
            let rested = try rig.pixels()
            #expect(rig.fraction != 0)

            try await Task.sleep(for: .milliseconds(700))
            #expect(!rig.settler.isSnapping)
            #expect(try rig.pixels() == rested)
        }

        @Test(.timeLimit(.minutes(1)))
        func `resting anywhere, momentum that runs out stays where it stopped`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }
            rig.view.configuration.scrollBehavior = .restsAnywhere

            let row = rig.cellHeight
            try rig.scroll(0, phase: .began)
            try rig.scroll(pixels: row * 2, phase: .changed)
            try rig.scroll(0, phase: .ended)
            try rig.scroll(pixels: row / 10, momentum: .begin)
            for _ in 0 ..< 2 {
                try rig.scroll(pixels: row / 10, momentum: .continuing)
            }
            try rig.scroll(0, momentum: .end)
            let rested = try rig.pixels()
            try #require(rig.fraction != 0)

            try await Task.sleep(for: .milliseconds(700))
            #expect(!rig.settler.isSnapping)
            #expect(try rig.pixels() == rested)
        }

        /// Most of the first row is scrolled off: counted from the
        /// viewport's first row, the middle of a drawn row belongs to the
        /// row above it.
        @Test(.timeLimit(.minutes(1)))
        func `resting anywhere, a drag selects the row drawn under the pointer`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }
            rig.view.configuration.scrollBehavior = .restsAnywhere

            try drag(rig, tenthsOfARow: 33)
            let rested = try rig.pixels()
            let position = try #require(rig.position)
            try #require(position.fraction * 2 > Double(position.cellHeight))
            let first = try #require(rig.firstVisibleLine)

            let pointer = try #require(DrawnRows(rig))
            pointer.drag(acrossRow: 5, columns: 0 ... 12)

            #expect(try rig.pixels() == rested, "the press moved the viewport")
            let selected = rig.view.surface?.readSelection()?.trimmingCharacters(in: .whitespaces)
            #expect(selected == "line \(first + 5)")
        }

        @Test(.timeLimit(.minutes(1)))
        func `settling again brings a viewport left between rows to a row`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }
            rig.view.configuration.scrollBehavior = .restsAnywhere
            try drag(rig, tenthsOfARow: 33)
            try await Task.sleep(for: .milliseconds(300))
            try #require(rig.fraction != 0)

            rig.view.configuration.scrollBehavior = .settlesOnRow
            #expect(await rig.settles())
        }

        @Test(.timeLimit(.minutes(1)))
        func `a row at a time, a precision scroll never rests between rows`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }
            let before = try #require(rig.firstVisibleLine)
            rig.view.configuration.scrollBehavior = .rowAtATime

            try rig.scroll(0, phase: .began)
            try rig.scroll(pixels: rig.cellHeight * 13 / 10, phase: .changed)
            #expect(rig.position?.isAvailable == false)
            #expect(rig.fraction == 0)
            #expect(before - (rig.firstVisibleLine ?? before) == 1)
            try rig.scroll(0, phase: .ended)

            rig.view.configuration.scrollBehavior = .settlesOnRow
            try rig.scroll(0, phase: .began)
            try rig.scroll(pixels: rig.cellHeight * 4 / 10, phase: .changed)
            #expect(rig.fraction != 0)
            try rig.scroll(0, phase: .ended)
            #expect(await rig.settles())
        }

        @Test(.timeLimit(.minutes(1)))
        func `going a row at a time puts a viewport between rows on one`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = try await ScrollRig()
            defer { rig.tearDown() }
            rig.view.configuration.scrollBehavior = .restsAnywhere
            try drag(rig, tenthsOfARow: 33)
            try #require(rig.fraction != 0)

            rig.view.configuration.scrollBehavior = .rowAtATime
            #expect(rig.fraction == 0)
        }

        /// Dragged to a stop: the last two events move a point each.
        private func drag(_ rig: ScrollRig, tenthsOfARow tenths: Int) throws {
            let total = rig.cellHeight * tenths / 10 - 2 * rig.pixelsPerPoint
            try rig.scroll(0, phase: .began)
            for step in 0 ..< 8 {
                try rig.scroll(pixels: total * (step + 1) / 8 - total * step / 8, phase: .changed)
            }
            for _ in 0 ..< 2 {
                try rig.scroll(pixels: rig.pixelsPerPoint, phase: .changed)
            }
            try rig.scroll(0, phase: .ended)
        }

        /// Mouse events aimed at rows where they are drawn: a viewport
        /// between rows is drawn the part of a row scrolled off higher.
        @MainActor
        private struct DrawnRows {
            let rig: ScrollRig
            let grid: TerminalSelectionGrid
            let lift: CGFloat

            init?(_ rig: ScrollRig) {
                let view = rig.view
                guard let surface = view.surface, let metrics = surface.size(),
                      let first = surface.readCells(0 ... 0, columns: Int(metrics.columns), viewport: true),
                      let grid = TerminalSelectionGrid(
                          metrics: metrics, scale: CGFloat(view.core.scaleFactor()),
                          firstBaseline: first.firstBaseline, imeBottom: surface.imePoint().y,
                      )
                else { return nil }
                self.rig = rig
                self.grid = grid
                lift = CGFloat(rig.fraction) / CGFloat(view.core.scaleFactor())
            }

            func point(_ column: Int, _ row: Int, dx: CGFloat) -> NSPoint {
                let cell = grid.rect(for: row * grid.columns + column, viewportOffset: 0)
                return NSPoint(x: cell.minX + cell.width * dx, y: rig.view.bounds.height - (cell.midY - lift))
            }

            func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(
                    with: type, location: rig.view.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.view.window?.windowNumber ?? 0,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1,
                )!
            }

            func drag(acrossRow row: Int, columns: ClosedRange<Int>) {
                let from = point(columns.lowerBound, row, dx: 0.25)
                let to = point(columns.upperBound, row, dx: 0.75)
                let view = rig.view
                view.mouseDown(with: event(.leftMouseDown, at: from))
                view.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: (from.x + to.x) / 2, y: from.y)))
                view.mouseDragged(with: event(.leftMouseDragged, at: to))
                view.mouseUp(with: event(.leftMouseUp, at: to))
            }
        }
    }
#endif
