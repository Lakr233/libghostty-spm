@testable import GhosttyTerminal
import Testing

struct TerminalDebugLogTests {
    @Test
    func loggingIsEnabledByDefault() {
        let originalEnabled = TerminalDebugLog.isEnabled
        let originalCategories = TerminalDebugLog.categories
        let originalSink = TerminalDebugLog.sink
        defer {
            TerminalDebugLog.isEnabled = originalEnabled
            TerminalDebugLog.categories = originalCategories
            TerminalDebugLog.sink = originalSink
        }

        #expect(TerminalDebugLog.isEnabled)
        #expect(TerminalDebugLog.categories == .standard)
        #expect(!TerminalDebugLog.categories.contains(.render))
    }

    @Test
    func loggingCanBeToggledAndReconfigured() {
        let originalEnabled = TerminalDebugLog.isEnabled
        let originalCategories = TerminalDebugLog.categories
        let originalSink = TerminalDebugLog.sink
        defer {
            TerminalDebugLog.isEnabled = originalEnabled
            TerminalDebugLog.categories = originalCategories
            TerminalDebugLog.sink = originalSink
        }

        TerminalDebugLog.disable()
        #expect(!TerminalDebugLog.isEnabled)

        TerminalDebugLog.enable(.all)
        TerminalDebugLog.sink = { _ in }

        #expect(TerminalDebugLog.isEnabled)
        #expect(TerminalDebugLog.categories == .all)
    }
}
