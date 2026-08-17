import AppKit
import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

// Every key goes through `ghostty_surface_key` on every backend — the
// in-memory backend forwards the core encoder's output to the host, so no
// raw-byte side channel exists. These tests pin the platform keycode
// mappings that feed the key events.
struct TerminalHardwareKeyRouterTests {
    @Test
    func `maps UI kit usages to ghostty keys`() {
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forUIKitUsage: 0x28) == GHOSTTY_KEY_ENTER)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forUIKitUsage: 0x29) == GHOSTTY_KEY_ESCAPE)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forUIKitUsage: 0x2A) == GHOSTTY_KEY_BACKSPACE)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forUIKitUsage: 0x2B) == GHOSTTY_KEY_TAB)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forUIKitUsage: 0x50) == GHOSTTY_KEY_ARROW_LEFT)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forUIKitUsage: 0x52) == GHOSTTY_KEY_ARROW_UP)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forUIKitUsage: 0x04) == GHOSTTY_KEY_A)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forUIKitUsage: 0xFF) == GHOSTTY_KEY_UNIDENTIFIED)
    }

    @Test
    func `maps app kit key codes to ghostty keys`() {
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forAppKitKeyCode: 0x7B) == GHOSTTY_KEY_ARROW_LEFT)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forAppKitKeyCode: 0x75) == GHOSTTY_KEY_DELETE)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forAppKitKeyCode: 0x30) == GHOSTTY_KEY_TAB)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forAppKitKeyCode: 0x00) == GHOSTTY_KEY_A)
    }

    @Test
    func `translates UI kit usages to app kit keycodes for ghostty events`() {
        // Enter: HID 0x28 -> kVK_Return 0x24
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x28) == 0x24)
        // Left arrow: HID 0x50 -> kVK_LeftArrow 0x7B
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x50) == 0x7B)
        // NumLock prefers the explicit AppKit override (kVK_ANSI_KeypadClear).
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x53) == 0x47)
        // Unmappable usages fall outside the 8-bit native keycode range.
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0xFF)
                == TerminalHardwareKeyRouter.unidentifiedAppKitKeyCode
        )
    }
}
