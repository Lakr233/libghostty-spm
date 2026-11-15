@testable import GhosttyTerminal
import Testing

/// The viewport position the engine reports while precision scrolls move it
/// by the pixel, and the scroll that brings it back to a row.
struct TerminalSmoothScrollPositionTests {
    /// 30 px rows, 100 rows of scrollback.
    private func position(row: Int, fraction: Double = 0) -> TerminalSmoothScrollPosition {
        TerminalSmoothScrollPosition(isAvailable: true, row: row, maxRow: 100, fraction: fraction, cellHeight: 30)
    }

    @Test
    func `pixels count from the top of the scrollback`() {
        #expect(position(row: 0).pixels == 0)
        #expect(position(row: 49, fraction: 23.5).pixels == 49 * 30 + 23.5)
        #expect(position(row: 49).maxPixels == 3000)
    }

    @Test
    func `the last row is the bottom`() {
        #expect(position(row: 100).isAtBottom)
        #expect(!position(row: 99, fraction: 29).isAtBottom)
    }

    @Test
    func `the nearer row is behind up to half a row and ahead past it`() {
        #expect(position(row: 49, fraction: 10).pixelsToNearestRow == 10)
        #expect(position(row: 49, fraction: 15).pixelsToNearestRow == 15)
        #expect(position(row: 49, fraction: 16).pixelsToNearestRow == -14)
        #expect(position(row: 49).pixelsToNearestRow == 0)
    }

    @Test
    func `following the travel goes on to the row ahead and never back`() {
        let resting = position(row: 49, fraction: 10)
        // Going toward the scrollback: up to the row it is in.
        #expect(resting.pixelsToRow(following: 4) == 10)
        // Toward the active area: down to the next row, though it is the
        // farther one.
        #expect(resting.pixelsToRow(following: -4) == -20)
        // No travel: the nearer row.
        #expect(resting.pixelsToRow(following: 0) == 10)
        // On a row there is nothing to do, whichever way it went.
        #expect(position(row: 49).pixelsToRow(following: 4) == 0)
        #expect(position(row: 49).pixelsToRow(following: -4) == 0)
    }

    @Test
    func `the scroll to a row lands on it`() {
        for fraction in [0.5, 7.25, 14.999, 15, 15.001, 29.75] {
            let start = position(row: 49, fraction: fraction)
            for travel in [-3.0, 0, 3] {
                let landing = start.pixels - start.pixelsToRow(following: travel)
                #expect(landing.truncatingRemainder(dividingBy: 30) == 0, "\(fraction) \(travel)")
                #expect(abs(landing - start.pixels) < 30)
            }
        }
    }

    /// The last frame of a snap, read off a run that ended a row too far:
    /// a millionth of a pixel past row 271 of 18 px rows. The scroll back
    /// to the row has to be that fraction bit for bit, or the engine floors
    /// what is left into the row above.
    @Test
    func `the scroll to a pixel cancels the fraction exactly far down the scrollback`() {
        let fraction = Double(Float(1.1414863365644123e-06))
        let start = TerminalSmoothScrollPosition(
            isAvailable: true, row: 271, maxRow: 400, fraction: fraction, cellHeight: 18,
        )
        #expect(start.pixels(to: 271 * 18) == fraction)
        #expect(fraction - start.pixels(to: 272 * 18) == 18)
        #expect(start.pixels(to: 270 * 18) == fraction + 18)
        // What the snap sent before: a hair more than the fraction.
        #expect(start.pixels - Double(271 * 18) > fraction)
    }
}
