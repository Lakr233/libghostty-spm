import GhosttyTerminal
import UIKit

class ViewController: UIViewController, TerminalViewDelegate {
    private lazy var terminalView: NativeTerminalView = .init(frame: .zero)

    private lazy var mockSession: MockTerminalSession = .init()

    private lazy var controller: TerminalController = {
        let configPath = Bundle.main.path(forResource: "DefaultGhostty", ofType: "config")
        return TerminalController(configFilePath: configPath)
    }()

    override func loadView() {
        terminalView.delegate = self
        terminalView.configuration = TerminalSurfaceConfiguration(
            backend: .hostManaged(mockSession.terminalSession)
        )
        terminalView.controller = controller
        view = terminalView
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        terminalView.becomeFirstResponder()
        mockSession.start()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        terminalView.fitToSize()
    }

    // TerminalViewDelegate

    func terminalDidChangeTitle(_ title: String) {
        self.title = title
    }

    func terminalDidResize(columns _: Int, rows _: Int) {
        // Size updated
    }

    func terminalDidClose(processAlive _: Bool) {
        // Terminal closed
    }
}
