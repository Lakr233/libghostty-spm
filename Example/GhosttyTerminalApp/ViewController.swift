import Cocoa
import GhosttyTerminal
import ShellCraftKit

final class ViewController: NSViewController {
    private lazy var terminalView: TerminalView = .init(
        frame: NSRect(x: 0, y: 0, width: 720, height: 480)
    )

    private lazy var shellSession: ShellSession = .init(shell: defaultSandboxShell)

    private lazy var controller: TerminalController = .init { builder in
        builder.withBackgroundOpacity(0)
        builder.withCustom("keybind", "super+k=text:\\x0c")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        configureTerminalView()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        activateTerminal()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        terminalView.fitToSize()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyWindowBackgroundColor()
    }

    private func configureView() {
        view.wantsLayer = true
        applyWindowBackgroundColor()
    }

    private func applyWindowBackgroundColor() {
        // `NSColor.windowBackgroundColor.cgColor` snapshots the current
        // appearance; resolve it against the view's effective appearance on
        // every change so the layer follows light/dark toggles.
        view.layer?.backgroundColor = NSColor.windowBackgroundColor
            .resolvedColor(with: view.effectiveAppearance)
            .cgColor
    }

    private func configureTerminalView() {
        terminalView.delegate = self
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .inMemory(shellSession.terminalSession)
        )
        terminalView.controller = controller
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func activateTerminal() {
        view.window?.makeFirstResponder(terminalView)
        shellSession.start()
    }
}

// MARK: - Terminal Callbacks

extension ViewController:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceResizeDelegate,
    TerminalSurfaceCloseDelegate
{
    func terminalDidChangeTitle(_ title: String) {
        view.window?.title = title
    }

    func terminalDidResize(columns _: Int, rows _: Int) {}

    func terminalDidClose(processAlive _: Bool) {
        view.window?.close()
    }
}
