import Foundation

extension Bundle {
    /// This target's resource bundle, wherever the host put it.
    ///
    /// SwiftPM's generated `Bundle.module` looks for the bundle next to the
    /// main executable (for a macOS app, the `.app` root, which a signed app
    /// cannot carry), then at the absolute build path, then traps. An app
    /// assembled from `swift build` output copies the bundle into
    /// `Contents/Resources` instead, so that is looked at first; `.module`
    /// still covers tests, Xcode builds and command-line tools.
    static let ghosttyTerminal: Bundle = ghosttyTerminalBundle(in: Bundle.main.resourceURL) ?? .module

    /// The `<package>_GhosttyTerminal.bundle` in `directory`, if any. The
    /// prefix is the consumer's identity for this package, so only the
    /// suffix is fixed.
    static func ghosttyTerminalBundle(in directory: URL?) -> Bundle? {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return nil }
        guard let name = names.sorted().first(where: { $0.hasSuffix("_GhosttyTerminal.bundle") }) else { return nil }
        return Bundle(url: directory.appendingPathComponent(name))
    }
}
