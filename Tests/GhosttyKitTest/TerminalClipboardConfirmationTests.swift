import Foundation
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

/// Regression coverage for #0390's post-rebase corruption: the wrapper has
/// two independent callers that can each try to answer the same clipboard
/// read request — the host's confirmation UI resolving normally, and
/// `denyAllPendingClipboardRequests()` denying everything outstanding at
/// surface teardown (called from `TerminalSurfaceCoordinator.deinit`, whose
/// `MainActor.assumeIsolated` is an unenforced assumption, not a guarantee,
/// about which thread runs it). If both ever answer the same request, two
/// calls into libghostty for one (already-freed-by-the-first-call)
/// `apprt.ClipboardRequest*` is a use-after-free that corrupts the heap —
/// consistent with the garbled escape-sequence fragments and misbehaving
/// keys reported live. These tests exercise `TerminalCallbackBridge`'s
/// bookkeeping directly, with no live `ghostty_surface_t` (`rawSurface` is
/// nil, so `finishClipboardRequest` never reaches libghostty) — the
/// `testHooks_clipboardAnswerCount` counter is the observable stand-in for
/// "libghostty was told exactly once."
@MainActor
struct TerminalClipboardRequestBookkeepingTests {
    private func makeStatePtr() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    }

    @Test
    func `resolve then denyAll answers exactly once`() {
        let bridge = TerminalCallbackBridge()
        let statePtr = makeStatePtr()
        defer { statePtr.deallocate() }

        let token = bridge.registerPendingClipboardRequest(statePtr)
        token.resolve(true, contents: [], available: [])
        bridge.denyAllPendingClipboardRequests()

        #expect(bridge.testHooks_clipboardAnswerCount == 1)
    }

    @Test
    func `denyAll then resolve answers exactly once`() {
        let bridge = TerminalCallbackBridge()
        let statePtr = makeStatePtr()
        defer { statePtr.deallocate() }

        let token = bridge.registerPendingClipboardRequest(statePtr)
        bridge.denyAllPendingClipboardRequests()
        token.resolve(true, contents: [], available: [])

        #expect(bridge.testHooks_clipboardAnswerCount == 1)
    }

    @Test
    func `resolve twice answers exactly once`() {
        let bridge = TerminalCallbackBridge()
        let statePtr = makeStatePtr()
        defer { statePtr.deallocate() }

        let token = bridge.registerPendingClipboardRequest(statePtr)
        token.resolve(true, contents: [], available: [])
        token.resolve(false, contents: [], available: [])

        #expect(bridge.testHooks_clipboardAnswerCount == 1)
    }

    @Test
    func `concurrent resolve and denyAll race never answers twice`() async {
        let bridge = TerminalCallbackBridge()
        let iterations = 500
        var statePtrs: [UnsafeMutableRawPointer] = []
        var tokens: [PendingClipboardRequest] = []
        for _ in 0 ..< iterations {
            let ptr = makeStatePtr()
            statePtrs.append(ptr)
            tokens.append(bridge.registerPendingClipboardRequest(ptr))
        }
        defer { statePtrs.forEach { $0.deallocate() } }

        // Race each token's own resolve against a shared denyAll sweep from
        // two concurrent queues, so scheduling order between the two answer
        // paths is genuinely non-deterministic across iterations.
        await withTaskGroup(of: Void.self) { group in
            for token in tokens {
                group.addTask {
                    token.resolve(true, contents: [], available: [])
                }
            }
            group.addTask {
                bridge.denyAllPendingClipboardRequests()
            }
            // A second sweep: some requests may not have been registered
            // race-free relative to the first sweep in a slower CI run, but
            // no request may ever be answered more than once regardless.
            group.addTask {
                bridge.denyAllPendingClipboardRequests()
            }
        }

        #expect(bridge.testHooks_clipboardAnswerCount == iterations)
    }
}
