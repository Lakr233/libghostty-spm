import Foundation
import GhosttyTerminal

final class SessionBridge: @unchecked Sendable {
    nonisolated(unsafe) weak var session: InMemoryTerminalSession?
}
