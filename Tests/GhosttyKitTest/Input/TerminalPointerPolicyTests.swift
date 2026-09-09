import GhosttyKit
@testable import GhosttyTerminal
import Testing

struct TerminalPointerPolicyTests {
    @Test
    func `maps secondary middle extra and primary`() {
        #expect(GHOSTTY_MOUSE_LEFT.rawValue == 1)
        #expect(GHOSTTY_MOUSE_RIGHT.rawValue == 2)
        #expect(GHOSTTY_MOUSE_MIDDLE.rawValue == 3)
        #expect(GHOSTTY_MOUSE_FOUR.rawValue == 4)
        #expect(GHOSTTY_MOUSE_ELEVEN.rawValue == 11)

        #expect(
            TerminalPointerPolicy.ghosttyButton(secondary: true, middle: false)
                == GHOSTTY_MOUSE_RIGHT
        )
        #expect(
            TerminalPointerPolicy.ghosttyButton(secondary: false, middle: true)
                == GHOSTTY_MOUSE_MIDDLE
        )
        #expect(
            TerminalPointerPolicy.ghosttyButton(
                secondary: false,
                middle: false,
                extraButtonNumber: 4
            ) == GHOSTTY_MOUSE_FOUR
        )
        #expect(
            TerminalPointerPolicy.ghosttyButton(
                secondary: false,
                middle: false,
                extraButtonNumber: 11
            ) == GHOSTTY_MOUSE_ELEVEN
        )
        #expect(
            TerminalPointerPolicy.ghosttyButton(secondary: false, middle: false)
                == GHOSTTY_MOUSE_LEFT
        )
        #expect(
            TerminalPointerPolicy.ghosttyButton(
                secondary: false,
                middle: false,
                extraButtonNumber: 3
            ) == GHOSTTY_MOUSE_LEFT
        )
        #expect(
            TerminalPointerPolicy.ghosttyButton(
                secondary: true,
                middle: true,
                extraButtonNumber: 4
            ) == GHOSTTY_MOUSE_RIGHT
        )
    }

    @Test
    func `host secondary menu is blocked while the mouse is captured`() {
        #expect(
            TerminalPointerPolicy.shouldPresentHostSecondaryMenu(mouseCaptured: false)
        )
        #expect(
            !TerminalPointerPolicy.shouldPresentHostSecondaryMenu(mouseCaptured: true)
        )
    }

    @Test
    func `press and cancel pair once`() {
        var session = TerminalPointerButtonSession()
        #expect(session.press(GHOSTTY_MOUSE_LEFT) == GHOSTTY_MOUSE_LEFT)
        #expect(session.reported == GHOSTTY_MOUSE_LEFT)
        #expect(session.cancel() == GHOSTTY_MOUSE_LEFT)
        #expect(session.reported == nil)
        #expect(session.cancel() == nil)
    }

    @Test
    func `a second press is ignored until release`() {
        var session = TerminalPointerButtonSession()
        #expect(session.press(GHOSTTY_MOUSE_LEFT) == GHOSTTY_MOUSE_LEFT)
        #expect(session.press(GHOSTTY_MOUSE_RIGHT) == nil)
        #expect(session.reported == GHOSTTY_MOUSE_LEFT)
        #expect(session.release(GHOSTTY_MOUSE_LEFT) == GHOSTTY_MOUSE_LEFT)
        #expect(session.press(GHOSTTY_MOUSE_RIGHT) == GHOSTTY_MOUSE_RIGHT)
    }

    @Test
    func `release of a different button is ignored`() {
        var session = TerminalPointerButtonSession()
        #expect(session.press(GHOSTTY_MOUSE_LEFT) == GHOSTTY_MOUSE_LEFT)
        #expect(session.release(GHOSTTY_MOUSE_RIGHT) == nil)
        #expect(session.reported == GHOSTTY_MOUSE_LEFT)
        #expect(session.finish() == GHOSTTY_MOUSE_LEFT)
        #expect(session.finish() == nil)
    }
}
