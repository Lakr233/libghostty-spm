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
                .path
        ))
        #expect(fileManager.fileExists(
            atPath: terminfo.appendingPathComponent("78/xterm-ghostty").path
        ))
        #expect(
            resources.deletingLastPathComponent()
                .appendingPathComponent("terminfo")
                .standardizedFileURL
                == terminfo.standardizedFileURL
        )
    }

    @Test
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
