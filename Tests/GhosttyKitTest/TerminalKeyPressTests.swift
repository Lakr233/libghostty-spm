import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

struct TerminalKeyTests {
    /// `GHOSTTY_KEY_UNIDENTIFIED` is 0 and `GHOSTTY_KEY_PASTE` closes the
    /// header's enum, so the raw value of the last key is the number of
    /// named keys. A header that grows fails this until the enum follows.
    @Test
    func `covers the whole header enum`() {
        #expect(TerminalKey.allCases.count == Int(GHOSTTY_KEY_PASTE.rawValue))
    }

    @Test
    func `names every libghostty key exactly once`() {
        var seen: Set<UInt32> = []
        for key in TerminalKey.allCases {
            #expect(key.ghosttyKey != GHOSTTY_KEY_UNIDENTIFIED)
            #expect(seen.insert(key.ghosttyKey.rawValue).inserted, "\(key) shares a ghostty key")
            #expect(TerminalKey(ghosttyKey: key.ghosttyKey) == key)
        }
        #expect(TerminalKey(ghosttyKey: GHOSTTY_KEY_UNIDENTIFIED) == nil)
    }

    /// A programmatic press rides `ghostty_surface_key`, which resolves the
    /// key from a macOS keycode: every key that claims one must survive the
    /// same translation a hardware key goes through.
    @Test
    func `keys with a mac keycode round trip through the router`() {
        for key in TerminalKey.allCases where key.hasPlatformKeycode {
            let code = TerminalHardwareKeyRouter.appKitKeyCode(for: key.ghosttyKey)
            let back = TerminalHardwareKeyRouter.ghosttyKey(forAppKitKeyCode: UInt16(code))
            #expect(back == key.ghosttyKey, "\(key) must survive the round trip")
        }
        #expect(TerminalKey.enter.hasPlatformKeycode)
        #expect(TerminalKey.f20.hasPlatformKeycode)
        #expect(!TerminalKey.mediaPlayPause.hasPlatformKeycode)
        #expect(!TerminalKey.kanaMode.hasPlatformKeycode)
    }

    @Test
    func `us layout lookup prefers the main block and reports shift`() {
        #expect(TerminalKey.usLayoutKey(typing: "5")?.key == .digit5)
        #expect(TerminalKey.usLayoutKey(typing: "5")?.shifted == false)
        #expect(TerminalKey.usLayoutKey(typing: "+")?.key == .equal)
        #expect(TerminalKey.usLayoutKey(typing: "+")?.shifted == true)
        #expect(TerminalKey.usLayoutKey(typing: "A")?.key == .a)
        #expect(TerminalKey.usLayoutKey(typing: "A")?.shifted == true)
        #expect(TerminalKey.usLayoutKey(typing: "~")?.key == .backquote)
        #expect(TerminalKey.usLayoutKey(typing: " ")?.key == .space)
        #expect(TerminalKey.usLayoutKey(typing: "\t") == nil)
        #expect(TerminalKey.usLayoutKey(typing: "é") == nil)
    }
}

struct TerminalKeyPressTests {
    @Test
    func `typing initializer folds shift into the modifiers`() {
        let press = TerminalKeyPress(typing: "C", modifiers: .ctrl)
        #expect(press?.key == .c)
        #expect(press?.modifiers == [.ctrl, .shift])
        #expect(press?.text == "C")
        #expect(press?.unshiftedCodepoint == 0x63)
        #expect(TerminalKeyPress(typing: "\u{3}") == nil)
    }

    @Test
    func `text follows shift and is withheld under command`() {
        #expect(TerminalKeyPress(.a).text == "a")
        #expect(TerminalKeyPress(.a, modifiers: .shift).text == "A")
        #expect(TerminalKeyPress(.a, modifiers: [.ctrl, .shift]).text == "A")
        #expect(TerminalKeyPress(.a, modifiers: .super_).text == nil)
        #expect(TerminalKeyPress(.space, modifiers: .shift).text == " ")
        #expect(TerminalKeyPress(.enter).text == nil)
        #expect(TerminalKeyPress(.enter).unshiftedCodepoint == 0)
    }

    @Test
    func `the event carries what the hardware paths carry`() {
        let press = TerminalKeyPress(.a, modifiers: [.ctrl, .shift])
        press.withKeyEvent(action: GHOSTTY_ACTION_PRESS) { event in
            #expect(event.action == GHOSTTY_ACTION_PRESS)
            // AppKit's keycode for the A key.
            #expect(event.keycode == 0x00)
            #expect(event.mods.rawValue == TerminalInputModifiers([.ctrl, .shift]).rawValue)
            // Shift produced the text and is spent; Control stays for bindings.
            #expect(event.consumed_mods.rawValue == TerminalInputModifiers.shift.rawValue)
            #expect(event.unshifted_codepoint == 0x61)
            #expect(event.text.map { String(cString: $0) } == "A")
            #expect(!event.composing)
        }
        press.withKeyEvent(action: GHOSTTY_ACTION_RELEASE) { event in
            #expect(event.action == GHOSTTY_ACTION_RELEASE)
            #expect(event.text == nil)
        }
    }

    /// The US table never applies Alt, so Alt is not spent: the encoder
    /// still sees it and can prefix ESC (Ctrl+Alt+C is `ESC 0x03`, not
    /// `0x03`).
    @Test
    func `alt is not consumed because the text never used it`() {
        TerminalKeyPress(.c, modifiers: [.ctrl, .alt]).withKeyEvent(action: GHOSTTY_ACTION_PRESS) { event in
            #expect(event.mods.rawValue == TerminalInputModifiers([.ctrl, .alt]).rawValue)
            #expect(event.consumed_mods.rawValue == 0)
            #expect(event.text.map { String(cString: $0) } == "c")
        }
        TerminalKeyPress(.a, modifiers: [.alt, .shift]).withKeyEvent(action: GHOSTTY_ACTION_PRESS) { event in
            #expect(event.consumed_mods.rawValue == TerminalInputModifiers.shift.rawValue)
            #expect(event.text.map { String(cString: $0) } == "A")
        }
    }
}

/// End to end through libghostty's key encoder on an in-memory session:
/// what a program on the other side of the pty reads.
@MainActor
struct TerminalKeyPressIntegrationTests {
    @Test
    func `enter takes the key path under bracketed paste`() async {
        let harness = GhosttySurfaceHarness()
        defer { harness.tearDown() }
        guard let surface = harness.surface else { return }
        // Kitty keeps Enter in legacy form unless report-all (bit 8) is
        // active, so combine it with disambiguate (bit 1).
        harness.receive("\u{1B}[?2004h\u{1B}[>9u")

        #expect(surface.sendKey(.enter))

        let bytes = await harness.drain()
        #expect(bytes.count(of: "\u{1B}[13u") == 1)
        #expect(!bytes.contains(0x0D))
        #expect(!bytes.contains(0x0A))
        #expect(bytes.count(of: "\u{1B}[200~") == 0)
    }

    @Test
    func `a release is reported when the program asks for key events`() async {
        let harness = GhosttySurfaceHarness()
        defer { harness.tearDown() }
        guard let surface = harness.surface else { return }
        // disambiguate (1) + report event types (2) + report all keys (8).
        harness.receive("\u{1B}[>11u")

        #expect(surface.sendKey(.enter))

        let bytes = await harness.drain()
        #expect(bytes.count(of: "\u{1B}[13u") == 1)
        #expect(bytes.count(of: "\u{1B}[13;1:3u") == 1)
    }

    @Test
    func `control c encodes the control byte`() async {
        let harness = GhosttySurfaceHarness()
        defer { harness.tearDown() }
        guard let surface = harness.surface else { return }

        #expect(surface.sendKey(.c, modifiers: .ctrl))

        let bytes = await harness.drain()
        #expect(bytes == Data([0x03]))
    }

    /// Alt is not spent by the US table, so the encoder still sees it and
    /// writes the ESC prefix a program reads as Meta.
    @Test
    func `control alt c keeps the alt escape prefix`() async {
        let harness = GhosttySurfaceHarness()
        defer { harness.tearDown() }
        guard let surface = harness.surface else { return }

        #expect(surface.sendKey(.c, modifiers: [.ctrl, .alt]))

        let bytes = await harness.drain()
        #expect(bytes == Data([0x1B, 0x03]))
    }

    @Test
    func `a typed character sends its text`() async {
        let harness = GhosttySurfaceHarness()
        defer { harness.tearDown() }
        guard let surface = harness.surface else { return }

        #expect(surface.sendKey(TerminalKeyPress(typing: "A")!))
        #expect(surface.sendKey(TerminalKeyPress(typing: "~")!))

        let bytes = await harness.drain()
        #expect(bytes == Data("A~".utf8))
    }

    @Test
    func `shift tab encodes back tab`() async {
        let harness = GhosttySurfaceHarness()
        defer { harness.tearDown() }
        guard let surface = harness.surface else { return }

        #expect(surface.sendKey(.tab, modifiers: .shift))

        let bytes = await harness.drain()
        #expect(bytes == Data("\u{1B}[Z".utf8))
    }

    @Test
    func `a key without a mac keycode is refused`() async {
        let harness = GhosttySurfaceHarness()
        defer { harness.tearDown() }
        guard let surface = harness.surface else { return }

        #expect(!surface.sendKey(.mediaPlayPause))

        let bytes = await harness.drain()
        #expect(bytes.isEmpty)
    }
}
