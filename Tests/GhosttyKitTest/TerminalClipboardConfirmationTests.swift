@testable import GhosttyTerminal
import Testing

@MainActor
struct TerminalClipboardConfirmationTests {
    @Test
    func `request completes only once`() {
        var decisions: [Bool] = []
        let request = TerminalClipboardConfirmationRequest(
            contents: "one\ntwo",
            kind: .paste,
            completion: { decisions.append($0) }
        )

        request.respond(allow: true)
        request.respond(allow: false)

        #expect(decisions == [true])
    }

    @Test
    func `unanswered request denies on release`() {
        var decisions: [Bool] = []
        var request: TerminalClipboardConfirmationRequest? =
            TerminalClipboardConfirmationRequest(
                contents: "one\ntwo",
                kind: .paste,
                completion: { decisions.append($0) }
            )

        #expect(request != nil)
        request = nil

        #expect(decisions == [false])
    }
}
