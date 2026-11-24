import CoreGraphics
@testable import GhosttyTerminal
import Testing

struct TerminalTouchResamplerTests {
    /// A finger moving down at `speed` points per second, reported `rate`
    /// times a second (`together` reports handed over at once), read at
    /// every refresh of a 120 Hz display. Returns each refresh's step.
    private func steps(
        speed: Double, rate: Double, together: Int = 1, phase: Double = 0.0031, seconds: Double = 0.5,
    ) -> [CGFloat] {
        var resampler = TerminalTouchResampler()
        resampler.begin()
        let refresh = 1.0 / 120
        var steps: [CGFloat] = []
        var reported = 0
        var frame = 1
        while Double(frame) * refresh < seconds {
            let time = Double(frame) * refresh + phase
            // Reports are handed over at the time of the last of their group.
            while Double(reported + together - 1) / rate <= time {
                for index in reported ..< reported + together {
                    resampler.add(CGPoint(x: 0, y: speed * Double(index) / rate), at: Double(reported + together - 1) / rate)
                }
                reported += together
            }
            steps.append(resampler.advance(to: time).y)
            frame += 1
        }
        return steps
    }

    @Test(arguments: [60.0, 100, 119, 120, 125, 240])
    func `a steady finger moves the same distance every refresh whatever the report rate`(rate: Double) {
        let speed = 300.0
        let steady = steps(speed: speed, rate: rate).dropFirst(6)
        let expected = CGFloat(speed / 120)
        for step in steady {
            #expect(abs(step - expected) < expected * 0.02, "\(rate) reports a second: \(step) against \(expected)")
        }
    }

    @Test
    func `reports handed over two at a time still move every refresh`() {
        let steady = steps(speed: 300, rate: 120, together: 2).dropFirst(6)
        let expected: CGFloat = 300.0 / 120
        for step in steady {
            #expect(abs(step - expected) < expected * 0.02)
        }
    }

    @Test
    func `a finger that stops is never passed and then brought back`() {
        var resampler = TerminalTouchResampler()
        resampler.begin()
        // 600 pt/s, then held still from 50 ms on: the last reports say so.
        var position: CGFloat = 0
        var handedOut: CGFloat = 0
        var time = 0.0
        for report in 0 ..< 12 {
            time = Double(report) / 120
            if report < 6 { position += 5 }
            resampler.add(CGPoint(x: 0, y: position), at: time)
            let step = resampler.advance(to: time + 0.004).y
            #expect(step >= 0)
            handedOut += step
        }
        // Past the last report with nothing new: no further than one
        // report's worth beyond it, and never back.
        for frame in 1 ... 6 {
            let step = resampler.advance(to: time + 0.004 + Double(frame) / 120).y
            #expect(step >= 0)
            handedOut += step
        }
        #expect(handedOut <= position + 0.001)
        handedOut += resampler.finish().y
        #expect(abs(handedOut - position) < 0.001)
    }

    @Test
    func `a prediction that ran ahead waits for the finger and the lift takes it back exactly`() {
        var resampler = TerminalTouchResampler()
        resampler.begin()
        resampler.add(.zero, at: 0)
        resampler.add(CGPoint(x: 0, y: 8), at: 1.0 / 60)
        // 12 ms past the last report: carried on at 480 pt/s.
        let ahead = resampler.advance(to: 1.0 / 60 + 0.012 + TerminalTouchResampler.latency).y
        #expect(ahead > 8)
        // The finger slowed down; the next report is behind the prediction.
        resampler.add(CGPoint(x: 0, y: 9), at: 2.0 / 60)
        #expect(resampler.advance(to: 2.0 / 60 + TerminalTouchResampler.latency).y == 0)
        #expect(abs(ahead + resampler.finish().y - 9) < 0.001)
    }

    @Test
    func `a finger that turns round is followed`() {
        var resampler = TerminalTouchResampler()
        resampler.begin()
        var total: CGFloat = 0
        for (index, position) in [0, 5, 10, 15, 12, 6, 0].enumerated() {
            let time = Double(index) / 120
            resampler.add(CGPoint(x: 0, y: CGFloat(position)), at: time)
            total += resampler.advance(to: time + TerminalTouchResampler.latency).y
        }
        #expect(abs(total) < 0.001)
    }

    @Test
    func `on a grid every step is whole and none of the finger's travel is lost`() {
        var resampler = TerminalTouchResampler()
        resampler.begin()
        var total: CGFloat = 0
        for report in 0 ..< 40 {
            // 173 pt/s at 100 reports a second: nothing lands on a half point.
            let time = Double(report) / 100
            resampler.add(CGPoint(x: 0, y: 1.73 * CGFloat(report)), at: time)
            for refresh in [time + 0.004, time + 0.009] {
                let step = resampler.advance(to: refresh, grid: 0.5).y
                #expect(step >= 0)
                #expect(abs((step / 0.5).rounded() - step / 0.5) < 1e-9)
                total += step
            }
        }
        total += resampler.finish().y
        #expect(abs(total - 1.73 * 39) < 1e-9)
    }

    /// The last reports of a finger on a MacBook Pro's touch display that
    /// slowed to a stop and lifted (seconds, points): 305, 62 and 60 pt/s,
    /// then nothing, then the lift 8 ms on. The pan recognizer's own
    /// velocity for it was 371 pt/s.
    @Test
    func `a finger that came to rest before it lifted has no speed to glide at`() {
        var resampler = TerminalTouchResampler()
        resampler.begin()
        let reports: [(Double, CGFloat)] = [
            (0.3828, 423.5), (0.3910, 426.0), (0.3991, 426.5), (0.4075, 427.0), (0.4159, 427.0),
        ]
        for (time, position) in reports {
            resampler.add(CGPoint(x: 0, y: position), at: time)
        }
        let speed = try? #require(resampler.velocity(at: 0.4242)).y
        #expect((speed ?? .infinity) < TerminalScrollMomentum.minimumSpeed)
        #expect(TerminalScrollMomentum(velocity: CGPoint(x: 0, y: speed ?? 0)) == nil)
    }

    @Test
    func `a finger at a steady speed lifts at that speed, and one that rests loses it`() throws {
        var resampler = TerminalTouchResampler()
        resampler.begin()
        for report in 0 ... 12 {
            resampler.add(CGPoint(x: 0, y: 5 * CGFloat(report)), at: Double(report) / 120)
        }
        let lift = 12.0 / 120
        #expect(try abs(#require(resampler.velocity(at: lift)).y - 600) < 1)
        // Half the window at rest: half the speed. All of it: none.
        #expect(try abs(#require(resampler.velocity(at: lift + 0.0125)).y - 300) < 1)
        #expect(try #require(resampler.velocity(at: lift + 0.05)).y == 0)
    }

    @Test
    func `reports handed over all at once say nothing about speed`() {
        var resampler = TerminalTouchResampler()
        resampler.begin()
        #expect(resampler.velocity(at: 1) == nil)
        resampler.add(.zero, at: 1)
        resampler.add(CGPoint(x: 0, y: 40), at: 1)
        #expect(resampler.velocity(at: 1) == nil)
        // A few milliseconds between them is a loop, not a finger.
        resampler.add(CGPoint(x: 0, y: 80), at: 1.003)
        resampler.add(CGPoint(x: 0, y: 120), at: 1.006)
        #expect(resampler.velocity(at: 1.006) == nil)
        resampler.add(CGPoint(x: 0, y: 124), at: 1.0145)
        #expect(resampler.velocity(at: 1.0145) != nil)
    }

    @Test
    func `reports far apart are not carried on`() {
        var resampler = TerminalTouchResampler()
        resampler.begin()
        resampler.add(.zero, at: 0)
        resampler.add(CGPoint(x: 0, y: 30), at: 0.3)
        #expect(resampler.advance(to: 0.32).y == 30)
        #expect(resampler.advance(to: 0.34).y == 0)
    }

    @Test
    func `with no refresh every report is scrolled exactly`() {
        var resampler = TerminalTouchResampler()
        resampler.begin()
        var total = CGPoint.zero
        for (index, position) in [3.5, 7.25, 7.25, 2.0].enumerated() {
            resampler.add(CGPoint(x: -position, y: position), at: Double(index) / 120)
            let step = resampler.finish()
            total.x += step.x
            total.y += step.y
            #expect(total == CGPoint(x: -position, y: position))
        }
        resampler.begin()
        #expect(resampler.finish() == .zero)
        #expect(resampler.advance(to: 1) == .zero)
    }
}
