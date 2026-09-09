import Foundation

/// Decode as many complete UTF-8 characters as possible from raw bytes.
///
/// Returns the decoded text and any trailing bytes that form an incomplete
/// (but potentially valid) UTF-8 sequence. Invalid bytes are skipped
/// immediately — only genuinely incomplete tails are retained as leftover.
func decodeUTF8Incrementally(_ data: Data) -> (String, Data) {
    var decoded = ""
    var i = data.startIndex

    while i < data.endIndex {
        let byte = data[i]

        let sequenceLength: Int
        switch byte {
        case 0x00 ... 0x7F: sequenceLength = 1
        case 0xC2 ... 0xDF: sequenceLength = 2
        case 0xE0 ... 0xEF: sequenceLength = 3
        case 0xF0 ... 0xF4: sequenceLength = 4
        default:
            i += 1
            continue
        }

        let remaining = data.endIndex - i
        if remaining < sequenceLength {
            // Verify trailing bytes are valid continuations (0x80-0xBF).
            // If any trailing byte is NOT a continuation, the sequence can
            // never be completed — skip the lead byte and keep scanning.
            var validPrefix = true
            for j in (i + 1) ..< data.endIndex {
                if data[j] & 0xC0 != 0x80 {
                    validPrefix = false
                    break
                }
            }
            if validPrefix {
                break
            }
            i += 1
            continue
        }

        let slice = data[i ..< i + sequenceLength]
        if let char = String(data: Data(slice), encoding: .utf8) {
            decoded += char
            i += sequenceLength
        } else {
            i += 1
        }
    }

    let leftover = i < data.endIndex ? Data(data[i...]) : Data()
    return (decoded, leftover)
}
