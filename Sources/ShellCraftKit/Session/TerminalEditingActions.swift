import Foundation

enum TerminalMetaEditingAction: Equatable {
    case moveBackwardWord
    case moveForwardWord
    case deleteBackwardWord
    case deleteForwardWord
}

enum TerminalCSIEditingAction: Equatable {
    case historyUp
    case historyDown
    case moveCursorLeft
    case moveCursorRight
    case moveCursorBackwardWord
    case moveCursorForwardWord
    case moveCursorToStart
    case moveCursorToEnd
    case deleteForward
    case deleteForwardWord
}

func terminalMetaEditingAction(for byte: UInt8) -> TerminalMetaEditingAction? {
    switch byte {
    case 0x08, 0x7F:
        .deleteBackwardWord
    case 0x62:
        .moveBackwardWord
    case 0x64:
        .deleteForwardWord
    case 0x66:
        .moveForwardWord
    default:
        nil
    }
}

func terminalCSIEditingAction(
    params: Data,
    finalByte: UInt8
) -> TerminalCSIEditingAction? {
    switch finalByte {
    case 0x41: // A - Up
        return .historyUp

    case 0x42: // B - Down
        return .historyDown

    case 0x43: // C - Right
        if terminalCSIHasAltModifier(params) {
            return .moveCursorForwardWord
        }
        return .moveCursorRight

    case 0x44: // D - Left
        if terminalCSIHasAltModifier(params) {
            return .moveCursorBackwardWord
        }
        return .moveCursorLeft

    case 0x48: // H - Home
        return .moveCursorToStart

    case 0x46: // F - End
        return .moveCursorToEnd

    case 0x7E: // ~ - Extended keys
        guard let csiParams = terminalCSIParameters(params) else { return nil }
        guard csiParams.first == 3 else { return nil }
        if csiParams.hasAltModifier {
            return .deleteForwardWord
        }
        return .deleteForward

    default:
        return nil
    }
}

func terminalCSIHasAltModifier(_ params: Data) -> Bool {
    terminalCSIParameters(params)?.hasAltModifier == true
}

private struct TerminalCSIParameters {
    let values: [Int]

    var first: Int? {
        values.first
    }

    var hasAltModifier: Bool {
        guard let last = values.last, values.count > 1 else { return false }
        // Decode the xterm-style CSI modifier suffix (`CSI 1;<mod><final>` or
        // `CSI 3;<mod>~`) where the trailing parameter stores 1 + bitmask.
        // Bit 1 is Shift, bit 2 is Alt, and bit 4 is Control.
        return max(last - 1, 0) & 0x2 != 0
    }
}

private func terminalCSIParameters(_ params: Data) -> TerminalCSIParameters? {
    guard !params.isEmpty else { return TerminalCSIParameters(values: []) }
    guard let ascii = String(data: params, encoding: .ascii) else { return nil }
    let components = ascii.split(separator: ";")
    let values = components.compactMap { Int($0) }
    guard values.count == components.count else { return nil }
    return TerminalCSIParameters(values: values)
}
