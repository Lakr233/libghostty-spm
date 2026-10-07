import Foundation
@testable import GhosttyTerminal
@testable import ShellCraftKit
import Testing

/// Seeded fuzzing of ShellCraftKit's line editing: word boundaries and word
/// deletes against a `[Character]` model, the CSI/meta decoders against
/// arbitrary bytes, incremental UTF-8 decoding against arbitrary splits,
/// and the engine itself against random editing keystrokes.
struct ShellCraftEditingFuzzTests {
    private static let seeds: [UInt64] = [3, 11, 99, 2026, 0xC0FFEE]

    /// Graphemes that stay whole when their neighbours are removed, so a
    /// `[Character]` model of the line is exact.
    private static let lineAlphabet = [
        "a", "Z", "0", "9", "_", " ", " ", "\t", "-", "/", ".", "'", "\"",
        "e\u{301}", "\u{E9}", "\u{4E16}", "\u{754C}", "\u{3042}", "\u{0E01}\u{0E31}",
        "\u{1F600}", "\u{1F44D}\u{1F3FD}", "\u{1F468}\u{200D}\u{1F469}", "\u{00A0}", "\u{3000}",
    ]

    // MARK: - Word boundaries

    @Test(arguments: seeds)
    func `word boundaries bracket the cursor and land on word edges`(seed: UInt64) {
        var random = SeededGenerator(seed: seed)
        for _ in 0 ..< 3000 {
            let input = random.string(from: Self.lineAlphabet, maxLength: 20)
            let characters = Array(input)
            let cursor = random.int(in: -3 ... characters.count + 3)
            let clamped = min(max(cursor, 0), characters.count)
            let context = "seed \(seed): \(input.debugDescription) @\(cursor)"

            let previous = terminalPreviousWordBoundary(in: input, from: cursor)
            let next = terminalNextWordBoundary(in: input, from: cursor)
            let previousShell = terminalPreviousShellWordBoundary(in: input, from: cursor)
            #expect((0 ... clamped).contains(previous), "\(context)")
            #expect((clamped ... characters.count).contains(next), "\(context)")
            #expect((0 ... clamped).contains(previousShell), "\(context)")

            // A boundary is a fixed point one step on: stepping from it
            // again moves to the next word, never back past the cursor.
            #expect(terminalPreviousWordBoundary(in: input, from: previous) <= previous, "\(context)")
            #expect(terminalNextWordBoundary(in: input, from: next) >= next, "\(context)")

            // The previous word boundary starts a word: nothing word-like
            // sits right before it.
            if previous > 0, previous < clamped {
                #expect(!isWord(characters[previous - 1]), "\(context)")
                #expect(isWord(characters[previous]), "\(context)")
            }
            if previousShell > 0, previousShell < clamped {
                #expect(isWhitespace(characters[previousShell - 1]), "\(context)")
            }
            if next < characters.count, next > clamped {
                #expect(!isWord(characters[next]), "\(context)")
                #expect(isWord(characters[next - 1]), "\(context)")
            }
        }
    }

    @Test(arguments: seeds)
    func `word deletes remove exactly the span to the boundary`(seed: UInt64) {
        var random = SeededGenerator(seed: seed)
        for _ in 0 ..< 3000 {
            let input = random.string(from: Self.lineAlphabet, maxLength: 20)
            let characters = Array(input)
            let cursor = random.int(in: -3 ... characters.count + 3)
            let clamped = min(max(cursor, 0), characters.count)
            let context = "seed \(seed): \(input.debugDescription) @\(cursor)"

            let backward = terminalDeleteBackwardWord(input: input, cursorPosition: cursor)
            let previous = terminalPreviousWordBoundary(in: input, from: clamped)
            #expect(backward.cursorPosition == previous, "\(context)")
            #expect(Array(backward.input) == Array(characters[..<previous] + characters[clamped...]), "\(context)")

            let shell = terminalDeleteBackwardShellWord(input: input, cursorPosition: cursor)
            let previousShell = terminalPreviousShellWordBoundary(in: input, from: clamped)
            #expect(shell.cursorPosition == previousShell, "\(context)")
            #expect(Array(shell.input) == Array(characters[..<previousShell] + characters[clamped...]), "\(context)")

            let forward = terminalDeleteForwardWord(input: input, cursorPosition: cursor)
            let next = terminalNextWordBoundary(in: input, from: clamped)
            #expect(forward.cursorPosition == clamped, "\(context)")
            #expect(Array(forward.input) == Array(characters[..<clamped] + characters[next...]), "\(context)")
        }
    }

    // MARK: - Escape decoding

    @Test(arguments: seeds)
    func `csi and meta decoding accept any bytes`(seed: UInt64) {
        var random = SeededGenerator(seed: seed)
        let paramBytes: [UInt8] = Array("0123456789;:".utf8) + [0x00, 0x20, 0x3F, 0x80, 0xFF]
        for _ in 0 ..< 5000 {
            let params = Data((0 ..< random.int(in: 0 ... 12)).map { _ in random.pick(paramBytes) })
            let finalByte = UInt8(random.int(in: 0x40 ... 0x7E))
            let action = terminalCSIEditingAction(params: params, finalByte: finalByte)
            switch finalByte {
            case 0x41: #expect(action == .historyUp)
            case 0x42: #expect(action == .historyDown)
            case 0x43: #expect(action == .moveCursorRight || action == .moveCursorForwardWord)
            case 0x44: #expect(action == .moveCursorLeft || action == .moveCursorBackwardWord)
            case 0x46: #expect(action == .moveCursorToEnd)
            case 0x48: #expect(action == .moveCursorToStart)
            case 0x7E: #expect(action == nil || action == .deleteForward || action == .deleteForwardWord)
            default: #expect(action == nil)
            }

            _ = terminalCSIHasAltModifier(params)
            _ = terminalMetaEditingAction(for: UInt8(random.int(in: 0 ... 255)))
        }
    }

    @Test
    func `alt modifier decoding matches the xterm bitmask for every modifier value`() {
        for modifier in 1 ... 16 {
            let alt = (modifier - 1) & 0x2 != 0
            #expect(terminalCSIHasAltModifier(Data("1;\(modifier)".utf8)) == alt)
            let left = terminalCSIEditingAction(params: Data("1;\(modifier)".utf8), finalByte: 0x44)
            #expect(left == (alt ? .moveCursorBackwardWord : .moveCursorLeft))
            let delete = terminalCSIEditingAction(params: Data("3;\(modifier)".utf8), finalByte: 0x7E)
            #expect(delete == (alt ? .deleteForwardWord : .deleteForward))
        }
    }

    // MARK: - UTF-8 decoding

    /// Valid UTF-8 cut anywhere decodes, chunk by chunk with the leftover
    /// carried forward, to the original text.
    @Test(arguments: seeds)
    func `incremental utf-8 decoding is split-invariant`(seed: UInt64) {
        var random = SeededGenerator(seed: seed)
        for _ in 0 ..< 1500 {
            let text = random.string(from: Self.lineAlphabet, maxLength: 30)
            let bytes = Array(text.utf8)
            var decoded = ""
            var pending = Data()
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + random.int(in: 1 ... 5), bytes.count)
                pending.append(contentsOf: bytes[offset ..< end])
                let (chunk, leftover) = decodeUTF8Incrementally(pending)
                #expect(leftover.count < 4, "seed \(seed): a leftover is at most an incomplete scalar")
                decoded += chunk
                pending = leftover
                offset = end
            }
            #expect(pending.isEmpty, "seed \(seed)")
            #expect(decoded == text, "seed \(seed): \(text.debugDescription)")
        }
    }

    /// Arbitrary bytes: decoding never traps, keeps at most an incomplete
    /// sequence back, and that tail can always still become valid.
    @Test(arguments: seeds)
    func `incremental utf-8 decoding survives arbitrary bytes`(seed: UInt64) {
        var random = SeededGenerator(seed: seed)
        for _ in 0 ..< 3000 {
            let bytes = Data((0 ..< random.int(in: 0 ... 24)).map { _ in UInt8(random.int(in: 0 ... 255)) })
            let (decoded, leftover) = decodeUTF8Incrementally(bytes)
            #expect(leftover.count < 4)
            #expect(!decoded.unicodeScalars.contains("\u{FFFD}") || bytes.count(of: "\u{FFFD}") > 0)
            if let lead = leftover.first {
                #expect((0xC2 ... 0xF4).contains(lead), "seed \(seed): leftover \(Array(leftover))")
                #expect(leftover.dropFirst().allSatisfy { $0 & 0xC0 == 0x80 })
            }
        }
    }

    // MARK: - Engine

    /// Random editing keystrokes — arrows, word motion, kills, history,
    /// Tab, and text with combining marks, ZWJ emoji and lone regional
    /// indicators that merge with their neighbours — in random write sizes.
    /// The engine must never trap on a cursor past its line, and must still
    /// run the next command it is given.
    @Test(.timeLimit(.minutes(1)), arguments: seeds)
    func `the engine survives random editing and still runs a command`(seed: UInt64) async {
        var random = SeededGenerator(seed: seed)
        let rig = EditingFuzzRig()
        await rig.engine.start()
        _ = rig.drain()

        let keys: [String] = [
            "\u{1B}[A", "\u{1B}[B", "\u{1B}[C", "\u{1B}[D", "\u{1B}[H", "\u{1B}[F",
            "\u{1B}[1;3C", "\u{1B}[1;3D", "\u{1B}[3~", "\u{1B}[3;3~", "\u{1B}OA",
            "\u{1B}b", "\u{1B}f", "\u{1B}d", "\u{1B}\u{7F}", "\u{01}", "\u{02}",
            "\u{05}", "\u{06}", "\u{0B}", "\u{15}", "\u{17}", "\u{7F}", "\u{08}",
            "\t", "\u{1B}", "\u{1B}[", "\u{1B}[99;99;99", "\r", "\u{03}",
        ]
        let text = Self.lineAlphabet + ["\u{301}", "\u{200D}", "\u{1F1FA}", "\u{1F1F8}", "\u{1100}", "\u{1161}", "echo "]

        for _ in 0 ..< 600 {
            var write = ""
            for _ in 0 ..< random.int(in: 1 ... 4) {
                write += random.chance(0.55) ? random.pick(keys) : random.pick(text)
            }
            await rig.engine.handleOutbound(Data(write.utf8))
        }
        _ = rig.drain()

        // `@` ends a CSI the fuzz left open (it is a final byte) and is
        // otherwise typed; Ctrl-U then clears the line either way.
        await rig.engine.handleOutbound(Data("@\u{15}echo SENTINEL-\(seed)\r".utf8))
        let output = rig.drain()
        #expect(output.hasSuffix("\r\nSENTINEL-\(seed)\r\n$ "), "seed \(seed): \(output.suffix(80).debugDescription)")
    }
}

private func isWord(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy {
        $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "_"
    }
}

private func isWhitespace(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy(\.properties.isWhitespace)
}

/// A ShellCraftKit engine against a stand-in surface that records bytes.
private final class EditingFuzzRig {
    let session: InMemoryTerminalSession
    let engine: Engine
    private let output = LockedBytes()

    init() {
        let output = output
        session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, data in output.append(data) },
            processExit: { _, _, _ in },
        )
        session.setSurface(UnsafeMutableRawPointer(bitPattern: 0x20)!)
        let shell = ShellDefinition(prompt: "$ ", welcomeMessage: "") {
            ShellCommand("echo", summary: "Echo text back") { .output($0.arguments + "\r\n") }
        }
        engine = Engine(shell: shell, session: session)
    }

    func drain() -> String {
        session.waitForPendingOutput()
        let data = output.bytes
        output.removeAll()
        return String(decoding: data, as: UTF8.self)
    }
}
