@testable import GhosttyTerminal
import Testing

@Suite(.serialized)
struct TerminalDebugLogTests {
    @Test
    func loggingIsDisabledByDefault() {
        withRestoredDebugLogState {
            #expect(!TerminalDebugLog.isEnabled)
            #expect(TerminalDebugLog.categories == .standard)
            #expect(!TerminalDebugLog.categories.contains(.render))
        }
    }

    @Test
    func loggingCanBeToggledAndReconfigured() {
        withRestoredDebugLogState {
            TerminalDebugLog.disable()
            #expect(!TerminalDebugLog.isEnabled)

            TerminalDebugLog.enable(.all)
            TerminalDebugLog.sink = { _ in }

            #expect(TerminalDebugLog.isEnabled)
            #expect(TerminalDebugLog.categories == .all)
        }
    }
}

private func withRestoredDebugLogState(
    _ body: () -> Void
) {
    let originalEnabled = TerminalDebugLog.isEnabled
    let originalCategories = TerminalDebugLog.categories
    let originalSink = TerminalDebugLog.sink
    defer {
        TerminalDebugLog.isEnabled = originalEnabled
        TerminalDebugLog.categories = originalCategories
        TerminalDebugLog.sink = originalSink
    }

    body()
}
