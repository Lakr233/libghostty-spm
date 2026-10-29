import GhosttyKit
@testable import GhosttyTerminal
import Testing

@MainActor
struct TerminalOpenURLDelegateTests {
    @Test
    func `explicit hyperlinks stay distinct from detected text URLs`() {
        let bridge = TerminalCallbackBridge()
        let probe = OpenURLProbe()
        bridge.delegate = probe
        let target = "https://example.com/"

        for kind in [GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, GHOSTTY_ACTION_OPEN_URL_KIND_OSC8] {
            target.withCString { pointer in
                var action = ghostty_action_s()
                action.tag = GHOSTTY_ACTION_OPEN_URL
                action.action.open_url.kind = kind
                action.action.open_url.url = pointer
                action.action.open_url.len = .init(target.utf8.count)
                bridge.handleAction(action)
            }
        }

        #expect(probe.urls == [target, target])
        #expect(probe.detectedTextURLs == [target])
        #expect(probe.explicitHyperlinks == [target])
    }
}

@MainActor
private final class OpenURLProbe: TerminalSurfaceOpenURLDelegate {
    var urls: [String] = []
    var detectedTextURLs: [String] = []
    var explicitHyperlinks: [String] = []

    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        urls.append(url)
        switch kind {
        case .unknown:
            detectedTextURLs.append(url)
        case .osc8:
            explicitHyperlinks.append(url)
        default:
            break
        }
    }
}
