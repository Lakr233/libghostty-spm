import QuartzCore
@testable import GhosttyTerminal
import Testing

/// The speed the settler's snap sets off at, and what tells a viewport
/// still moving from one brought to a stop when the fingers lift.
@MainActor
struct TerminalSmoothScrollSettlerVelocityTests {
    private func settler() -> TerminalSmoothScrollSettler {
        let settler = TerminalSmoothScrollSettler { nil }
        // Nothing to snap; only the scrolls are counted.
        settler.settlesAutomatically = false
        return settler
    }

    @Test
    func `the speed is the scrolls of the last 50 ms`() {
        let settler = settler()
        for _ in 0 ..< 3 {
            settler.didScroll(up: 10)
        }
        let now = CACurrentMediaTime()
        #expect(abs(settler.velocity(at: now) - 30 / TerminalSmoothScrollSettler.velocityWindow) < 1)
        settler.didScroll(up: -40)
        #expect(settler.velocity(at: CACurrentMediaTime()) < 0)
    }

    /// Fingers held still send nothing: the speed fades from the window's
    /// end and is gone by `velocityStaleAfter`.
    @Test
    func `the speed fades once the scrolls stop`() {
        let settler = settler()
        settler.didScroll(up: 20)
        let last = CACurrentMediaTime()
        let full = 20 / TerminalSmoothScrollSettler.velocityWindow
        #expect(abs(settler.velocity(at: last + 0.075) - full / 2) < full * 0.05)
        #expect(settler.velocity(at: last + TerminalSmoothScrollSettler.velocityStaleAfter) == 0)
        #expect(TerminalSmoothScrollSettler { nil }.velocity() == 0)
    }
}
