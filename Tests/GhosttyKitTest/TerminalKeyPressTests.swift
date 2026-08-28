import GhosttyKit
@testable import GhosttyTerminal
import Testing

// A programmatic key press rides `ghostty_surface_key`, so its keycode must
// survive the same translation a hardware key goes through. These tests pin
// that every named key resolves to a real AppKit keycode and back.
struct TerminalKeyPressTests {
    @Test
    func `every named key resolves to a real app kit keycode`() {
        for key in TerminalKeyPress.allCases {
            let code = TerminalHardwareKeyRouter.appKitKeyCode(for: key.ghosttyKey)
            #expect(code != TerminalHardwareKeyRouter.unidentifiedAppKitKeyCode,
                    "\(key) must map to a physical key")
        }
    }

    @Test
    func `the keycode round trips back to the same ghostty key`() {
        for key in TerminalKeyPress.allCases {
            let code = TerminalHardwareKeyRouter.appKitKeyCode(for: key.ghosttyKey)
            let back = TerminalHardwareKeyRouter.ghosttyKey(forAppKitKeyCode: UInt16(code))
            #expect(back == key.ghosttyKey, "\(key) must survive the round trip")
        }
    }
}
