#if !canImport(UIKit) && canImport(AppKit)
    import Foundation
    @testable import GhosttyTerminal
    import Testing

    /// The title carries the directory name at every prompt, and a directory
    /// name is whatever a cloned repository or an unpacked archive says it
    /// is. This one ends the title with its BEL and writes the clipboard
    /// with the OSC 52 behind it, so `cd` alone would be enough.
    @Suite("GhosttyShellIntegrationTitle")
    struct GhosttyShellIntegrationTitleTests {
        private static let directoryName = "x\u{07}\u{1B}]52;c;aGk=\u{07}"

        @Test(.timeLimit(.minutes(1)))
        func `bash strips the bytes that would end the title`() throws {
            let output = try promptOutput(
                shell: "/bin/bash",
                flags: ["--noprofile", "--norc", "-i"],
                integration: "bash/ghostty.bash",
            )

            #expect(!output.contains("\u{1B}]52"))
            #expect(output.contains("x]52;c;aGk=\u{07}"))
        }

        /// `%~` prints control characters in caret notation on its own.
        @Test(.timeLimit(.minutes(1)))
        func `zsh shows the bytes that would end the title`() throws {
            let output = try promptOutput(
                shell: "/bin/zsh",
                flags: ["-f", "-i"],
                integration: "zsh/ghostty-integration",
            )

            #expect(!output.contains("\u{1B}]52"))
            #expect(output.contains("x^G^[]52;c;aGk=^G\u{07}"))
        }

        /// Runs one prompt hook inside the hostile directory. `script` gives
        /// the shell a terminal of its own: an interactive shell in a
        /// background process group of the test's terminal stops itself.
        private func promptOutput(shell: String, flags: [String], integration: String) throws -> String {
            let resources = try #require(GhosttyRuntimeResources.directoryURL)
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("ghostty-title-test-\(UUID().uuidString)", isDirectory: true)
            let directory = base.appendingPathComponent(Self.directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }

            var environment = ProcessInfo.processInfo.environment
            environment["GHOSTTY_SHELL_FEATURES"] = "title"
            environment["GHOSTTY_TEST_INTEGRATION"] = resources
                .appendingPathComponent("shell-integration/\(integration)").path
            environment["HOME"] = base.path

            let output = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", shell] + flags
                + ["-c", #"source "$GHOSTTY_TEST_INTEGRATION"; _ghostty_precmd"#]
            process.currentDirectoryURL = directory
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: bytes, as: UTF8.self)
        }
    }
#endif
