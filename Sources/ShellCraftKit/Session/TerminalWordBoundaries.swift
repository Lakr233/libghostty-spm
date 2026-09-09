func terminalPreviousWordBoundary(
    in input: String,
    from cursorPosition: Int
) -> Int {
    terminalPreviousBoundary(
        in: input,
        from: cursorPosition,
        skippingTrailingCharactersWhere: { !$0.isTerminalWordCharacter },
        consumingCharactersWhere: { $0.isTerminalWordCharacter }
    )
}

func terminalNextWordBoundary(
    in input: String,
    from cursorPosition: Int
) -> Int {
    terminalNextBoundary(
        in: input,
        from: cursorPosition,
        skippingLeadingCharactersWhere: { !$0.isTerminalWordCharacter },
        consumingCharactersWhere: { $0.isTerminalWordCharacter }
    )
}

func terminalPreviousShellWordBoundary(
    in input: String,
    from cursorPosition: Int
) -> Int {
    terminalPreviousBoundary(
        in: input,
        from: cursorPosition,
        skippingTrailingCharactersWhere: { $0.isTerminalWordWhitespace },
        consumingCharactersWhere: { !$0.isTerminalWordWhitespace }
    )
}

func terminalDeleteBackwardWord(
    input: String,
    cursorPosition: Int
) -> (input: String, cursorPosition: Int) {
    terminalDeleteBackward(
        input: input,
        cursorPosition: cursorPosition,
        boundary: terminalPreviousWordBoundary
    )
}

func terminalDeleteForwardWord(
    input: String,
    cursorPosition: Int
) -> (input: String, cursorPosition: Int) {
    let clampedCursorPosition = min(max(cursorPosition, 0), input.count)
    let boundary = terminalNextWordBoundary(
        in: input,
        from: clampedCursorPosition
    )
    guard clampedCursorPosition < boundary else {
        return (input, clampedCursorPosition)
    }

    var updatedInput = input
    let start = updatedInput.index(
        updatedInput.startIndex,
        offsetBy: clampedCursorPosition
    )
    let end = updatedInput.index(updatedInput.startIndex, offsetBy: boundary)
    updatedInput.removeSubrange(start ..< end)
    return (updatedInput, clampedCursorPosition)
}

func terminalDeleteBackwardShellWord(
    input: String,
    cursorPosition: Int
) -> (input: String, cursorPosition: Int) {
    terminalDeleteBackward(
        input: input,
        cursorPosition: cursorPosition,
        boundary: terminalPreviousShellWordBoundary
    )
}

private func terminalDeleteBackward(
    input: String,
    cursorPosition: Int,
    boundary resolveBoundary: (String, Int) -> Int
) -> (input: String, cursorPosition: Int) {
    let clampedCursorPosition = min(max(cursorPosition, 0), input.count)
    let boundary = resolveBoundary(input, clampedCursorPosition)
    guard boundary < clampedCursorPosition else {
        return (input, clampedCursorPosition)
    }

    var updatedInput = input
    let start = updatedInput.index(updatedInput.startIndex, offsetBy: boundary)
    let end = updatedInput.index(
        updatedInput.startIndex,
        offsetBy: clampedCursorPosition
    )
    updatedInput.removeSubrange(start ..< end)
    return (updatedInput, boundary)
}

private extension Character {
    var isTerminalWordWhitespace: Bool {
        unicodeScalars.allSatisfy(\.properties.isWhitespace)
    }

    var isTerminalWordCharacter: Bool {
        unicodeScalars.allSatisfy { scalar in
            scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "_"
        }
    }
}

private func terminalPreviousBoundary(
    in input: String,
    from cursorPosition: Int,
    skippingTrailingCharactersWhere shouldSkipTrailing: (Character) -> Bool,
    consumingCharactersWhere shouldConsume: (Character) -> Bool
) -> Int {
    var index = input.index(
        input.startIndex,
        offsetBy: min(max(cursorPosition, 0), input.count)
    )
    while index > input.startIndex {
        let previous = input.index(before: index)
        guard shouldSkipTrailing(input[previous]) else { break }
        index = previous
    }
    while index > input.startIndex {
        let previous = input.index(before: index)
        guard shouldConsume(input[previous]) else { break }
        index = previous
    }
    return input.distance(from: input.startIndex, to: index)
}

private func terminalNextBoundary(
    in input: String,
    from cursorPosition: Int,
    skippingLeadingCharactersWhere shouldSkipLeading: (Character) -> Bool,
    consumingCharactersWhere shouldConsume: (Character) -> Bool
) -> Int {
    var index = input.index(
        input.startIndex,
        offsetBy: min(max(cursorPosition, 0), input.count)
    )
    while index < input.endIndex, shouldSkipLeading(input[index]) {
        index = input.index(after: index)
    }
    while index < input.endIndex, shouldConsume(input[index]) {
        index = input.index(after: index)
    }
    return input.distance(from: input.startIndex, to: index)
}
