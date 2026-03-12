import Foundation
import GhosttyKit

public enum TerminalBackend: Sendable {
    case exec
    case hostManaged(TerminalHostManagedSession)
}

public struct TerminalSurfaceConfiguration: Sendable {
    public var backend: TerminalBackend
    public var fontSize: Float?
    public var workingDirectory: String?
    public var command: String?
    public var environmentVariables: [String: String]
    public var initialInput: String?
    public var waitAfterCommand: Bool
    public var context: ghostty_surface_context_e

    public init(
        backend: TerminalBackend = .exec,
        fontSize: Float? = nil,
        workingDirectory: String? = nil,
        command: String? = nil,
        environmentVariables: [String: String] = [:],
        initialInput: String? = nil,
        waitAfterCommand: Bool = false,
        context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_WINDOW
    ) {
        self.backend = backend
        self.fontSize = fontSize
        self.workingDirectory = workingDirectory
        self.command = command
        self.environmentVariables = environmentVariables
        self.initialInput = initialInput
        self.waitAfterCommand = waitAfterCommand
        self.context = context
    }
}
