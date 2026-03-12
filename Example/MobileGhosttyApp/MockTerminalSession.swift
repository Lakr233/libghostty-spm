import Foundation
import GhosttyTerminal

final class MockTerminalSession {
    let terminalSession: TerminalHostManagedSession
    private let engine: Engine

    init() {
        let engine = Engine()
        let terminalSession = TerminalHostManagedSession(
            write: { data in
                Task {
                    await engine.handleOutbound(data)
                }
            },
            resize: { size in
                Task {
                    await engine.updateSize(size)
                }
            }
        )
        engine.setSession(terminalSession)

        self.terminalSession = terminalSession
        self.engine = engine
    }

    func start() {
        Task {
            await engine.start()
        }
    }
}

private actor Engine {
    private enum EscapeState {
        case none
        case escape
        case controlSequence
    }

    private var session: TerminalHostManagedSession?
    private var startedAt = Date()
    private var currentInput = ""
    private var escapeState = EscapeState.none
    private var ignoreNextLineFeed = false
    private var hasStarted = false
    private var terminalSize = TerminalHostManagedResize(
        columns: 80,
        rows: 20,
        widthPixels: 0,
        heightPixels: 0
    )

    func setSession(_ session: TerminalHostManagedSession) {
        self.session = session
    }

    func start() {
        guard !hasStarted else {
            return
        }

        hasStarted = true
        startedAt = Date()
        send("\u{1B}[2J\u{1B}[H")
        send(EchoTerminal.welcomeMessage)
        sendPrompt()
    }

    func updateSize(_ size: TerminalHostManagedResize) {
        terminalSize = size
    }

    func handleOutbound(_ data: Data) {
        for byte in data {
            handle(byte)
        }
    }

    private func handle(_ byte: UInt8) {
        switch escapeState {
        case .escape:
            escapeState = byte == 0x5B || byte == 0x4F ? .controlSequence : .none
            return

        case .controlSequence:
            if (0x40 ... 0x7E).contains(byte) {
                escapeState = .none
            }
            return

        case .none:
            break
        }

        switch byte {
        case 0x1B:
            escapeState = .escape

        case 0x03:
            currentInput.removeAll(keepingCapacity: true)
            send("^C\r\n")
            sendPrompt()

        case 0x0C:
            currentInput.removeAll(keepingCapacity: true)
            send("\u{1B}[2J\u{1B}[H")
            sendPrompt()

        case 0x08, 0x7F:
            guard !currentInput.isEmpty else {
                return
            }

            currentInput.removeLast()
            redrawInputLine()

        case 0x0D:
            ignoreNextLineFeed = true
            submitCurrentInput()

        case 0x0A:
            if ignoreNextLineFeed {
                ignoreNextLineFeed = false
                return
            }

            submitCurrentInput()

        case 0x09:
            currentInput.append("\t")
            send("\t")

        default:
            guard byte >= 0x20 else {
                return
            }

            currentInput.append(Character(UnicodeScalar(byte)))
            send(Data([byte]))
        }
    }

    private func submitCurrentInput() {
        send("\r\n")

        let command = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        currentInput.removeAll(keepingCapacity: true)

        switch EchoTerminal.processCommand(
            command,
            username: NSUserName(),
            terminalSize: terminalSize
        ) {
        case let .output(output):
            if !output.isEmpty {
                send(output)
            }
            sendPrompt()

        case .clear:
            send("\u{1B}[2J\u{1B}[H")
            sendPrompt()

        case .exit:
            send("logout\r\n")
            session?.finish(
                exitCode: 0,
                runtimeMilliseconds: elapsedMilliseconds
            )
        }
    }

    private func sendPrompt() {
        send(EchoTerminal.prompt)
    }

    private func redrawInputLine() {
        send("\r\u{1B}[2K")
        send(EchoTerminal.prompt)
        send(currentInput)
    }

    private func send(_ string: String) {
        session?.receive(string)
    }

    private func send(_ data: Data) {
        session?.receive(data)
    }

    private var elapsedMilliseconds: UInt64 {
        UInt64(max(0, Date().timeIntervalSince(startedAt) * 1000))
    }
}
