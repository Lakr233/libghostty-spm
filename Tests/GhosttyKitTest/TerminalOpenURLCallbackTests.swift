import GhosttyKit
import Testing

@testable import GhosttyTerminal

@MainActor
private final class OpenURLDelegateSpy: TerminalSurfaceOpenURLDelegate {
    var urls: [String] = []

    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        urls.append(url)
    }
}

@MainActor
struct TerminalOpenURLCallbackTests {
    @Test
    func `open URL is handled when a delegate owns it`() {
        let delegate = OpenURLDelegateSpy()
        let bridge = TerminalCallbackBridge(delegate: delegate)
        let url = "https://example.com/path?query=value"

        let handled = url.withCString { pointer in
            var actionValue = ghostty_action_u()
            actionValue.open_url = ghostty_action_open_url_s(
                kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN,
                url: pointer,
                len: UInt(url.utf8.count)
            )

            return bridge.handleAction(
                ghostty_action_s(
                    tag: GHOSTTY_ACTION_OPEN_URL,
                    action: actionValue
                )
            )
        }

        #expect(handled)
        #expect(delegate.urls == [url])
    }

    @Test
    func `open URL requests core fallback without a delegate`() {
        let bridge = TerminalCallbackBridge(delegate: nil)
        let url = "https://example.com/"

        let handled = url.withCString { pointer in
            var actionValue = ghostty_action_u()
            actionValue.open_url = ghostty_action_open_url_s(
                kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN,
                url: pointer,
                len: UInt(url.utf8.count)
            )

            return bridge.handleAction(
                ghostty_action_s(
                    tag: GHOSTTY_ACTION_OPEN_URL,
                    action: actionValue
                )
            )
        }

        #expect(!handled)
    }
}
