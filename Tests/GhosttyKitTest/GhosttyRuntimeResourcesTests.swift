import Darwin
import Foundation
@testable import GhosttyTerminal
import Testing

struct GhosttyRuntimeResourcesTests {
    @Test
    func `runtime resource layout matches Ghostty exec expectations`() throws {
        let resources = try #require(GhosttyRuntimeResources.directoryURL)
        let terminfo = try #require(GhosttyRuntimeResources.terminfoDirectoryURL)
        let fileManager = FileManager.default

        #expect(fileManager.fileExists(
            atPath: resources
                .appendingPathComponent("shell-integration/zsh/ghostty-integration")
                .path,
        ))
        #expect(fileManager.fileExists(
            atPath: terminfo.appendingPathComponent("78/xterm-ghostty").path,
        ))
        #expect(
            resources.deletingLastPathComponent()
                .appendingPathComponent("terminfo")
                .standardizedFileURL
                == terminfo.standardizedFileURL,
        )
    }

    /// The bundle ships into every host app, so it may hold only the files
    /// we wrote or vendored under MIT: upstream's bash and zsh integration is
    /// GPLv3 and came back once already (see Script/check-licenses.sh).
    @Test
    func `bundled shell integration is exactly the MIT set and carries no GPL text`() throws {
        let resources = try #require(GhosttyRuntimeResources.directoryURL)
        let integration = resources.appendingPathComponent("shell-integration")
        let enumerator = try #require(FileManager.default.enumerator(
            at: integration,
            includingPropertiesForKeys: [.isRegularFileKey],
        ))

        var files: [String] = []
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            files.append(url.resolvingSymlinksInPath().path.replacingOccurrences(
                of: integration.resolvingSymlinksInPath().path + "/",
                with: "",
            ))

            let text = try String(contentsOf: url, encoding: .utf8)
            // Split so the license name itself never appears in this tree.
            #expect(!text.localizedCaseInsensitiveContains("General Public " + "License"), "\(url.lastPathComponent)")
        }

        #expect(files.sorted() == [
            "bash/LICENSE-bash-preexec.md",
            "bash/bash-preexec.sh",
            "bash/ghostty.bash",
            "zsh/.zshenv",
            "zsh/ghostty-integration",
        ])
    }

    /// An app assembled from `swift build` output carries the bundle in
    /// `Contents/Resources` under the consumer's package prefix; SwiftPM's
    /// `Bundle.module` never looks there.
    @Test
    func `resource bundle is found by suffix in a resources directory`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhosttyTerminalBundleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(Bundle.ghosttyTerminalBundle(in: directory) == nil)
        #expect(Bundle.ghosttyTerminalBundle(in: nil) == nil)
        #expect(Bundle.ghosttyTerminalBundle(in: directory.appendingPathComponent("missing")) == nil)

        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Other_GhosttyTheme.bundle"),
            withIntermediateDirectories: true,
        )
        #expect(Bundle.ghosttyTerminalBundle(in: directory) == nil)

        let expected = directory.appendingPathComponent("SomePackage_GhosttyTerminal.bundle")
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        let found = try #require(Bundle.ghosttyTerminalBundle(in: directory))
        #expect(found.bundleURL.standardizedFileURL == expected.standardizedFileURL)
    }

    /// Outside an app the lookup misses and `Bundle.module` answers.
    @Test
    func `resource bundle falls back to the module bundle`() {
        #expect(Bundle.ghosttyTerminal.bundleURL == Bundle.module.bundleURL)
    }

    /// Main actor: `setenv`/`unsetenv` must not run while `ghostty_init` on
    /// the main thread is reading the environment.
    @Test @MainActor
    func `configuration exports Ghostty resource root`() throws {
        let previous = getenv("GHOSTTY_RESOURCES_DIR").map { String(cString: $0) }
        defer {
            if let previous {
                setenv("GHOSTTY_RESOURCES_DIR", previous, 1)
            } else {
                unsetenv("GHOSTTY_RESOURCES_DIR")
            }
        }

        GhosttyRuntimeResources.configureEnvironment()

        let resources = try #require(GhosttyRuntimeResources.directoryURL)
        let exported = try #require(getenv("GHOSTTY_RESOURCES_DIR"))
        #expect(String(cString: exported) == resources.path)
    }
}
