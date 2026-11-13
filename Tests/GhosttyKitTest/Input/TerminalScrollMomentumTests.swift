import CoreGraphics
@testable import GhosttyTerminal
import Testing

struct TerminalScrollMomentumTests {
    private func travel(from velocity: CGPoint, tick: Double) -> (distance: CGPoint, ticks: Int) {
        guard var momentum = TerminalScrollMomentum(velocity: velocity) else { return (.zero, 0) }
        var distance = CGPoint.zero
        var ticks = 0
        while let step = momentum.advance(by: tick) {
            distance.x += step.x
            distance.y += step.y
            ticks += 1
            if ticks > 100_000 { break }
        }
        return (distance, ticks)
    }

    @Test
    func `a slow lift does not glide`() {
        #expect(TerminalScrollMomentum(velocity: CGPoint(x: 10, y: -49)) == nil)
        #expect(TerminalScrollMomentum(velocity: CGPoint(x: 0, y: 50)) != nil)
    }

    @Test
    func `a flick glides the way it was going and comes to rest`() {
        let down = travel(from: CGPoint(x: 0, y: 1200), tick: 1.0 / 120)
        #expect(down.distance.y > 100)
        #expect(down.distance.x == 0)
        #expect(down.ticks < 1000)
        let up = travel(from: CGPoint(x: 0, y: -1200), tick: 1.0 / 120)
        #expect(abs(up.distance.y + down.distance.y) < 0.001)
    }

    @Test
    func `the distance does not depend on the tick rate`() {
        let fast = travel(from: CGPoint(x: 0, y: 1500), tick: 1.0 / 120).distance.y
        let slow = travel(from: CGPoint(x: 0, y: 1500), tick: 1.0 / 60).distance.y
        #expect(abs(fast - slow) / fast < 0.05)
    }

    @Test
    func `a stalled tick is not one long jump`() {
        var momentum = TerminalScrollMomentum(velocity: CGPoint(x: 0, y: 1000))
        let step = momentum?.advance(by: 5)
        #expect((step?.y ?? .infinity) <= 1000 * TerminalScrollMomentum.longestStep)
    }
}
