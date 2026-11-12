import CoreGraphics
@testable import GhosttyTerminal
import Testing

/// The arithmetic behind iOS system scrolling: a hidden scroll view's
/// content offset mapped onto the engine's viewport position.
struct TerminalScrollOffsetMappingTests {
    /// A 3x display, 51 px (17 pt) rows, 24 on a screen, 100 rows of
    /// scrollback; the scroll view's range is the engine's.
    private let mapping = TerminalScrollOffsetMapping(
        scale: 3,
        cellHeight: 51,
        screenRows: 24,
        engineMax: 5100,
        viewMax: 5100,
        shift: 0,
    )

    /// The same, with 60 px of output that arrived at the bottom under a
    /// finger: the engine is 60 px ahead of the offset.
    private let shifted = TerminalScrollOffsetMapping(
        scale: 3,
        cellHeight: 51,
        screenRows: 24,
        engineMax: 5100,
        viewMax: 5040,
        shift: 60,
    )

    @Test
    func `the rubber band is the part of the offset out of range`() {
        #expect(mapping.overscroll(offsetPixels: -30) == 30)
        #expect(mapping.overscroll(offsetPixels: 5130) == -30)
        #expect(mapping.overscroll(offsetPixels: 0) == 0)
        #expect(mapping.overscroll(offsetPixels: 2500) == 0)
        #expect(mapping.overscroll(offsetPixels: 5100) == 0)
    }

    @Test
    func `an offset maps to whole engine pixels inside the range`() {
        #expect(mapping.enginePixels(offsetPixels: 1000.4) == 1000)
        #expect(mapping.enginePixels(offsetPixels: 1000.6) == 1001)
        #expect(mapping.enginePixels(offsetPixels: -40) == 0)
        #expect(mapping.enginePixels(offsetPixels: 6000) == 5100)
    }

    @Test
    func `within half a pixel of the bottom is the bottom`() {
        #expect(mapping.isAtBottom(offsetPixels: 5099.6))
        #expect(mapping.enginePixels(offsetPixels: 5099.6) == 5100)
        #expect(!mapping.isAtBottom(offsetPixels: 5099.4))
    }

    @Test
    func `with output absorbed the scroll view's bottom stands for the engine's`() {
        #expect(shifted.enginePixels(offsetPixels: 100) == 160)
        #expect(shifted.enginePixels(offsetPixels: 5040) == 5100)
        #expect(shifted.offsetPixels(enginePixels: 1020) == 960)
        #expect(shifted.offsetPixels(enginePixels: 30) == 0)
        #expect(shifted.offsetPixels(enginePixels: 5100) == 5040)
    }

    @Test
    func `every row maps to an offset and back`() {
        for row in 0 ... 100 {
            let engine = row * 51
            #expect(mapping.enginePixels(offsetPixels: mapping.offsetPixels(enginePixels: engine)) == engine)
            #expect(shifted.enginePixels(offsetPixels: shifted.offsetPixels(enginePixels: engine)) == max(engine, 60))
        }
    }

    @Test
    func `the edges are the top at zero and the bottom at the end of the range`() {
        #expect(mapping.edge(offsetPixels: 0, enginePixels: 0) == -1)
        #expect(mapping.edge(offsetPixels: -12, enginePixels: 0) == -1)
        #expect(shifted.edge(offsetPixels: 0, enginePixels: 60) == 0)
        #expect(mapping.edge(offsetPixels: 5100, enginePixels: 5100) == 1)
        #expect(mapping.edge(offsetPixels: 5140, enginePixels: 5100) == 1)
        #expect(mapping.edge(offsetPixels: 2000, enginePixels: 2000) == 0)
        #expect(mapping.screenPixels == 51 * 24)
    }

    @Test
    func `the nearest row rounds half a row up and stops at the bottom`() {
        #expect(mapping.nearestRow(enginePixels: 1000) == 1020)
        #expect(mapping.nearestRow(enginePixels: 1045) == 1020)
        #expect(mapping.nearestRow(enginePixels: 1046) == 1071)
        #expect(mapping.nearestRow(enginePixels: 0) == 0)
        #expect(mapping.nearestRow(enginePixels: 5099) == 5100)
    }

    @Test
    func `a fling lands on a whole row of the engine`() {
        // 345 pt is 1035 px, 20.3 rows: back to row 20, 1020 px.
        #expect(mapping.landingOffset(proposed: 345) == 340)
        #expect(mapping.landingOffset(proposed: -80) == 0)
        #expect(mapping.landingOffset(proposed: 4000) == 1700)
        for proposed in stride(from: CGFloat(0), through: 1700, by: 7.3) {
            let engine = (mapping.landingOffset(proposed: proposed) * mapping.scale).rounded()
            #expect(Int(engine) % 51 == 0)
            #expect(abs(engine - proposed * 3) <= 25.5)
        }
        // Rounded in the engine's rows: 160 px of offset is 220 px in the
        // engine, row 4 (204 px), shown at 144 px of offset.
        #expect(shifted.landingOffset(proposed: 160.0 / 3) == 144.0 / 3)
    }

    @Test
    func `an offset is out of range only past UIKit's rounding`() {
        let unit: CGFloat = 1.0 / 3
        #expect(!TerminalScrollOffsetMapping.isOutOfRange(offset: -0.3, maxOffset: 1700, unit: unit))
        #expect(TerminalScrollOffsetMapping.isOutOfRange(offset: -0.4, maxOffset: 1700, unit: unit))
        #expect(!TerminalScrollOffsetMapping.isOutOfRange(offset: 1700.3, maxOffset: 1700, unit: unit))
        #expect(TerminalScrollOffsetMapping.isOutOfRange(offset: 1700.4, maxOffset: 1700, unit: unit))
    }

    /// One point over a 3x screen whose native scale is 2.807: an offset in
    /// pixels can only be written to the nearest third of a point.
    @Test
    func `an offset that rounds to where the scroll view is moves nothing`() {
        let unit: CGFloat = 1.0 / 3
        #expect(TerminalScrollOffsetMapping.rounds(100.1, onto: 100, unit: unit))
        #expect(!TerminalScrollOffsetMapping.rounds(100.2, onto: 100, unit: unit))
        #expect(TerminalScrollOffsetMapping.rounds(100.2, onto: 100 + unit, unit: unit))
    }
}
