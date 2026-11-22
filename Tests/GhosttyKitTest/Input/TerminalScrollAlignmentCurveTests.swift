import CoreGraphics
@testable import GhosttyTerminal
import Testing

/// The curve an alignment to a whole row runs along: it sets off at the
/// scroll's speed, from rest at zero, and arrives at rest on the row.
struct TerminalScrollAlignmentCurveTests {
    /// Points per second at the start of a curve over `distance` points.
    private func startSpeed(_ curve: TerminalScrollAlignmentCurve, distance: CGFloat) -> CGFloat {
        let dt = 0.0001
        return distance * curve.value(at: CGFloat(dt / curve.duration)) / CGFloat(dt)
    }

    @Test
    func `from rest it starts at no speed`() {
        let curve = TerminalScrollAlignmentCurve(distance: 6, velocity: 0, longest: 0.25)
        #expect(curve.duration == 0.25)
        #expect(curve.startSlope == 0)
        #expect(curve.value(at: 0) == 0)
        #expect(curve.value(at: 1) == 1)
        // The first 60 Hz frame of 0.25 s: under 2% of the way, where the
        // cubic ease-out went 18.7%.
        #expect(curve.value(at: 1.0 / 15) < 0.02)
        #expect(1 - pow(1 - 1.0 / 15, 3) > 0.18)
    }

    @Test
    func `it sets off at the speed the scroll had`() {
        // 6 pt at 120 pt/s: the ease-out over 3 * 6 / 120 s starts at 120.
        let quick = TerminalScrollAlignmentCurve(distance: 6, velocity: 120, longest: 0.25)
        #expect(abs(quick.duration - 0.15) < 1e-9)
        #expect(abs(quick.startSlope - 3) < 1e-9)
        #expect(abs(startSpeed(quick, distance: 6) - 120) < 1)
        // Slow, the duration from rest is enough and the start still keeps
        // the speed.
        let slow = TerminalScrollAlignmentCurve(distance: 13, velocity: 30, longest: 0.25)
        #expect(slow.duration == 0.25)
        #expect(abs(startSpeed(slow, distance: 13) - 30) < 1)
        // Toward the top, distance and velocity are both negative.
        let back = TerminalScrollAlignmentCurve(distance: -6, velocity: -120, longest: 0.25)
        #expect(abs(back.startSlope - 3) < 1e-9)
    }

    /// Too fast for the distance: the duration stops at its shortest and
    /// the start at three times the average, the fastest that does not
    /// overshoot.
    @Test
    func `a start too fast for the distance is capped`() {
        let curve = TerminalScrollAlignmentCurve(distance: 1, velocity: 250, longest: 0.25)
        #expect(curve.duration == TerminalScrollAlignmentCurve.shortestDuration)
        #expect(curve.startSlope == 3)
    }

    @Test
    func `a velocity away from the row counts as rest`() {
        let curve = TerminalScrollAlignmentCurve(distance: 6, velocity: -200, longest: 0.25)
        #expect(curve.startSlope == 0)
        #expect(curve.duration == 0.25)
    }

    /// The Mac's snap after momentum: the speed falls in a straight line
    /// from the momentum's to zero.
    @Test
    func `a preferred slope of 2 slows down evenly`() {
        let curve = TerminalScrollAlignmentCurve(distance: 13, velocity: 100, longest: 0.4, preferredSlope: 2)
        #expect(abs(curve.duration - 0.26) < 1e-9)
        #expect(abs(curve.startSlope - 2) < 1e-9)
        let du: CGFloat = 0.0001
        let speedAt = { (u: CGFloat) in (curve.value(at: u + du) - curve.value(at: u)) / du }
        #expect(abs(speedAt(0.5) - speedAt(0) / 2) < 0.001)
        #expect(abs(speedAt(0.25) - speedAt(0) * 3 / 4) < 0.001)
        // Slower momentum takes the longest duration and keeps its speed.
        let slow = TerminalScrollAlignmentCurve(distance: 13, velocity: 60, longest: 0.4, preferredSlope: 2)
        #expect(slow.duration == 0.4)
        #expect(abs(startSpeed(slow, distance: 13) - 60) < 1)
    }

    @Test
    func `it never overshoots the row or turns back`() {
        let cases: [(CGFloat, CGFloat)] = [(6, 0), (6, 60), (6, 120), (1, 250), (13, 30), (6, -200), (-6, -90)]
        for (distance, velocity) in cases {
            let curve = TerminalScrollAlignmentCurve(distance: distance, velocity: velocity, longest: 0.25)
            #expect(curve.duration >= TerminalScrollAlignmentCurve.shortestDuration)
            var last: CGFloat = 0
            for step in 1 ... 200 {
                let value = curve.value(at: CGFloat(step) / 200)
                #expect(value >= last - 1e-9, "\(distance) pt at \(velocity) pt/s went back")
                #expect(value <= 1 + 1e-9, "\(distance) pt at \(velocity) pt/s overshot")
                last = value
            }
        }
    }
}
