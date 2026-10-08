import Foundation
@testable import GhosttyTerminal
import Testing

struct TerminalKeyRepeatTests {
    /// HID usages: A, Delete, Return, Space, Left Arrow, Up Arrow, F5.
    @Test(arguments: [0x04, 0x2A, 0x28, 0x2C, 0x50, 0x52, 0x3E] as [UInt16])
    func `typing and navigation keys repeat`(usage: UInt16) {
        #expect(TerminalKeyRepeat.repeats(
            usage: usage,
            isCommandModified: false,
            isKeyCommand: false,
            isRepeatedBySystem: false,
        ))
    }

    /// Caps Lock and Left/Right Control, Shift, Option, Command.
    @Test(arguments: [0x39, 0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7] as [UInt16])
    func `modifiers never repeat`(usage: UInt16) {
        #expect(TerminalKeyRepeat.isModifier(usage: usage))
        #expect(!TerminalKeyRepeat.repeats(
            usage: usage,
            isCommandModified: false,
            isKeyCommand: false,
            isRepeatedBySystem: false,
        ))
    }

    @Test
    func `usages beside the modifier block are not modifiers`() {
        #expect(!TerminalKeyRepeat.isModifier(usage: 0xDF))
        #expect(!TerminalKeyRepeat.isModifier(usage: 0xE8))
        #expect(!TerminalKeyRepeat.isModifier(usage: 0x3A))
    }

    @Test
    func `command combos do not repeat`() {
        #expect(!TerminalKeyRepeat.repeats(
            usage: 0x2E,
            isCommandModified: true,
            isKeyCommand: false,
            isRepeatedBySystem: false,
        ))
    }

    /// Ctrl+C and Escape arrive through a `UIKeyCommand`. On a system that
    /// also delivers the press, repeating it would double the command.
    @Test
    func `keys owned by a key command do not repeat`() {
        #expect(!TerminalKeyRepeat.repeats(
            usage: 0x06,
            isCommandModified: false,
            isKeyCommand: true,
            isRepeatedBySystem: false,
        ))
        #expect(!TerminalKeyRepeat.repeats(
            usage: 0x29,
            isCommandModified: false,
            isKeyCommand: true,
            isRepeatedBySystem: false,
        ))
    }

    /// Mac Catalyst repeats a held letter or Delete itself, through
    /// `insertText` / `deleteBackward`; a second repeat would type it twice.
    @Test
    func `keys the system repeats do not repeat`() {
        #expect(!TerminalKeyRepeat.repeats(
            usage: 0x04,
            isCommandModified: false,
            isKeyCommand: false,
            isRepeatedBySystem: true,
        ))
    }

    /// A letter, Delete (DEL or BS), Return, Tab, Space, Option+A.
    @Test(arguments: ["a", "\u{7F}", "\u{08}", "\r", "\t", " ", "å"])
    func `keys that type text`(characters: String) {
        #expect(TerminalKeyRepeat.typesText(charactersIgnoringModifiers: characters))
    }

    /// Arrows and Home as UIKit names them and as AppKit's private-use
    /// scalars, F5, and a key with no characters.
    @Test(arguments: [
        "UIKeyInputLeftArrow", "UIKeyInputUpArrow", "UIKeyInputHome",
        "\u{F702}", "\u{F729}", "\u{F708}", "",
    ])
    func `keys that type no text`(characters: String) {
        #expect(!TerminalKeyRepeat.typesText(charactersIgnoringModifiers: characters))
    }

    @Test
    func `a key with unknown characters types no text`() {
        #expect(!TerminalKeyRepeat.typesText(charactersIgnoringModifiers: nil))
    }

    @Test
    func `the system timing is used when it is a positive duration`() {
        let timing = TerminalKeyRepeat.timing(systemDelay: 0.5, systemInterval: 1.0 / 12)
        #expect(timing.initialDelay == 0.5)
        #expect(timing.interval == 1.0 / 12)
    }

    @Test(arguments: [
        (nil, nil), (0.5, nil), (nil, 0.05), (0, 0.05), (0.5, 0), (-1, 0.05),
        (.infinity, 0.05), (0.5, .nan),
    ] as [(TimeInterval?, TimeInterval?)])
    func `a missing or invalid system timing falls back`(delay: TimeInterval?, interval: TimeInterval?) {
        let timing = TerminalKeyRepeat.timing(systemDelay: delay, systemInterval: interval)
        #expect(timing.initialDelay == TerminalKeyRepeat.initialDelay)
        #expect(timing.interval == TerminalKeyRepeat.interval)
    }
}
