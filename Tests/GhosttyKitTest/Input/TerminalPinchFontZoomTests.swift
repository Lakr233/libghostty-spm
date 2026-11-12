import CoreGraphics
@testable import GhosttyTerminal
import Testing

struct TerminalPinchFontZoomTests {
    @Test
    func `one step per tenth of scale and the rest carries over`() {
        var pinch = TerminalPinchFontZoom()
        pinch.begin(scale: 1)
        #expect(pinch.takeSteps(at: 1.05) == 0)
        #expect(pinch.takeSteps(at: 1.12) == 1)
        // 1.12 left 0.02 over: 0.09 more is a second step, not a first.
        #expect(pinch.takeSteps(at: 1.21) == 1)
        #expect(pinch.takeSteps(at: 1.55) == 3)
    }

    @Test
    func `pinching in steps down and back out steps up again`() {
        var pinch = TerminalPinchFontZoom()
        pinch.begin(scale: 1)
        #expect(pinch.takeSteps(at: 0.75) == -2)
        #expect(pinch.takeSteps(at: 0.95) == 1)
    }

    @Test
    func `a new pinch starts from its own scale`() {
        var pinch = TerminalPinchFontZoom()
        pinch.begin(scale: 1)
        _ = pinch.takeSteps(at: 1.5)
        pinch.end()
        pinch.begin(scale: 1)
        #expect(pinch.takeSteps(at: 1.05) == 0)
    }

    @Test
    func `steps stop at the gesture's own range`() {
        #expect(TerminalPinchFontZoom.bindingAction(growing: true, from: 12) == "increase_font_size:1")
        #expect(TerminalPinchFontZoom.bindingAction(growing: false, from: 12) == "decrease_font_size:1")
        #expect(TerminalPinchFontZoom.bindingAction(growing: true, from: 64) == nil)
        #expect(TerminalPinchFontZoom.bindingAction(growing: false, from: 4) == nil)
    }
}
