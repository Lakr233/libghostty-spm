import Foundation
import GhosttyTerminal

enum EchoTerminal {
    enum CommandResult {
        case output(String)
        case clear
        case exit
    }

    nonisolated static let prompt = "sandbox@ghostty % "

    nonisolated static let welcomeMessage = """
    \r\n  GhosttyKit Sandbox Demo\r
    \r\n  This terminal runs inside App Sandbox.\r
      No subprocesses are spawned.\r
      Type 'help' for available commands.\r\n\r\n
    """

    nonisolated static func processCommand(
        _ command: String,
        username: String,
        terminalSize: TerminalHostManagedResize
    ) -> CommandResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .output("") }

        let parts = trimmed.split(separator: " ", maxSplits: 1)
        let cmd = String(parts[0]).lowercased()
        let args = parts.count > 1 ? String(parts[1]) : ""

        switch cmd {
        case "help":
            return .output("""
            Available commands:\r
              help    - Show this help message\r
              echo    - Echo text back\r
              date    - Show current date/time\r
              uname   - Show system information\r
              whoami  - Show current user\r
              env     - Show environment variables\r
              size    - Show terminal size\r
              clear   - Clear the screen\r
              exit    - Exit the terminal\r\n
            """)
        case "echo":
            return .output(args + "\r\n")
        case "date":
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE MMM dd HH:mm:ss zzz yyyy"
            return .output(formatter.string(from: Date()) + "\r\n")
        case "uname":
            return .output("Darwin ghostty-sandbox host-managed\r\n")
        case "whoami":
            return .output(username + "\r\n")
        case "env":
            return .output("""
            TERM=xterm-ghostty\r
            SHELL=/bin/zsh\r
            USER=\(username)\r
            HOME=/Users/\(username)\r
            LANG=en_US.UTF-8\r
            TERM_PROGRAM=GhosttyKit\r\n
            """)
        case "size":
            return .output(
                "columns: \(terminalSize.columns), rows: \(terminalSize.rows), " +
                    "pixels: \(terminalSize.widthPixels)x\(terminalSize.heightPixels)\r\n"
            )
        case "clear":
            return .clear
        case "exit", "logout":
            return .exit
        default:
            return .output("echo: \(trimmed)\r\n")
        }
    }
}
