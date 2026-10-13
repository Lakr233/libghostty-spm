#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    @testable import GhosttyTerminal
    import Testing

    /// Issue #75 end to end: a selection made by mouse events through the
    /// AppKit view, then the press test a host runs in `mouseDown` to drag
    /// the selected text out, in the view's own (bottom-left) coordinates.
    @Suite("AppTerminalViewSelectionRegion", .serialized)
    @MainActor
    struct AppTerminalViewSelectionRegionTests {
        @MainActor
        private struct Pointer {
            let rig: AppKitInputRig
            let grid: TerminalSelectionGrid

            init?(_ rig: AppKitInputRig) {
                guard let surface = rig.view.surface, let metrics = surface.size(),
                      let first = surface.readCells(0 ... 0, columns: Int(metrics.columns), viewport: true),
                      let grid = TerminalSelectionGrid(
                          metrics: metrics, scale: CGFloat(rig.view.core.scaleFactor()),
                          firstBaseline: first.firstBaseline, imeBottom: surface.imePoint().y,
                      )
                else { return nil }
                self.rig = rig
                self.grid = grid
            }

            /// A point inside a cell, in the view's coordinates; `dx` is the
            /// fraction of the cell's width from its left edge.
            func point(_ column: Int, _ row: Int, dx: CGFloat = 0.5) -> NSPoint {
                let cell = grid.rect(for: row * grid.columns + column, viewportOffset: 0)
                return NSPoint(x: cell.minX + cell.width * dx, y: rig.view.bounds.height - cell.midY)
            }

            func event(_ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags) -> NSEvent {
                NSEvent.mouseEvent(
                    with: type, location: rig.view.convert(point, to: nil), modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1,
                )!
            }

            func drag(from start: (Int, Int), to end: (Int, Int), flags: NSEvent.ModifierFlags = []) {
                let from = point(start.0, start.1, dx: 0.25)
                let to = point(end.0, end.1, dx: 0.75)
                let view = rig.view
                view.mouseDown(with: event(.leftMouseDown, at: from, flags: flags))
                view.mouseDragged(with: event(
                    .leftMouseDragged, at: NSPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2), flags: flags,
                ))
                view.mouseDragged(with: event(.leftMouseDragged, at: to, flags: flags))
                view.mouseUp(with: event(.leftMouseUp, at: to, flags: flags))
            }
        }

        private func fill(_ rig: AppKitInputRig) {
            rig.receive((0 ..< 8).map { String(format: "line %03d abcdefghijklmnopqrstuvwxyz", $0) }
                .joined(separator: "\r\n"))
        }

        @Test
        func `a press over a dragged selection is on it, beside it is not`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }
            fill(rig)
            let pointer = try #require(Pointer(rig))
            #expect(rig.view.selectionRegion == nil)
            #expect(!rig.view.selectionContains(pointer.point(10, 2)))

            pointer.drag(from: (9, 1), to: (12, 3))

            let region = try #require(rig.view.selectionRegion)
            #expect(region.topLeft == TerminalViewportCell(column: 9, row: 1))
            #expect(region.bottomRight == TerminalViewportCell(column: 12, row: 3))
            #expect(!region.isRectangle)
            #expect(rig.view.viewportCell(at: pointer.point(20, 2)) == TerminalViewportCell(column: 20, row: 2))
            #expect(rig.view.selectionContains(pointer.point(9, 1)))
            #expect(rig.view.selectionContains(pointer.point(25, 1)))
            #expect(rig.view.selectionContains(pointer.point(2, 2)))
            #expect(rig.view.selectionContains(pointer.point(12, 3)))
            #expect(!rig.view.selectionContains(pointer.point(8, 1)))
            #expect(!rig.view.selectionContains(pointer.point(13, 3)))
            #expect(!rig.view.selectionContains(pointer.point(10, 0)))
            #expect(!rig.view.selectionContains(pointer.point(10, 4)))
        }

        @Test
        func `an Option drag is a rectangle and only its columns are on it`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }
            fill(rig)
            let pointer = try #require(Pointer(rig))

            pointer.drag(from: (12, 1), to: (16, 4), flags: .option)

            let region = try #require(rig.view.selectionRegion)
            #expect(region.isRectangle)
            #expect(rig.view.surface?.readSelection() == "defgh\ndefgh\ndefgh\ndefgh")
            #expect(rig.view.selectionContains(pointer.point(14, 2)))
            #expect(rig.view.selectionContains(pointer.point(16, 4)))
            #expect(!rig.view.selectionContains(pointer.point(25, 1)))
            #expect(!rig.view.selectionContains(pointer.point(2, 3)))
        }
    }
#endif
