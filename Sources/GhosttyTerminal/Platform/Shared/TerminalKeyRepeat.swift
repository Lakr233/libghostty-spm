import Foundation

/// Which held hardware keys the view repeats itself, and how fast. On iOS
/// UIKit reports a held key once; the repeat belongs to the text input
/// system, which the terminal's keys never reach.
enum TerminalKeyRepeat {
    /// iPadOS exposes the user's Key Repeat setting to no app, so these
    /// follow AppKit's defaults.
    static let initialDelay: TimeInterval = 0.4
    static let interval: TimeInterval = 0.05

    /// Caps Lock and the eight modifier usages (HID 0xE0–0xE7). Holding one
    /// is not typing, and pressing one leaves a running repeat alone.
    static func isModifier(usage: UInt16) -> Bool {
        usage == 0x39 || (0xE0 ... 0xE7).contains(usage)
    }

    /// Whether a held key repeats. A Cmd combo is a shortcut, not typing.
    /// A key that is also a registered `UIKeyCommand` (the Ctrl combos,
    /// Escape) is delivered by that command — a repeat of its press would
    /// double the command's own, or repeat a press the claim dropped.
    static func repeats(
        usage: UInt16,
        isCommandModified: Bool,
        isKeyCommand: Bool,
    ) -> Bool {
        !isModifier(usage: usage) && !isCommandModified && !isKeyCommand
    }
}
