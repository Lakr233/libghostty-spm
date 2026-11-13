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
            openURL(target, kind: kind, on: bridge)
        }

        #expect(probe.urls == [target, target])
        #expect(probe.detectedTextURLs == [target])
        #expect(probe.explicitHyperlinks == [target])
    }

    @Test
    func `an observing delegate takes every link`() {
        let bridge = TerminalCallbackBridge()
        let probe = OpenURLProbe()
        bridge.delegate = probe

        #expect(openURL("https://example.com/", kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, on: bridge))
    }

    @Test
    func `a link with no delegate for it falls to Ghostty`() {
        let bridge = TerminalCallbackBridge()

        #expect(!openURL("https://example.com/", kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, on: bridge))
    }

    @Test
    func `a handling delegate decides per link`() {
        let bridge = TerminalCallbackBridge()
        let handler = OpenURLHandler { _, kind in kind == .osc8 }
        bridge.delegate = handler

        #expect(openURL("https://example.com/a", kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, on: bridge))
        #expect(!openURL("https://example.com/b", kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, on: bridge))
        #expect(handler.urls == ["https://example.com/a", "https://example.com/b"])
    }

    @Test
    func `view state leaves links to Ghostty until the host sets onOpenURL`() {
        let state = TerminalViewState(controller: TerminalController())
        let bridge = TerminalCallbackBridge()
        bridge.delegate = state
        let target = "https://example.com/"

        #expect(!openURL(target, kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, on: bridge))

        var opened: [(String, TerminalOpenURLKind)] = []
        state.onOpenURL = { url, kind in
            opened.append((url, kind))
            return kind == .osc8
        }

        #expect(openURL(target, kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, on: bridge))
        #expect(!openURL(target, kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, on: bridge))
        #expect(opened.map(\.0) == [target, target])
        #expect(opened.map(\.1) == [.osc8, .unknown])
    }

    @discardableResult
    private func openURL(
        _ target: String,
        kind: ghostty_action_open_url_kind_e,
        on bridge: TerminalCallbackBridge,
    ) -> Bool {
        target.withCString { pointer in
            // Memberwise: the header marks `url` nonnull from the cf5519b
            // pin on, which takes the zero initializer away.
            let payload = ghostty_action_open_url_s(
                kind: kind,
                url: pointer,
                len: .init(target.utf8.count),
            )
            return bridge.handleOpenURL(payload)
        }
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

@MainActor
private final class OpenURLHandler: TerminalSurfaceOpenURLHandlingDelegate {
    var urls: [String] = []
    let decide: (String, TerminalOpenURLKind) -> Bool

    init(decide: @escaping (String, TerminalOpenURLKind) -> Bool) {
        self.decide = decide
    }

    func terminalShouldHandleOpenURL(_ url: String, kind: TerminalOpenURLKind) -> Bool {
        urls.append(url)
        return decide(url, kind)
    }
}
