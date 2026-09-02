import Foundation
import GhosttyTerminal

enum ShellSessionEvent: Sendable {
    case start
    case write(Data)
    case resize(InMemoryTerminalViewport)
}

public final class ShellSession {
    public let terminalSession: InMemoryTerminalSession
    private let events: AsyncStream<ShellSessionEvent>.Continuation

    public init(shell: ShellDefinition) {
        let sessionBridge = SessionBridge()
        let engine = Engine(shell: shell, sessionBridge: sessionBridge)
        let (stream, events) = AsyncStream.makeStream(of: ShellSessionEvent.self)
        let terminalSession = InMemoryTerminalSession(
            write: { data in
                events.yield(.write(data))
            },
            resize: { size in
                events.yield(.resize(size))
            }
        )
        sessionBridge.session = terminalSession

        self.terminalSession = terminalSession
        self.events = events
        Task {
            await engine.run(stream)
        }
    }

    deinit {
        events.finish()
    }

    public func start() {
        events.yield(.start)
    }
}
