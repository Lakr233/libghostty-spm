//
//  TerminalSurfaceOptions.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import GhosttyKit

public struct TerminalSurfaceOptions: Sendable {
    public var backend: TerminalSessionBackend
    public var fontSize: Float?
    public var workingDirectory: String?
    /// Extra environment variables set in the child process spawned for this
    /// surface (exec backend). Passed through `ghostty_surface_config_s.env_vars`;
    /// every process launched from the surface's shell inherits them, which lets
    /// embedding hosts tag a surface (e.g. `MYAPP_PANE=<uuid>`) and correlate
    /// externally observed processes back to it.
    public var envVars: [String: String]
    /// Overrides the command executed in the child process spawned for this
    /// surface (exec backend), taking the place of the user's default shell.
    /// Passed through `ghostty_surface_config_s.command`. When `nil`, the
    /// value already established by `ghostty_surface_config_new()` (e.g. the
    /// app-level config's command, if any) is left untouched.
    public var command: String?
    /// Controls whether the surface stays open after `command` exits instead
    /// of closing immediately. Passed through
    /// `ghostty_surface_config_s.wait_after_command`. When `nil`, the value
    /// already established by `ghostty_surface_config_new()` is left
    /// untouched.
    public var waitAfterCommand: Bool?
    public var context: TerminalSurfaceContext

    public init(
        backend: TerminalSessionBackend = .exec,
        fontSize: Float? = nil,
        workingDirectory: String? = nil,
        envVars: [String: String] = [:],
        command: String? = nil,
        waitAfterCommand: Bool? = nil,
        context: TerminalSurfaceContext = .window
    ) {
        self.backend = backend
        self.fontSize = fontSize
        self.workingDirectory = workingDirectory
        self.envVars = envVars
        self.command = command
        self.waitAfterCommand = waitAfterCommand
        self.context = context
    }

    func isEquivalent(to other: TerminalSurfaceOptions) -> Bool {
        fontSize == other.fontSize
            && workingDirectory == other.workingDirectory
            && envVars == other.envVars
            && command == other.command
            && waitAfterCommand == other.waitAfterCommand
            && context == other.context
            && backend.isEquivalent(to: other.backend)
    }

    var inMemorySession: InMemoryTerminalSession? {
        guard case let .inMemory(session) = backend else { return nil }
        return session
    }
}
