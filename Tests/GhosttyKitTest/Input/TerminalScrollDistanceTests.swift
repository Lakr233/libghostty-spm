import CoreGraphics
@testable import GhosttyTerminal
import Testing

struct TerminalScrollDistanceTests {
    @Test
    func `view points scale to pixels by the display scale`() {
        let delta = CGPoint(x: 4, y: 10)
        #expect(TerminalScrollDistance.scrollPixels(for: delta, displayScale: 2) == CGPoint(x: 8, y: 20))
        #expect(TerminalScrollDistance.scrollPixels(for: delta, displayScale: 3) == CGPoint(x: 12, y: 30))
    }

    @Test
    func `scrolling up stays negative and a still finger sends nothing`() {
        #expect(TerminalScrollDistance.scrollPixels(for: CGPoint(x: 0, y: -10), displayScale: 2) == CGPoint(x: 0, y: -20))
        #expect(TerminalScrollDistance.scrollPixels(for: .zero, displayScale: 3) == .zero)
    }
}
