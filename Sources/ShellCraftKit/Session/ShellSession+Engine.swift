import Foundation
import GhosttyTerminal

actor Engine {
    private enum EscapeState {
        case none
        case escape
        case csi(Data)
    }

    private let shell: ShellDefinition
    private weak var session: InMemoryTerminalSession?
    private var startedAt = Date()
    private var currentInput = ""
    private var cursorPosition = 0
    private var isTerminated = false
    private var pendingText = Data()
    private var escapeState = EscapeState.none
    private var ignoreNextLineFeed = false
    private var hasStarted = false
    private var commandHistory: [String] = []
    private var historyIndex = -1
    private var savedInput = ""
    private var pendingResizeRedrawTask: Task<Void, Never>?
    private var renderedInputRevision: UInt64 = 0
    private var renderedInputState = TerminalRenderedInputState(
        totalLineCount: 1,
        cursorLineOffset: 0,
        cursorColumn: 1
    )
    private var terminalSize = InMemoryTerminalViewport(
        columns: 80,
        rows: 20,
        widthPixels: 0,
        heightPixels: 0
    )

    init(shell: ShellDefinition, session: InMemoryTerminalSession) {
        self.shell = shell
        self.session = session
    }

    /// Consumes the session's events one at a time so writes are parsed in
    /// arrival order; the parser keeps state across writes (`escapeState`,
    /// `pendingText`), and one Task per write would race for the actor.
    func run(_ events: AsyncStream<ShellSessionEvent>) async {
        for await event in events {
            switch event {
            case .start:
                start()
            case let .write(data):
                handleOutbound(data)
            case let .resize(size):
                updateSize(size)
            }
        }
    }

    func start() {
        guard !hasStarted else {
            return
        }

        hasStarted = true
        isTerminated = false
        startedAt = Date()
        send("\u{1B}[2J\u{1B}[H")
        send(shell.welcomeMessage)
        sendPrompt()
    }

    func updateSize(_ size: InMemoryTerminalViewport) {
        let previous = terminalSize
        terminalSize = size

        shellDebugLog(
            .metrics,
            "shell resize cols=\(previous.columns)x\(previous.rows) -> \(size.columns)x\(size.rows) pixels=\(size.widthPixels)x\(size.heightPixels)"
        )

        guard hasStarted, !isTerminated else { return }
        guard previous != size else { return }

        shellDebugLog(
            .actions,
            "shell redraw after resize input=\(shellDebugDescribe(currentInput)) cursorPosition=\(cursorPosition)"
        )
        // ghostty reflows the soft-wrapped prompt+input block to the new
        // width before it reports the resize, so the cursor's row offset
        // inside the block is already the new-width one.
        renderedInputState = terminalRenderedInputState(
            promptDisplayWidth: shell.promptDisplayWidth,
            input: currentInput,
            cursorPosition: cursorPosition,
            terminalColumns: Int(size.columns)
        )
        redrawInputLine()

        pendingResizeRedrawTask?.cancel()
        let expectedRevision = renderedInputRevision
        pendingResizeRedrawTask = Task { [self] in
            try? await Task.sleep(nanoseconds: 75_000_000)
            guard !Task.isCancelled else { return }
            redrawInputLineIfViewportStable(
                size,
                expectedRevision: expectedRevision
            )
        }
    }

    func handleOutbound(_ data: Data) {
        guard !isTerminated else {
            return
        }

        for byte in data {
            handle(byte)
        }
        flushPendingText()
    }

    // MARK: - Byte Handling

    private func handle(_ byte: UInt8) {
        switch escapeState {
        case .escape:
            flushPendingText()
            if byte == 0x5B || byte == 0x4F {
                escapeState = .csi(Data())
            } else {
                escapeState = .none
                // Meta/Option often arrives as ESC followed by an ASCII byte
                // (for example ESC-b / ESC-f word motion on macOS).
                handleMeta(byte)
            }
            return

        case var .csi(buffer):
            if (0x40 ... 0x7E).contains(byte) {
                escapeState = .none
                handleCSI(buffer, finalByte: byte)
            } else if buffer.count >= 64 {
                // Cap the CSI parameter buffer to guard against a peer that
                // sends ESC[ followed by an unbounded stream of intermediate
                // bytes, which would otherwise grow memory until the process
                // is killed.
                escapeState = .none
            } else {
                buffer.append(byte)
                escapeState = .csi(buffer)
            }
            return

        case .none:
            break
        }

        if byte != 0x0A {
            ignoreNextLineFeed = false
        }

        switch byte {
        case 0x1B:
            flushPendingText()
            escapeState = .escape

        case 0x01:
            flushPendingText()
            moveCursorToStart()

        case 0x02:
            flushPendingText()
            moveCursorLeft()

        case 0x03:
            flushPendingText()
            moveCursorToRenderedInputEnd()
            currentInput.removeAll(keepingCapacity: true)
            cursorPosition = 0
            resetHistoryState()
            send("^C\r\n")
            sendPrompt()

        case 0x05:
            flushPendingText()
            moveCursorToEnd()

        case 0x06:
            flushPendingText()
            moveCursorRight()

        case 0x0C:
            flushPendingText()
            currentInput.removeAll(keepingCapacity: true)
            cursorPosition = 0
            resetHistoryState()
            send("\u{1B}[2J\u{1B}[H")
            sendPrompt()

        case 0x0B:
            flushPendingText()
            killToEndOfLine()

        case 0x15:
            flushPendingText()
            killLine()

        case 0x17:
            flushPendingText()
            deleteBackwardShellWord()

        case 0x08, 0x7F:
            flushPendingText()
            deleteBackward()

        case 0x0D:
            flushPendingText()
            ignoreNextLineFeed = true
            submitCurrentInput()

        case 0x0A:
            flushPendingText()
            if ignoreNextLineFeed {
                ignoreNextLineFeed = false
                return
            }

            submitCurrentInput()

        case 0x09:
            flushPendingText()
            // The demo shell does not implement completion, but it also cannot
            // keep a literal HT byte in the line buffer because redraw and
            // cursor math operate on visible cell widths. Expanding tab to the
            // next visual stop keeps the host-managed shell stable while still
            // giving the key an observable effect for input testing.
            insertText(
                terminalExpandedTabText(
                    promptDisplayWidth: shell.promptDisplayWidth,
                    input: currentInput,
                    cursorPosition: cursorPosition,
                    terminalColumns: Int(terminalSize.columns)
                )
            )

        default:
            guard byte >= 0x20 else {
                return
            }

            pendingText.append(byte)
        }
    }

    private func handleCSI(_ params: Data, finalByte: UInt8) {
        // CSI params carry modifier suffixes such as `1;3D` for Alt-Left, so
        // dispatch on the decoded editing action instead of `finalByte` alone.
        switch terminalCSIEditingAction(params: params, finalByte: finalByte) {
        case .historyUp:
            navigateHistory(direction: .up)

        case .historyDown:
            navigateHistory(direction: .down)

        case .moveCursorRight:
            moveCursorRight()

        case .moveCursorLeft:
            moveCursorLeft()

        case .moveCursorBackwardWord:
            moveCursorBackwardWord()

        case .moveCursorForwardWord:
            moveCursorForwardWord()

        case .moveCursorToStart:
            moveCursorToStart()

        case .moveCursorToEnd:
            moveCursorToEnd()

        case .deleteForward:
            deleteForward()

        case .deleteForwardWord:
            deleteForwardWord()

        case nil:
            break
        }
    }

    // MARK: - Cursor Movement

    private func moveCursorLeft() {
        guard cursorPosition > 0 else { return }
        cursorPosition -= 1
        redrawInputLine()
    }

    private func moveCursorRight() {
        guard cursorPosition < currentInput.count else { return }
        cursorPosition += 1
        redrawInputLine()
    }

    private func moveCursorToStart() {
        guard cursorPosition > 0 else {
            return
        }
        cursorPosition = 0
        redrawInputLine()
    }

    private func moveCursorToEnd() {
        guard cursorPosition < currentInput.count else {
            return
        }
        cursorPosition = currentInput.count
        redrawInputLine()
    }

    private func moveCursorBackwardWord() {
        let nextCursorPosition = terminalPreviousWordBoundary(
            in: currentInput,
            from: cursorPosition
        )
        guard nextCursorPosition != cursorPosition else { return }
        cursorPosition = nextCursorPosition
        redrawInputLine()
    }

    private func moveCursorForwardWord() {
        let nextCursorPosition = terminalNextWordBoundary(
            in: currentInput,
            from: cursorPosition
        )
        guard nextCursorPosition != cursorPosition else { return }
        cursorPosition = nextCursorPosition
        redrawInputLine()
    }

    // MARK: - Editing

    private func insertText(_ text: String) {
        let previousInput = currentInput
        let previousCursorPosition = cursorPosition
        let idx = currentInput.index(currentInput.startIndex, offsetBy: cursorPosition)
        currentInput.insert(contentsOf: text, at: idx)
        // A combining scalar typed on its own merges into the previous
        // Character, so count the graphemes now before the cursor rather
        // than adding `text.count`.
        cursorPosition = (String(previousInput.prefix(previousCursorPosition)) + text).count

        if applyIncrementalAppendIfPossible(
            insertedText: text,
            previousInput: previousInput,
            previousCursorPosition: previousCursorPosition
        ) {
            return
        }

        redrawInputLine()
    }

    private func deleteBackward() {
        guard cursorPosition > 0 else {
            return
        }

        let idx = currentInput.index(currentInput.startIndex, offsetBy: cursorPosition - 1)
        currentInput.remove(at: idx)
        cursorPosition -= 1
        redrawInputLine()
    }

    private func deleteBackwardWord() {
        let result = terminalDeleteBackwardWord(
            input: currentInput,
            cursorPosition: cursorPosition
        )
        guard result.cursorPosition != cursorPosition else { return }
        currentInput = result.input
        cursorPosition = result.cursorPosition
        redrawInputLine()
    }

    private func deleteBackwardShellWord() {
        let result = terminalDeleteBackwardShellWord(
            input: currentInput,
            cursorPosition: cursorPosition
        )
        guard result.cursorPosition != cursorPosition else { return }
        currentInput = result.input
        cursorPosition = result.cursorPosition
        redrawInputLine()
    }

    private func deleteForward() {
        guard cursorPosition < currentInput.count else {
            return
        }

        let idx = currentInput.index(currentInput.startIndex, offsetBy: cursorPosition)
        currentInput.remove(at: idx)
        redrawInputLine()
    }

    private func deleteForwardWord() {
        let result = terminalDeleteForwardWord(
            input: currentInput,
            cursorPosition: cursorPosition
        )
        guard result.input != currentInput else { return }
        currentInput = result.input
        cursorPosition = result.cursorPosition
        redrawInputLine()
    }

    private func killLine() {
        guard !currentInput.isEmpty else {
            return
        }

        currentInput.removeAll(keepingCapacity: true)
        cursorPosition = 0
        redrawInputLine()
    }

    private func killToEndOfLine() {
        guard cursorPosition < currentInput.count else { return }
        currentInput.removeSubrange(
            currentInput.index(currentInput.startIndex, offsetBy: cursorPosition) ..< currentInput.endIndex
        )
        redrawInputLine()
    }

    // MARK: - History

    private enum HistoryDirection {
        case up
        case down
    }

    private func navigateHistory(direction: HistoryDirection) {
        guard !commandHistory.isEmpty else {
            return
        }

        switch direction {
        case .up:
            if historyIndex < 0 {
                savedInput = currentInput
                historyIndex = commandHistory.count - 1
            } else if historyIndex > 0 {
                historyIndex -= 1
            } else {
                return
            }

        case .down:
            guard historyIndex >= 0 else {
                return
            }
            if historyIndex < commandHistory.count - 1 {
                historyIndex += 1
            } else {
                historyIndex = -1
                currentInput = savedInput
                cursorPosition = currentInput.count
                redrawInputLine()
                return
            }
        }

        currentInput = commandHistory[historyIndex]
        cursorPosition = currentInput.count
        redrawInputLine()
    }

    private func resetHistoryState() {
        historyIndex = -1
        savedInput = ""
    }

    // MARK: - Text Handling

    private func flushPendingText() {
        guard !pendingText.isEmpty else {
            return
        }

        let (text, leftover) = decodeUTF8Incrementally(pendingText)
        pendingText = leftover

        guard !text.isEmpty else {
            return
        }

        insertText(text)
    }

    private func submitCurrentInput() {
        moveCursorToRenderedInputEnd()
        send("\r\n")

        let command = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        currentInput.removeAll(keepingCapacity: true)
        cursorPosition = 0

        if !command.isEmpty {
            commandHistory.append(command)
        }
        resetHistoryState()

        switch shell.processCommand(
            command,
            username: NSUserName(),
            terminalSize: terminalSize
        ) {
        case let .output(output):
            if !output.isEmpty {
                send(output)
            }
            sendPrompt()

        case .clear:
            send("\u{1B}[2J\u{1B}[H")
            sendPrompt()

        case .exit:
            isTerminated = true
            send("logout\r\n")
            session?.finish(
                exitCode: 0,
                runtimeMilliseconds: elapsedMilliseconds
            )
        }
    }

    private func sendPrompt() {
        send(shell.prompt)
        renderedInputState = terminalRenderedInputState(
            promptDisplayWidth: shell.promptDisplayWidth,
            input: currentInput,
            cursorPosition: cursorPosition,
            terminalColumns: Int(terminalSize.columns)
        )
        renderedInputRevision &+= 1
    }

    private func redrawInputLine() {
        let nextState = terminalRenderedInputState(
            promptDisplayWidth: shell.promptDisplayWidth,
            input: currentInput,
            cursorPosition: cursorPosition,
            terminalColumns: Int(terminalSize.columns)
        )
        let renderedEndState = terminalRenderedInputState(
            promptDisplayWidth: shell.promptDisplayWidth,
            input: currentInput,
            cursorPosition: currentInput.count,
            terminalColumns: Int(terminalSize.columns)
        )

        shellDebugLog(
            .actions,
            "shell redraw promptWidth=\(shell.promptDisplayWidth) input=\(shellDebugDescribe(currentInput)) cursorPosition=\(cursorPosition) previousLines=\(renderedInputState.totalLineCount) nextLines=\(nextState.totalLineCount)"
        )

        moveCursorToRenderedInputStart(renderedInputState)
        clearRenderedBlock()
        send(shell.prompt)
        send(currentInput)
        moveCursor(
            from: renderedEndState,
            to: nextState
        )
        renderedInputState = nextState
        renderedInputRevision &+= 1
    }

    private func redrawInputLineIfViewportStable(
        _ expectedViewport: InMemoryTerminalViewport,
        expectedRevision: UInt64
    ) {
        guard hasStarted, !isTerminated else { return }
        guard terminalSize == expectedViewport else { return }
        guard renderedInputRevision == expectedRevision else {
            shellDebugLog(
                .actions,
                "shell redraw settle skipped: revision changed expected=\(expectedRevision) actual=\(renderedInputRevision)"
            )
            return
        }

        shellDebugLog(
            .actions,
            "shell redraw settle viewport=\(expectedViewport.columns)x\(expectedViewport.rows) pixels=\(expectedViewport.widthPixels)x\(expectedViewport.heightPixels)"
        )
        redrawInputLine()
    }

    private func applyIncrementalAppendIfPossible(
        insertedText: String,
        previousInput: String,
        previousCursorPosition: Int
    ) -> Bool {
        guard canIncrementallyAppendInput(
            previousInput: previousInput,
            previousCursorPosition: previousCursorPosition,
            insertedText: insertedText
        ) else {
            return false
        }

        let nextState = terminalRenderedInputState(
            promptDisplayWidth: shell.promptDisplayWidth,
            input: currentInput,
            cursorPosition: cursorPosition,
            terminalColumns: Int(terminalSize.columns)
        )

        shellDebugLog(
            .actions,
            "shell incremental append text=\(shellDebugDescribe(insertedText)) input=\(shellDebugDescribe(currentInput)) cursorPosition=\(cursorPosition)"
        )
        send(insertedText)
        renderedInputState = nextState
        renderedInputRevision &+= 1
        return true
    }

    private func moveCursorToRenderedInputEnd() {
        moveCursor(
            from: renderedInputState,
            to: terminalRenderedInputState(
                promptDisplayWidth: shell.promptDisplayWidth,
                input: currentInput,
                cursorPosition: currentInput.count,
                terminalColumns: Int(terminalSize.columns)
            )
        )
    }

    private func moveCursorToRenderedInputStart(
        _ state: TerminalRenderedInputState
    ) {
        send("\r")
        guard state.cursorLineOffset > 0 else { return }
        send("\u{1B}[\(state.cursorLineOffset)A\r")
    }

    private func clearRenderedBlock() {
        send("\u{1B}[J")
    }

    private func moveCursor(
        from current: TerminalRenderedInputState,
        to target: TerminalRenderedInputState
    ) {
        let rowDelta = current.cursorLineOffset - target.cursorLineOffset
        if rowDelta > 0 {
            send("\u{1B}[\(rowDelta)A")
        } else if rowDelta < 0 {
            send("\u{1B}[\(-rowDelta)B")
        }

        send("\u{1B}[\(target.cursorColumn)G")
    }

    private func send(_ string: String) {
        session?.receive(string)
    }

    private var elapsedMilliseconds: UInt64 {
        UInt64(max(0, Date().timeIntervalSince(startedAt) * 1000))
    }

    private func handleMeta(_ byte: UInt8) {
        switch terminalMetaEditingAction(for: byte) {
        case .moveBackwardWord:
            moveCursorBackwardWord()

        case .moveForwardWord:
            moveCursorForwardWord()

        case .deleteBackwardWord:
            deleteBackwardWord()

        case .deleteForwardWord:
            deleteForwardWord()

        case nil:
            break
        }
    }
}

private func shellDebugLog(
    _ category: TerminalDebugCategory,
    _ message: @autoclosure () -> String
) {
    guard TerminalDebugLog.isEnabled else { return }
    guard TerminalDebugLog.categories.contains(category) else { return }
    TerminalDebugLog.sink("[ShellCraftKit] \(message())")
}

private func shellDebugDescribe(_ string: String?) -> String {
    guard let string else { return "nil" }
    let truncated = String(string.prefix(96))
    let escaped = truncated
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\u{1B}", with: "\\e")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    let suffix = string.count > truncated.count ? "..." : ""
    return "\"\(escaped)\(suffix)\""
}
