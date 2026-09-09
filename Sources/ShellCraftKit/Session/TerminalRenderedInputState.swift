struct TerminalRenderedInputState: Equatable {
    let totalLineCount: Int
    let cursorLineOffset: Int
    let cursorColumn: Int
}

func terminalRenderedInputState(
    promptDisplayWidth: Int,
    input: String,
    cursorPosition: Int,
    terminalColumns: Int
) -> TerminalRenderedInputState {
    let columns = max(terminalColumns, 1)
    let clampedCursorPosition = min(max(cursorPosition, 0), input.count)
    let cursorIndex = input.index(input.startIndex, offsetBy: clampedCursorPosition)
    let cursorWidth = String(input[..<cursorIndex]).terminalWrappedDisplayWidth(
        after: promptDisplayWidth,
        terminalColumns: columns
    )
    let totalWidth = String(input[cursorIndex...]).terminalWrappedDisplayWidth(
        after: cursorWidth,
        terminalColumns: columns
    )
    let hasTrailingContent = cursorWidth < totalWidth

    let cursorLineOffset: Int
    let cursorColumn: Int

    if cursorWidth <= 0 {
        cursorLineOffset = 0
        cursorColumn = 1
    } else if cursorWidth % columns == 0, !hasTrailingContent {
        cursorLineOffset = max((cursorWidth / columns) - 1, 0)
        cursorColumn = columns
    } else {
        cursorLineOffset = cursorWidth / columns
        cursorColumn = (cursorWidth % columns) + 1
    }

    return TerminalRenderedInputState(
        totalLineCount: wrappedTerminalLineCount(
            displayWidth: totalWidth,
            terminalColumns: columns
        ),
        cursorLineOffset: cursorLineOffset,
        cursorColumn: cursorColumn
    )
}

func wrappedTerminalLineCount(
    displayWidth: Int,
    terminalColumns: Int
) -> Int {
    let columns = max(terminalColumns, 1)
    return max(1, (max(displayWidth, 1) - 1) / columns + 1)
}

func terminalExpandedTabText(
    promptDisplayWidth: Int,
    input: String,
    cursorPosition: Int,
    terminalColumns: Int,
    tabWidth: Int = 8
) -> String {
    let cursorColumn = terminalRenderedInputState(
        promptDisplayWidth: promptDisplayWidth,
        input: input,
        cursorPosition: cursorPosition,
        terminalColumns: terminalColumns
    ).cursorColumn
    let zeroBasedColumn = max(cursorColumn - 1, 0)
    let spacesUntilNextStop = max(1, tabWidth - (zeroBasedColumn % tabWidth))
    return String(repeating: " ", count: spacesUntilNextStop)
}

func canIncrementallyAppendInput(
    previousInput: String,
    previousCursorPosition: Int,
    insertedText: String
) -> Bool {
    guard !insertedText.isEmpty else { return false }
    guard previousCursorPosition == previousInput.count else { return false }
    return insertedText.unicodeScalars.allSatisfy { scalar in
        scalar.value >= 0x20 && scalar.value != 0x7F
    }
}
