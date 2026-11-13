import GhosttyKit
import XCTest

class GhosttyKitTest: XCTestCase {
    func testAppLifecycle() {
        XCTAssertEqual(ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv), GHOSTTY_SUCCESS)

        guard let config = ghostty_config_new() else {
            return XCTFail("ghostty_config_new returned nil")
        }
        defer { ghostty_config_free(config) }

        ghostty_config_finalize(config)

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in },
            action_cb: { _, _, _ in false },
            read_clipboard_cb: { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNAVAILABLE },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, _, _, _, _ in },
            close_surface_cb: nil,
        )

        guard let app = ghostty_app_new(&runtime, config) else {
            return XCTFail("ghostty_app_new returned nil")
        }
        ghostty_app_free(app)
    }
}
