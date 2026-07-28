import Darwin
import Foundation

/// Runtime assets required by Ghostty's exec backend.
///
/// The package owns these assets and always points libghostty at this immutable
/// bundle location before the C runtime initializes. User-level Ghostty
/// resources and configuration are never consulted.
public enum GhosttyRuntimeResources {
    /// The package-bundled directory containing terminfo and shell integration.
    public static var directoryURL: URL? {
        Bundle.module.url(forResource: "Ghostty", withExtension: nil)
    }

    static func configureEnvironment() {
        guard let path = directoryURL?.path else { return }
        setenv("GHOSTTY_RESOURCES_DIR", path, 1)
    }
}
