import GhosttyTerminal
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?,
    ) -> Bool {
        TerminalDebugLog.enable(.standard)
        TerminalDebugLog.sink = { message in
            NSLog("%@", message)
            #if DEBUG
                UITestKeyLog.shared.record(message)
            #endif
        }
        return true
    }

    func application(
        _: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options _: UIScene.ConnectionOptions,
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role,
        )
        config.delegateClass = SceneDelegate.self
        return config
    }
}

#if DEBUG
    /// The last key presses the terminal view sent to its surface, for UI
    /// tests (`terminal.keyLog`). The debug log sink runs on any thread.
    final class UITestKeyLog: @unchecked Sendable {
        static let shared = UITestKeyLog()
        private let lock = NSLock()
        private var stored: [String] = []

        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func record(_ message: String) {
            guard let range = message.range(of: "surface key action=press ") else { return }
            lock.lock()
            stored.append(String(message[range.lowerBound...]))
            if stored.count > 16 {
                stored.removeFirst(stored.count - 16)
            }
            lock.unlock()
        }
    }
#endif
