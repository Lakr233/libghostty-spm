import Foundation
@testable import GhosttyTerminal

/// Holds an object weakly so a stress loop can check, after the fact, that
/// every instance it made went away.
final class WeakReference {
    weak var object: AnyObject?
    let label: String

    init(_ object: AnyObject, _ label: String) {
        self.object = object
        self.label = label
    }
}

/// Every generated config file a stress loop's controllers wrote. A
/// controller replaces its file on each reconfigure, so the URL is sampled
/// after every change, not only at the end.
@MainActor
final class ManagedConfigLedger {
    private(set) var urls: Set<URL> = []

    func record(_ controller: TerminalController) {
        guard let url = controller.managedConfigURL else { return }
        urls.insert(url)
    }

    var leftovers: [URL] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }
}

enum LifecycleStress {
    /// A distinct theme per cycle, so every reconfigure renders a new config.
    static func theme(_ index: Int) -> TerminalTheme {
        TerminalTheme(
            light: TerminalConfiguration()
                .background(String(format: "F%05X", index % 0xFFFF))
                .foreground("202020"),
            dark: TerminalConfiguration()
                .background(String(format: "1%05X", index % 0xFFFF))
                .foreground("E0E0E0"),
        )
    }

    /// Lets the main queue run what teardown left on it: `publishSoon`
    /// closures, focus replays, callbacks hopped from ghostty's threads.
    /// Each of those holds its target until it runs, so a weak reference is
    /// only meaningful once they have.
    @MainActor
    static func drainMainQueue(turns: Int = 3) async {
        for _ in 0 ..< turns {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    static func survivors(_ references: [WeakReference]) -> [String] {
        references.filter { $0.object != nil }.map(\.label)
    }
}
