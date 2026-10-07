import Cocoa
import GhosttyTerminal

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaultContentSize = NSSize(width: 720, height: 480)
    private let minimumContentSize = NSSize(width: 480, height: 320)
    private var window: NSWindow?

    func applicationDidFinishLaunching(_: Notification) {
        TerminalDebugLog.enable(.standard)
        TerminalDebugLog.sink = { message in
            NSLog("%@", message)
        }
        NSApp.mainMenu = MainMenu.make()

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
        )
        window.title = "GhosttyKit Sandbox Demo"
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.titlebarAppearsTransparent = false
        window.contentMinSize = minimumContentSize
        window.contentViewController = ViewController()
        // Assigning the controller sizes the window to its view, which starts
        // at zero and is clamped to the minimum; put the default back.
        window.setContentSize(defaultContentSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        repairRestoredWindowSizeIfNeeded(window)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    private func repairRestoredWindowSizeIfNeeded(_ window: NSWindow) {
        DispatchQueue.main.async { [defaultContentSize, minimumContentSize] in
            let contentRect = window.contentRect(forFrameRect: window.frame)
            guard contentRect.width < minimumContentSize.width
                || contentRect.height < minimumContentSize.height
            else {
                return
            }

            window.setContentSize(defaultContentSize)
            window.center()
        }
    }
}
