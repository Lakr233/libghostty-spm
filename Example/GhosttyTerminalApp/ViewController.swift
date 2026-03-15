import Cocoa
import GhosttyTerminal

class ViewController: NSViewController, TerminalViewDelegate {
    private lazy var terminalView: NativeTerminalView = .init(frame: NSRect(x: 0, y: 0, width: 720, height: 480))

    private lazy var mockSession: MockTerminalSession = .init()

    private lazy var controller: TerminalController = {
        let configPath = Bundle.main.path(forResource: "DefaultGhostty", ofType: "config")
        return TerminalController(configFilePath: configPath)
    }()

    override func loadView() {
        terminalView.autoresizingMask = [.width, .height]
        terminalView.delegate = self
        terminalView.configuration = TerminalSurfaceConfiguration(
            backend: .hostManaged(mockSession.terminalSession)
        )
        terminalView.controller = controller
        view = terminalView
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(terminalView)
        mockSession.start()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        terminalView.fitToSize()
    }

    // TerminalViewDelegate

    func terminalDidChangeTitle(_ title: String) {
        view.window?.title = title
    }

    func terminalDidResize(columns _: Int, rows _: Int) {
        // Size updated
    }

    func terminalDidClose(processAlive _: Bool) {
        view.window?.close()
    }
}
