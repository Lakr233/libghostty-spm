import Foundation
import GhosttyKit
@testable import GhosttyTerminal
@testable import ShellCraftKit
import Testing

struct ShellCraftKitTests {
    @Test
    func `styled prompt uses visible column width`() {
        let shell = ShellDefinition(
            prompt: "\u{1B}[38;5;110mcolor\u{1B}[0m > ",
            welcomeMessage: ""
        ) {}

        #expect(shell.promptDisplayWidth == 8)
    }

    @Test
    func `terminal display width counts wide characters`() {
        #expect("abc".terminalDisplayWidth == 3)
        #expect("你好".terminalDisplayWidth == 4)
        #expect("a你b好".terminalDisplayWidth == 6)
        #expect("\u{1B}[31m红色\u{1B}[0m".terminalDisplayWidth == 4)
    }

    @Test
    func `terminal display width treats wide emoji blocks as two cells`() {
        #expect("\u{1F680}".terminalDisplayWidth == 2)
        #expect("\u{1F7E2}".terminalDisplayWidth == 2)
        #expect("\u{1FA90}".terminalDisplayWidth == 2)
        #expect("\u{1F004}".terminalDisplayWidth == 2)
        #expect("\u{1F0CF}".terminalDisplayWidth == 2)
        #expect("\u{1F18E}".terminalDisplayWidth == 2)
        #expect("\u{1F191}".terminalDisplayWidth == 2)
        #expect("\u{1F201}".terminalDisplayWidth == 2)
        #expect("echo \u{1F680}".terminalDisplayWidth == 7)
    }

    @Test
    func `wrapped display width counts the spacer a wide glyph leaves at the margin`() {
        #expect("你".terminalWrappedDisplayWidth(after: 78, terminalColumns: 80) == 80)
        #expect("你".terminalWrappedDisplayWidth(after: 79, terminalColumns: 80) == 82)
        #expect("a".terminalWrappedDisplayWidth(after: 79, terminalColumns: 80) == 80)
        #expect("你好".terminalWrappedDisplayWidth(after: 0, terminalColumns: 3) == 5)
    }

    @Test
    func `rendered input state places the cursor past a wide glyph that wrapped`() {
        let input = String(repeating: "a", count: 61) + "你abc"

        let atEnd = terminalRenderedInputState(
            promptDisplayWidth: 18,
            input: input,
            cursorPosition: input.count,
            terminalColumns: 80
        )
        #expect(atEnd.totalLineCount == 2)
        #expect(atEnd.cursorLineOffset == 1)
        #expect(atEnd.cursorColumn == 6)

        let afterWide = terminalRenderedInputState(
            promptDisplayWidth: 18,
            input: input,
            cursorPosition: 62,
            terminalColumns: 80
        )
        #expect(afterWide.cursorLineOffset == 1)
        #expect(afterWide.cursorColumn == 3)

        let beforeWide = terminalRenderedInputState(
            promptDisplayWidth: 18,
            input: input,
            cursorPosition: 61,
            terminalColumns: 80
        )
        #expect(beforeWide.cursorLineOffset == 0)
        #expect(beforeWide.cursorColumn == 80)

        let straddling = terminalRenderedInputState(
            promptDisplayWidth: 0,
            input: String(repeating: "a", count: 19) + "你" + String(repeating: "a", count: 19),
            cursorPosition: 0,
            terminalColumns: 20
        )
        #expect(straddling.totalLineCount == 3)
    }

    @Test
    func `cursor column uses display width instead of character count`() {
        #expect(
            terminalCursorColumn(
                promptDisplayWidth: 8,
                input: "测试",
                cursorPosition: 2
            ) == 13
        )

        #expect(
            terminalCursorColumn(
                promptDisplayWidth: 8,
                input: "a测b",
                cursorPosition: 2
            ) == 12
        )

        #expect(
            terminalCursorColumn(
                promptDisplayWidth: 8,
                input: "你好吗",
                cursorPosition: 1
            ) == 11
        )
    }

    @Test
    func `rendered input state tracks wrapped lines and cursor placement`() {
        let state = terminalRenderedInputState(
            promptDisplayWidth: 18,
            input: "hello world",
            cursorPosition: 11,
            terminalColumns: 20
        )

        #expect(state.totalLineCount == 2)
        #expect(state.cursorLineOffset == 1)
        #expect(state.cursorColumn == 10)
    }

    @Test
    func `rendered input state handles prompt only wrapping`() {
        let state = terminalRenderedInputState(
            promptDisplayWidth: 18,
            input: "",
            cursorPosition: 0,
            terminalColumns: 10
        )

        #expect(state.totalLineCount == 2)
        #expect(state.cursorLineOffset == 1)
        #expect(state.cursorColumn == 9)
    }

    @Test
    func `wrapped terminal line count handles exact boundary`() {
        #expect(wrappedTerminalLineCount(displayWidth: 20, terminalColumns: 20) == 1)
        #expect(wrappedTerminalLineCount(displayWidth: 21, terminalColumns: 20) == 2)
    }

    @Test
    func `rendered input state keeps cursor on boundary without trailing content`() {
        let state = terminalRenderedInputState(
            promptDisplayWidth: 18,
            input: "ab",
            cursorPosition: 2,
            terminalColumns: 20
        )

        #expect(state.totalLineCount == 1)
        #expect(state.cursorLineOffset == 0)
        #expect(state.cursorColumn == 20)
    }

    @Test
    func `rendered input state wraps boundary cursor when trailing content exists`() {
        let state = terminalRenderedInputState(
            promptDisplayWidth: 18,
            input: "abc",
            cursorPosition: 2,
            terminalColumns: 20
        )

        #expect(state.totalLineCount == 2)
        #expect(state.cursorLineOffset == 1)
        #expect(state.cursorColumn == 1)
    }

    @Test
    func `incremental append is allowed for tail insertion`() {
        #expect(
            canIncrementallyAppendInput(
                previousInput: "hello",
                previousCursorPosition: 5,
                insertedText: " world"
            )
        )
        #expect(
            canIncrementallyAppendInput(
                previousInput: "ni",
                previousCursorPosition: 2,
                insertedText: "你好"
            )
        )
    }

    @Test
    func `incremental append falls back for mid line or control input`() {
        #expect(
            !canIncrementallyAppendInput(
                previousInput: "hello",
                previousCursorPosition: 2,
                insertedText: "X"
            )
        )
        #expect(
            !canIncrementallyAppendInput(
                previousInput: "hello",
                previousCursorPosition: 5,
                insertedText: "\t"
            )
        )
    }

    @Test
    func `tab expansion uses visible cursor column`() {
        #expect(
            terminalExpandedTabText(
                promptDisplayWidth: 2,
                input: "abc",
                cursorPosition: 3,
                terminalColumns: 80
            ) == "   "
        )
        #expect(
            terminalExpandedTabText(
                promptDisplayWidth: 7,
                input: "",
                cursorPosition: 0,
                terminalColumns: 80
            ) == " "
        )
    }

    @Test
    func `tab expansion respects wrapped cursor column`() {
        #expect(
            terminalExpandedTabText(
                promptDisplayWidth: 18,
                input: "ab",
                cursorPosition: 2,
                terminalColumns: 20
            ) == String(repeating: " ", count: 5)
        )
    }

    @Test
    func `meta editing action recognizes word sequences`() {
        #expect(terminalMetaEditingAction(for: 0x7F) == .deleteBackwardWord)
        #expect(terminalMetaEditingAction(for: 0x08) == .deleteBackwardWord)
        #expect(terminalMetaEditingAction(for: 0x62) == .moveBackwardWord)
        #expect(terminalMetaEditingAction(for: 0x66) == .moveForwardWord)
        #expect(terminalMetaEditingAction(for: 0x64) == .deleteForwardWord)
        #expect(terminalMetaEditingAction(for: 0x42) == nil)
        #expect(terminalMetaEditingAction(for: 0x78) == nil)
    }

    @Test
    func `csi editing action recognizes modified arrow word sequences`() {
        #expect(
            terminalCSIEditingAction(params: Data("1;3".utf8), finalByte: 0x44)
                == .moveCursorBackwardWord
        )
        #expect(
            terminalCSIEditingAction(params: Data("1;3".utf8), finalByte: 0x43)
                == .moveCursorForwardWord
        )
        #expect(
            terminalCSIEditingAction(params: Data(), finalByte: 0x44)
                == .moveCursorLeft
        )
        #expect(
            terminalCSIEditingAction(params: Data(), finalByte: 0x43)
                == .moveCursorRight
        )
        #expect(
            terminalCSIEditingAction(params: Data("3".utf8), finalByte: 0x7E)
                == .deleteForward
        )
        #expect(
            terminalCSIEditingAction(params: Data("1;4".utf8), finalByte: 0x44)
                == .moveCursorBackwardWord
        )
        #expect(
            terminalCSIEditingAction(params: Data("3;3".utf8), finalByte: 0x7E)
                == .deleteForwardWord
        )
    }

    @Test
    func `csi modifier detection matches alt suffix`() {
        #expect(terminalCSIHasAltModifier(Data("1;3".utf8)))
        #expect(terminalCSIHasAltModifier(Data("1;4".utf8)))
        #expect(!terminalCSIHasAltModifier(Data("1;5".utf8)))
        #expect(!terminalCSIHasAltModifier(Data("3".utf8)))
        #expect(!terminalCSIHasAltModifier(Data()))
    }

    @Test
    func `word boundaries treat punctuation as separators for meta motion`() {
        #expect(terminalPreviousWordBoundary(in: "alpha beta", from: 10) == 6)
        #expect(terminalPreviousWordBoundary(in: "alpha beta  ", from: 12) == 6)
        #expect(terminalNextWordBoundary(in: "alpha beta", from: 0) == 5)
        #expect(terminalNextWordBoundary(in: "alpha   beta", from: 5) == 12)
        #expect(terminalPreviousWordBoundary(in: "foo-bar", from: 7) == 4)
        #expect(terminalNextWordBoundary(in: "foo-bar", from: 0) == 3)
        #expect(terminalPreviousWordBoundary(in: "héllo wörld", from: 11) == 6)
    }

    @Test
    func `shell word boundaries remain whitespace delimited for control W`() {
        #expect(terminalPreviousShellWordBoundary(in: "foo-bar baz", from: 11) == 8)
        #expect(terminalPreviousShellWordBoundary(in: "alpha beta  ", from: 12) == 6)
        #expect(terminalNextShellWordBoundary(in: "alpha   beta", from: 5) == 12)
    }

    @Test
    func `delete backward word removes previous word and trailing spaces`() {
        let result = terminalDeleteBackwardWord(
            input: "alpha beta  ",
            cursorPosition: 12
        )

        #expect(result.input == "alpha ")
        #expect(result.cursorPosition == 6)
    }

    @Test
    func `delete forward word removes next word and leading spaces`() {
        let result = terminalDeleteForwardWord(
            input: "alpha   beta gamma",
            cursorPosition: 5
        )

        #expect(result.input == "alpha gamma")
        #expect(result.cursorPosition == 5)
    }

    @Test
    func `delete backward shell word removes previous whitespace delimited token`() {
        let result = terminalDeleteBackwardShellWord(
            input: "foo-bar baz  ",
            cursorPosition: 13
        )

        #expect(result.input == "foo-bar ")
        #expect(result.cursorPosition == 8)
    }

    @Test
    func `user defined help command replaces the built-in listing`() {
        let viewport = InMemoryTerminalViewport(columns: 80, rows: 24)
        let shell = ShellDefinition(prompt: "$ ", welcomeMessage: "") {
            ShellCommand("help", summary: "Custom") { _ in .output("custom\r\n") }
        }

        guard case let .output(custom) = shell.processCommand(
            "help",
            username: "tester",
            terminalSize: viewport
        ) else {
            Issue.record("expected the user's help command to run")
            return
        }
        #expect(custom == "custom\r\n")

        let builtIn = ShellDefinition(prompt: "$ ", welcomeMessage: "") {
            ShellCommand("echo", summary: "Echo") { _ in .output("") }
        }
        guard case let .output(listing) = builtIn.processCommand(
            "help",
            username: "tester",
            terminalSize: viewport
        ) else {
            Issue.record("expected the built-in help listing")
            return
        }
        let helpLines = listing.components(separatedBy: "\n").filter { $0.hasPrefix("  help") }
        #expect(helpLines.count == 1)
        #expect(listing.contains("Show this help message"))
        #expect(listing.contains("echo"))
    }

    @Test
    func `sandbox shell supports exit and styled fallback`() {
        let viewport = InMemoryTerminalViewport(
            columns: 80,
            rows: 24,
            widthPixels: 0,
            heightPixels: 0
        )

        switch defaultSandboxShell.processCommand(
            "exit",
            username: "tester",
            terminalSize: viewport
        ) {
        case .exit:
            break

        default:
            Issue.record("expected sandbox shell exit command to terminate the session")
        }

        if case let .output(message) = defaultSandboxShell.processCommand(
            "missing-command",
            username: "tester",
            terminalSize: viewport
        ) {
            #expect(message.contains("\u{1B}["))
            #expect(message.contains("missing-command"))
        } else {
            Issue.record("expected fallback command result to produce output")
        }
    }

    // MARK: - decodeUTF8Incrementally

    @Test
    func `utf 8 incremental decodes complete ASCII`() {
        let (text, leftover) = decodeUTF8Incrementally(Data("hello".utf8))
        #expect(text == "hello")
        #expect(leftover.isEmpty)
    }

    @Test
    func `utf 8 incremental decodes complete chinese`() {
        let (text, leftover) = decodeUTF8Incrementally(Data("你好".utf8))
        #expect(text == "你好")
        #expect(leftover.isEmpty)
    }

    @Test
    func `utf 8 incremental retains incomplete three byte sequence`() {
        // "你" is E4 BD A0 — send only first 2 bytes
        let partial = Data([0xE4, 0xBD])
        let (text1, leftover1) = decodeUTF8Incrementally(partial)
        #expect(text1 == "")
        #expect(leftover1 == partial)

        // Now complete the sequence
        let full = leftover1 + Data([0xA0])
        let (text2, leftover2) = decodeUTF8Incrementally(full)
        #expect(text2 == "你")
        #expect(leftover2.isEmpty)
    }

    @Test
    func `utf 8 incremental retains incomplete four byte sequence`() {
        // 😀 is F0 9F 98 80 — send only first 3 bytes
        let partial = Data([0xF0, 0x9F, 0x98])
        let (text1, leftover1) = decodeUTF8Incrementally(partial)
        #expect(text1 == "")
        #expect(leftover1 == partial)

        let full = leftover1 + Data([0x80])
        let (text2, leftover2) = decodeUTF8Incrementally(full)
        #expect(text2 == "😀")
        #expect(leftover2.isEmpty)
    }

    @Test
    func `utf 8 incremental skips illegal lead byte FF`() {
        let (text, leftover) = decodeUTF8Incrementally(Data([0xFF]))
        #expect(text == "")
        #expect(leftover.isEmpty)
    }

    @Test
    func `utf 8 incremental skips overlong lead C 0 C 1`() {
        // 0xC0 and 0xC1 are overlong, should be skipped
        let input = Data([0xC0, 0x41, 0xC1, 0x42])
        let (text, leftover) = decodeUTF8Incrementally(input)
        #expect(text == "AB")
        #expect(leftover.isEmpty)
    }

    @Test
    func `utf 8 incremental skips lead F 5 plus`() {
        let input = Data([0xF5, 0x41, 0xF6, 0x42, 0xF7, 0x43])
        let (text, leftover) = decodeUTF8Incrementally(input)
        #expect(text == "ABC")
        #expect(leftover.isEmpty)
    }

    @Test
    func `utf 8 incremental skips only lead byte on invalid combination`() {
        // 0xE4 expects 2 continuation bytes, but next bytes are ASCII
        let input = Data([0xE4, 0x41, 0x42])
        let (text, leftover) = decodeUTF8Incrementally(input)
        #expect(text == "AB")
        #expect(leftover.isEmpty)
    }

    @Test
    func `utf 8 incremental preserves valid text after illegal byte`() {
        let input = Data([0xFF, 0x68, 0x65, 0x6C, 0x6C, 0x6F]) // 0xFF + "hello"
        let (text, leftover) = decodeUTF8Incrementally(input)
        #expect(text == "hello")
        #expect(leftover.isEmpty)
    }

    @Test
    func `utf 8 incremental handles empty data`() {
        let (text, leftover) = decodeUTF8Incrementally(Data())
        #expect(text == "")
        #expect(leftover.isEmpty)
    }

    @Test
    func `utf 8 incremental handles mixed valid and incomplete`() {
        // "ab" + incomplete 3-byte lead
        let input = Data([0x61, 0x62, 0xE4, 0xBD])
        let (text, leftover) = decodeUTF8Incrementally(input)
        #expect(text == "ab")
        #expect(leftover == Data([0xE4, 0xBD]))
    }

    @Test
    func `utf 8 incremental decomposed unicode`() {
        // e (0x65) + combining acute accent U+0301 (0xCC 0x81)
        let input = Data([0x65, 0xCC, 0x81])
        let (text, leftover) = decodeUTF8Incrementally(input)
        #expect(text == "e\u{0301}")
        #expect(leftover.isEmpty)
    }

    @Test
    func `utf 8 incremental skips lead with non continuation tail`() {
        // 0xE4 is 3-byte lead, but 0x41 is ASCII — not a valid continuation
        let input = Data([0xE4, 0x41])
        let (text, leftover) = decodeUTF8Incrementally(input)
        #expect(text == "A")
        #expect(leftover.isEmpty)
    }

    @Test
    func `utf 8 incremental skips four byte lead with invalid tail`() {
        // 0xF0 is 4-byte lead, but 0x41/0x42 are ASCII
        let input = Data([0xF0, 0x41, 0x42])
        let (text, leftover) = decodeUTF8Incrementally(input)
        #expect(text == "AB")
        #expect(leftover.isEmpty)
    }

    // MARK: - Engine

    @Test
    func `engine keeps the cursor on a grapheme boundary when a combining mark merges`() async {
        let shell = await EngineHarness()
        await shell.start()

        await shell.feed("a")
        await shell.feed("\u{0E01}")
        await shell.feed("\u{0E31}")
        _ = shell.drain()

        await shell.feed([0x7F])
        #expect(shell.drain().contains("$ a\u{1B}[4G"))

        await shell.feed("\r")
        #expect(shell.drain().contains("a: command not found"))
    }

    @Test
    func `engine submits a line feed that does not follow a carriage return`() async {
        let shell = await EngineHarness()
        await shell.start()

        await shell.feed("\r")
        _ = shell.drain()

        await shell.feed("whoami\n")
        #expect(shell.drain().components(separatedBy: "tester").count == 2)

        await shell.feed("whoami\r\n")
        #expect(shell.drain().components(separatedBy: "tester").count == 2)
    }

    @Test
    func `engine redraws after a resize from the reflowed cursor row`() async {
        let shell = await EngineHarness(columns: 20)
        await shell.start()
        let input = String(repeating: "a", count: 30)
        await shell.feed(input)
        _ = shell.drain()

        await shell.resize(columns: 40)
        #expect(shell.drain().hasPrefix("\r\u{1B}[J$ \(input)\u{1B}[33G"))

        await shell.resize(columns: 20)
        #expect(shell.drain().hasPrefix("\r\u{1B}[1A\r\u{1B}[J$ \(input)\u{1B}[13G"))
    }

    @Test
    func `engine moves to the end of a wrapped input before submitting`() async {
        let shell = await EngineHarness(columns: 20)
        await shell.start()
        let input = String(repeating: "a", count: 30)
        await shell.feed(input)
        await shell.feed([0x01])
        _ = shell.drain()

        await shell.feed("\r")
        #expect(shell.drain().hasPrefix("\u{1B}[1B\u{1B}[13G\r\n\(input): command not found\r\n$ "))

        await shell.feed(input)
        await shell.feed([0x01])
        _ = shell.drain()

        await shell.feed([0x03])
        #expect(shell.drain().hasPrefix("\u{1B}[1B\u{1B}[13G^C\r\n$ "))
    }

    @Test
    func `engine handles session events in arrival order`() async {
        let shell = await EngineHarness()
        let (stream, events) = AsyncStream.makeStream(of: ShellSessionEvent.self)
        events.yield(.start)
        for _ in 0 ..< 50 {
            for byte in "whoami\r".utf8 {
                events.yield(.write(Data([byte])))
            }
        }
        events.finish()

        await shell.engine.run(stream)
        #expect(shell.drain().components(separatedBy: "tester").count == 51)
    }

    @Test
    func `shell session releases its terminal session when dropped`() {
        weak var terminalSession: InMemoryTerminalSession?
        do {
            let session = ShellSession(shell: defaultSandboxShell)
            terminalSession = session.terminalSession
            withExtendedLifetime(session) {
                #expect(terminalSession != nil)
            }
        }
        #expect(terminalSession == nil)
    }
}

private struct EngineHarness {
    let engine: Engine
    private let session: InMemoryTerminalSession
    private let output: CapturedOutput

    init(columns: UInt16 = 80) async {
        let output = CapturedOutput()
        let bridge = SessionBridge()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, data in output.append(data) },
            processExit: { _, _, _ in }
        )
        session.setSurface(UnsafeMutableRawPointer(bitPattern: 0x10)!)
        bridge.session = session
        let shell = ShellDefinition(prompt: "$ ", welcomeMessage: "") {
            ShellCommand("whoami", summary: "Show current user") { _ in .output("tester\r\n") }
        }
        let engine = Engine(shell: shell, sessionBridge: bridge)
        await engine.updateSize(InMemoryTerminalViewport(columns: columns, rows: 24))

        self.engine = engine
        self.session = session
        self.output = output
    }

    func start() async {
        await engine.start()
        _ = drain()
    }

    func feed(_ string: String) async {
        await engine.handleOutbound(Data(string.utf8))
    }

    func feed(_ bytes: [UInt8]) async {
        await engine.handleOutbound(Data(bytes))
    }

    func resize(columns: UInt16) async {
        await engine.updateSize(InMemoryTerminalViewport(columns: columns, rows: 24))
    }

    func drain() -> String {
        session.waitForPendingOutput()
        return output.take()
    }
}

private final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func take() -> String {
        lock.lock()
        defer {
            data.removeAll()
            lock.unlock()
        }
        return String(decoding: data, as: UTF8.self)
    }
}
