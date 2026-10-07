import Cocoa
import GhosttyTerminal
import ShellCraftKit

private final class AppearanceAwareView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

final class ViewController: NSViewController {
    private lazy var terminalView: TerminalView = .init(frame: .zero)

    private lazy var shellSession: ShellSession = .init(shell: defaultSandboxShell)

    private lazy var controller: TerminalController = .init { builder in
        builder.withBackgroundOpacity(0)
        builder.withCustom("keybind", "super+k=text:\\x0c")
        #if DEBUG
            if Self.isUITesting {
                // Ghostty's defaults, spelled out: UI tests place the pointer
                // on a cell from these and the reported cell size.
                builder.withWindowPaddingX(TerminalGridAccessibilityView.padding)
                builder.withWindowPaddingY(TerminalGridAccessibilityView.padding)
                builder.withCustom("window-padding-balance", "false")
            }
        #endif
    }

    #if DEBUG
        private static let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        private var gridAccessibility: TerminalGridAccessibilityView?
    #endif

    override func loadView() {
        let container = AppearanceAwareView()
        container.onAppearanceChange = { [weak self] in
            self?.applyWindowBackgroundColor()
        }
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        applyWindowBackgroundColor()
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

    private func applyWindowBackgroundColor() {
        // `NSColor.windowBackgroundColor.cgColor` snapshots whichever
        // appearance is current at the call site, so drawing it naively
        // caches yesterday's light/dark value on the layer. Resolve it
        // under the view's effective appearance so the layer follows
        // system toggles.
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    private func configureTerminalView() {
        terminalView.delegate = self
        terminalView.setAccessibilityElement(true)
        terminalView.setAccessibilityIdentifier("terminal.surface")
        terminalView.setAccessibilityLabel("Terminal")
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .inMemory(shellSession.terminalSession),
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

        #if DEBUG
            if Self.isUITesting {
                let output = TerminalOutputAccessibilityView(
                    session: shellSession.terminalSession,
                )
                let grid = TerminalGridAccessibilityView()
                gridAccessibility = grid
                for probe in [output, grid] as [NSView] {
                    probe.translatesAutoresizingMaskIntoConstraints = false
                    view.addSubview(probe)
                    NSLayoutConstraint.activate([
                        probe.topAnchor.constraint(equalTo: view.topAnchor),
                        probe.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                        probe.widthAnchor.constraint(equalToConstant: 1),
                        probe.heightAnchor.constraint(equalToConstant: 1),
                    ])
                }
            }
        #endif
    }

    private func activateTerminal() {
        view.window?.makeFirstResponder(terminalView)
        shellSession.start()
    }
}

#if DEBUG
    /// UI tests read the shell's viewport through this element's value; it
    /// draws nothing and takes no clicks.
    private final class TerminalOutputAccessibilityView: NSView {
        private let session: InMemoryTerminalSession

        init(session: InMemoryTerminalSession) {
            self.session = session
            super.init(frame: .zero)
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityIdentifier("terminal.output")
            setAccessibilityLabel("Terminal Output")
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func accessibilityValue() -> Any? {
            session.readViewportText()
        }
    }

    /// UI tests read the cell size and padding, in points, through this
    /// element's value (`cell=W,H padding=P`) to aim the pointer at a cell
    /// instead of at a fraction of the view, whose row moves with the
    /// window's height.
    private final class TerminalGridAccessibilityView: NSView {
        static let padding = 2
        var cellSize: CGSize?

        init() {
            super.init(frame: .zero)
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityIdentifier("terminal.grid")
            setAccessibilityLabel("Terminal Grid")
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func accessibilityValue() -> Any? {
            guard let cellSize else { return "" }
            return "cell=\(cellSize.width),\(cellSize.height) padding=\(Self.padding)"
        }
    }
#endif

// MARK: - Terminal Callbacks

extension ViewController:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceGridResizeDelegate
{
    func terminalDidResize(_ size: TerminalGridMetrics) {
        #if DEBUG
            let scale = view.window?.backingScaleFactor ?? 1
            gridAccessibility?.cellSize = CGSize(
                width: CGFloat(size.cellWidthPixels) / scale,
                height: CGFloat(size.cellHeightPixels) / scale,
            )
        #endif
    }

    func terminalDidChangeTitle(_ title: String) {
        view.window?.title = title
    }

    func terminalDidClose(processAlive _: Bool) {
        view.window?.close()
    }
}
