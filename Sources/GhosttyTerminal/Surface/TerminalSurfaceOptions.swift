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
    public var context: TerminalSurfaceContext

    /// Coalescing window for host-driven resizes, in milliseconds. `0`
    /// (the default) sizes the surface synchronously on every metrics change,
    /// which is the behaviour with no coalescing at all.
    ///
    /// Set this when the content re-renders on every resize: a live drag posts
    /// sizes faster than a full-repaint TUI can settle, so the grid reflow
    /// runs permanently behind the layer bounds. Bounding the stream — leading
    /// edge for responsiveness, trailing edge so the final size always lands —
    /// gives such a client something to settle on. Content that redraws
    /// incrementally is better off at `0`; coalesced jumps read as blinking.
    public var resizeThrottleMilliseconds: Double

    public init(
        backend: TerminalSessionBackend = .exec,
        fontSize: Float? = nil,
        workingDirectory: String? = nil,
        envVars: [String: String] = [:],
        context: TerminalSurfaceContext = .window,
        resizeThrottleMilliseconds: Double = 0
    ) {
        self.backend = backend
        self.fontSize = fontSize
        self.workingDirectory = workingDirectory
        self.envVars = envVars
        self.context = context
        self.resizeThrottleMilliseconds = max(0, resizeThrottleMilliseconds)
    }

    // `resizeThrottleMilliseconds` is deliberately absent: it is a delivery
    // policy, not part of the surface's identity. Including it would tear down
    // and rebuild a live surface — discarding its grid and scrollback — for a
    // change that only affects how often the existing surface is resized.
    func isEquivalent(to other: TerminalSurfaceOptions) -> Bool {
        fontSize == other.fontSize
            && workingDirectory == other.workingDirectory
            && envVars == other.envVars
            && context == other.context
            && backend.isEquivalent(to: other.backend)
    }

    var inMemorySession: InMemoryTerminalSession? {
        guard case let .inMemory(session) = backend else { return nil }
        return session
    }
}
