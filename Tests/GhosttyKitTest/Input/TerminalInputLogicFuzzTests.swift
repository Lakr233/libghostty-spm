import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// Seeded fuzzing of the pure input types: document/marked-offset
/// conversion, the marked-text editing model, the hardware key tables and
/// the shell escaper. Every input is drawn from `SeededGenerator`, so a
/// failure reproduces from the seed in its message.
struct TerminalInputLogicFuzzTests {
    private static let seeds: [UInt64] = [1, 7, 42, 2026, 0xDEAD_BEEF]

    /// Text an input method can mark: ASCII, Latin with a combining mark,
    /// CJK, Hangul, and astral emoji that take two UTF-16 units each.
    private static let markedAlphabet = [
        "a", "b", "z", " ", "e\u{301}", "\u{4E2D}", "\u{6587}", "\u{AC00}",
        "\u{3042}", "\u{1F600}", "\u{1F44D}\u{1F3FD}", "\u{20BB7}",
    ]

    // MARK: - TerminalInputDocument

    @Test(arguments: seeds)
    func `document conversions stay in bounds and keep order`(seed: UInt64) {
        var random = SeededGenerator(seed: seed)
        for _ in 0 ..< 2000 {
            let document = TerminalInputDocument(
                anchorLength: random.int(in: 0 ... 3),
                markedLength: random.int(in: 0 ... 64),
            )
            let offset = random.int(in: -16 ... 96)
            let position = document.position(ofMarkedOffset: offset)
            #expect((document.anchorLength ... document.length).contains(position), "seed \(seed)")

            let marked = document.markedOffset(of: random.int(in: -16 ... 96))
            #expect((0 ... document.markedLength).contains(marked), "seed \(seed)")

            let valid = random.int(in: 0 ... document.markedLength)
            #expect(document.markedOffset(of: document.position(ofMarkedOffset: valid)) == valid)

            let first = random.int(in: -16 ... 96)
            let second = random.int(in: -16 ... 96)
            #expect(
                document.markedOffset(of: min(first, second)) <= document.markedOffset(of: max(first, second)),
                "seed \(seed): markedOffset must not decrease",
            )

            let range = NSRange(location: random.int(in: -8 ... 80), length: random.int(in: 0 ... 80))
            let markedRange = document.markedRange(of: range)
            #expect(markedRange.location >= 0 && markedRange.length >= 0, "seed \(seed) range \(range)")
            #expect(NSMaxRange(markedRange) <= document.markedLength, "seed \(seed) range \(range)")
            if NSMaxRange(range) <= document.anchorLength {
                #expect(markedRange.length == 0, "seed \(seed): the anchor holds no text")
            }
        }
    }

    @Test(arguments: seeds)
    func `the whole document maps onto the whole marked text`(seed: UInt64) {
        var random = SeededGenerator(seed: seed)
        for _ in 0 ..< 500 {
            let document = TerminalInputDocument(
                anchorLength: random.int(in: 0 ... 3),
                markedLength: random.int(in: 0 ... 64),
            )
            let whole = document.markedRange(of: NSRange(location: 0, length: document.length))
            #expect(whole == NSRange(location: 0, length: document.markedLength))
        }
    }

    // MARK: - TerminalMarkedTextState

    /// Arbitrary selections, including ones that split a surrogate pair,
    /// checked against a UTF-16 model for length and selection.
    @Test(arguments: seeds)
    func `marked text edits agree with a utf-16 model under arbitrary selections`(seed: UInt64) {
        var random = SeededGenerator(seed: seed)
        var state = TerminalMarkedTextState()
        var model = MarkedTextModel()

        for step in 0 ..< 4000 {
            let context = "seed \(seed) step \(step)"
            switch random.int(in: 0 ... 9) {
            case 0 ... 3:
                let text = random.chance(0.1) ? (random.chance(0.5) ? nil : "") : random.string(from: Self.markedAlphabet, maxLength: 12)
                let length = text?.utf16.count ?? 0
                let range = NSRange(location: random.int(in: -4 ... length + 4), length: random.int(in: -2 ... length + 4))
                state.setMarkedText(text, selectedRange: range)
                model.set(text, range)
            case 4 ... 7:
                let hadText = state.hasMarkedText
                #expect(state.deleteBackward() == hadText, "\(context)")
                model.deleteBackward()
            case 8:
                state.clear()
                model = MarkedTextModel()
            default:
                let length = state.documentLength
                let range = NSRange(location: random.int(in: -2 ... length + 2), length: random.int(in: -1 ... length + 2))
                let read = state.text(in: range)
                // With nothing marked, any empty range reads as "".
                let inBounds = state.hasMarkedText
                    ? range.location >= 0 && range.length >= 0 && NSMaxRange(range) <= length
                    : range.length == 0
                #expect((read != nil) == inBounds, "\(context) range \(range)")
            }

            #expect(state.documentLength == model.units.count, "\(context)")
            #expect(state.hasMarkedText == !model.units.isEmpty, "\(context)")
            #expect(state.text != "", "\(context): empty text must normalize to nil")
            assertSelectionInvariants(state, context: context)
            if state.hasMarkedText {
                #expect(state.selectedRange == model.selection, "\(context)")
            }
        }
    }

    /// Selections an input method actually reports sit on scalar
    /// boundaries. Deleting backward from one must never leave half of a
    /// surrogate pair in the preedit.
    @Test(arguments: seeds)
    func `delete backward never splits a surrogate pair`(seed: UInt64) {
        var random = SeededGenerator(seed: seed)
        var state = TerminalMarkedTextState()

        for step in 0 ..< 3000 {
            let context = "seed \(seed) step \(step)"
            if !state.hasMarkedText || random.chance(0.25) {
                let text = random.string(from: Self.markedAlphabet, maxLength: 10)
                let boundaries = scalarBoundaries(text)
                let start = random.pick(boundaries)
                let end = random.chance(0.6) ? start : random.pick(boundaries.filter { $0 >= start })
                state.setMarkedText(text, selectedRange: NSRange(location: start, length: end - start))
            }
            _ = state.deleteBackward()

            let text = state.text ?? ""
            #expect(!text.unicodeScalars.contains("\u{FFFD}"), "\(context): \(text.debugDescription)")
            #expect(String(utf16CodeUnits: Array(text.utf16), count: text.utf16.count) == text, "\(context)")
            #expect(scalarBoundaries(text).contains(state.selectedRange.location), "\(context)")
            assertSelectionInvariants(state, context: context)
        }
    }

    private func assertSelectionInvariants(_ state: TerminalMarkedTextState, context: String) {
        let selection = state.selectedRange
        #expect(selection.location >= 0 && selection.length >= 0, "\(context)")
        #expect(NSMaxRange(selection) <= state.documentLength, "\(context)")
        #expect(state.text(in: selection) != nil, "\(context)")
        if state.hasMarkedText {
            #expect(state.markedRange == NSRange(location: 0, length: state.documentLength), "\(context)")
            #expect(state.currentSelectedRange == selection, "\(context)")
        } else {
            #expect(state.markedRange.location == NSNotFound, "\(context)")
            #expect(state.currentSelectedRange.location == NSNotFound, "\(context)")
            #expect(selection == NSRange(location: 0, length: 0), "\(context)")
        }
    }

    // MARK: - TerminalHardwareKeyRouter

    @Test
    func `every app kit keycode round trips through its ghostty key`() {
        for code in UInt16.min ... UInt16.max {
            let key = TerminalHardwareKeyRouter.ghosttyKey(forAppKitKeyCode: code)
            guard key != GHOSTTY_KEY_UNIDENTIFIED else { continue }
            #expect(code < 0x100, "AppKit keycodes are 8-bit; \(code) is not")
            let back = TerminalHardwareKeyRouter.appKitKeyCode(for: key)
            #expect(back < 0x100)
            #expect(TerminalHardwareKeyRouter.ghosttyKey(forAppKitKeyCode: UInt16(back)) == key, "keycode \(code)")
        }
    }

    @Test
    func `every uikit usage translates to a keycode for the same key`() {
        let overrides: Set<UInt16> = [0x53, 0x64, 0x75]
        for usage in UInt16.min ... UInt16.max {
            let key = TerminalHardwareKeyRouter.ghosttyKey(forUIKitUsage: usage)
            let code = TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: usage)
            if code == TerminalHardwareKeyRouter.unidentifiedAppKitKeyCode {
                #expect(TerminalHardwareKeyRouter.appKitKeyCode(for: key) == code, "usage \(usage)")
                continue
            }
            #expect(code < 0x100, "usage \(usage)")
            #expect(key != GHOSTTY_KEY_UNIDENTIFIED, "usage \(usage) has a keycode but no key")
            // The overrides send the Mac's own keycode for the physical key,
            // even one (ISO Section) that libghostty's table leaves out.
            guard !overrides.contains(usage) else { continue }
            let resolved = TerminalHardwareKeyRouter.ghosttyKey(forAppKitKeyCode: UInt16(code))
            #expect(resolved == key, "usage \(usage)")
        }
    }

    @Test
    func `every terminal key with a keycode resolves back to itself`() {
        for key in TerminalKey.allCases {
            let code = TerminalHardwareKeyRouter.appKitKeyCode(for: key.ghosttyKey)
            #expect(key.hasPlatformKeycode == (code != TerminalHardwareKeyRouter.unidentifiedAppKitKeyCode))
            guard key.hasPlatformKeycode else { continue }
            #expect(TerminalHardwareKeyRouter.ghosttyKey(forAppKitKeyCode: UInt16(code)) == key.ghosttyKey, "\(key)")
        }
    }

    // MARK: - TerminalShellEscape

    private static let shellAlphabet = [
        "a", "Z", "0", ".", "-", "_", "/", "~", "\\", " ", "(", ")", "[", "]",
        "{", "}", "<", ">", "\"", "'", "`", "!", "#", "$", "&", ";", "|", "*",
        "?", "\t", "\u{301}", "\u{200D}", "\u{E9}", "\u{4E2D}", "\u{1F600}",
        "\u{1F1FA}", "=", ":", "%", "^", "\n",
    ]

    private static let shellSensitive: Set<Unicode.Scalar> = [
        "\\", " ", "(", ")", "[", "]", "{", "}", "<", ">", "\"", "'", "`",
        "!", "#", "$", "&", ";", "|", "*", "?", "\t",
    ]

    /// A shell reading the escaped form back must recover the exact path,
    /// and must find every sensitive byte behind a backslash — including
    /// one a following combining mark folds into the same grapheme.
    @Test(arguments: seeds)
    func `shell escaping round trips and leaves no sensitive scalar bare`(seed: UInt64) {
        var random = SeededGenerator(seed: seed)
        for _ in 0 ..< 3000 {
            let path = random.string(from: Self.shellAlphabet, maxLength: 24)
            let escaped = TerminalShellEscape.escape(path)

            var unescaped = String.UnicodeScalarView()
            var pendingBackslash = false
            var bare: [Unicode.Scalar] = []
            for scalar in escaped.unicodeScalars {
                if pendingBackslash {
                    unescaped.append(scalar)
                    pendingBackslash = false
                } else if scalar == "\\" {
                    pendingBackslash = true
                } else {
                    if Self.shellSensitive.contains(scalar) {
                        bare.append(scalar)
                    }
                    unescaped.append(scalar)
                }
            }
            #expect(!pendingBackslash, "seed \(seed): \(escaped.debugDescription) ends in a lone backslash")
            #expect(bare.isEmpty, "seed \(seed): \(escaped.debugDescription) leaves \(bare) bare")
            #expect(String(unescaped) == path, "seed \(seed): \(path.debugDescription)")

            let sensitiveCount = path.unicodeScalars.filter { Self.shellSensitive.contains($0) }.count
            #expect(escaped.unicodeScalars.count == path.unicodeScalars.count + sensitiveCount)
        }
    }
}

/// The marked-text editing rules on raw UTF-16, the way UIKit and AppKit
/// count. Deleting backward from a caret removes the scalar before it — two
/// units for a surrogate pair.
private struct MarkedTextModel {
    var units: [UInt16] = []
    var selection = NSRange(location: 0, length: 0)

    mutating func set(_ text: String?, _ range: NSRange) {
        units = Array((text ?? "").utf16)
        let location = min(max(range.location, 0), units.count)
        let end = min(max(range.location + range.length, location), units.count)
        selection = NSRange(location: location, length: end - location)
    }

    mutating func deleteBackward() {
        guard !units.isEmpty else { return }
        if selection.length > 0 {
            units.removeSubrange(selection.location ..< NSMaxRange(selection))
            selection.length = 0
        } else if selection.location > 0 {
            var start = selection.location - 1
            if start > 0, UTF16.isTrailSurrogate(units[start]), UTF16.isLeadSurrogate(units[start - 1]) {
                start -= 1
            }
            units.removeSubrange(start ..< selection.location)
            selection.location = start
        }
        if units.isEmpty {
            selection = NSRange(location: 0, length: 0)
        }
    }
}

/// UTF-16 offsets that fall between scalars.
private func scalarBoundaries(_ text: String) -> [Int] {
    var offsets = [0]
    var offset = 0
    for scalar in text.unicodeScalars {
        offset += scalar.utf16.count
        offsets.append(offset)
    }
    return offsets
}
