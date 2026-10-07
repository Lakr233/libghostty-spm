import GhosttyTerminal
import GhosttyTheme
import ShellCraftKit
import UIKit

final class ViewController: UIViewController {
    private static let lightThemeKey = "SelectedTheme.light"
    private static let darkThemeKey = "SelectedTheme.dark"

    private lazy var terminalView = MobileExampleTerminalView(frame: .zero)
    private lazy var shellSession: ShellSession = .init(shell: defaultSandboxShell)
    private var isKeyboardVisible = false
    private lazy var controller: TerminalController = .init(
        theme: Self.savedTerminalTheme(),
    ) { builder in
        builder.withBackgroundOpacity(0)
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                builder.withWindowPaddingX(TerminalGridAccessibilityView.padding)
                builder.withWindowPaddingY(TerminalGridAccessibilityView.padding)
                builder.withCustom("window-padding-balance", "false")
            }
        #endif
    }

    #if DEBUG
        private var gridAccessibility: TerminalGridAccessibilityView?
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Terminal"
        view.isOpaque = true
        configureTerminalView()
        configureThemeMenu()
        applyBackgroundForCurrentAppearance()
        observeSoftwareKeyboard()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        activateTerminal()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        terminalView.fitToSize()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else {
            return
        }
        controller.setTheme(Self.savedTerminalTheme())
        applyBackgroundForCurrentAppearance()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: any UIViewControllerTransitionCoordinator,
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate { [weak self] _ in
            self?.updateNavigationBarVisibility(animated: false)
        }
    }

    private func configureTerminalView() {
        terminalView.delegate = self
        terminalView.usesInlineTextSelection = !ProcessInfo.processInfo.arguments.contains("--no-inline-selection")
        terminalView.isAccessibilityElement = true
        terminalView.accessibilityIdentifier = "terminal.surface"
        terminalView.accessibilityLabel = "Terminal"
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .inMemory(shellSession.terminalSession),
        )
        terminalView.controller = controller
        terminalView.backgroundColor = .clear
        terminalView.isOpaque = false
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            // The safe area, not the view edges: in landscape the sensor
            // housing and the rounded corners sit over the first and last
            // columns. The view's background fills the margins.
            terminalView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                UIPasteboard.general.items = []
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-pasteboard") {
                UIPasteboard.general.string = "paste fixture"
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-touch-menu") {
                UIPasteboard.general.items = []
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                let output = TerminalOutputAccessibilityView(
                    session: shellSession.terminalSession,
                )
                let menus = UILabel(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
                menus.isAccessibilityElement = true
                menus.accessibilityIdentifier = "terminal.systemMenus"
                menus.accessibilityLabel = "System Menus"
                menus.accessibilityValue = "pending"
                menus.alpha = 0.01
                view.addSubview(menus)
                terminalView.onSystemMenuItems = { [weak menus, weak terminalView] items in
                    @MainActor
                    func availableActions(in elements: [UIMenuElement]) -> [String] {
                        elements.flatMap { element -> [String] in
                            if let menu = element as? UIMenu {
                                return availableActions(in: menu.children)
                            }
                            if let action = element as? UIAction,
                               action.attributes.isDisjoint(with: [.hidden, .disabled])
                            {
                                return [action.title]
                            }
                            if let command = element as? UICommand,
                               command.attributes.isDisjoint(with: [.hidden, .disabled]),
                               terminalView?.canPerformAction(command.action, withSender: command) == true
                            {
                                return [command.title]
                            }
                            return []
                        }
                    }
                    let actions = availableActions(in: items)
                    menus?.accessibilityValue = String(actions.count)
                    menus?.accessibilityLabel = actions.joined(separator: ", ")
                }
                let grid = TerminalGridAccessibilityView()
                gridAccessibility = grid
                grid.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(grid)
                output.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(output)
                NSLayoutConstraint.activate([
                    output.topAnchor.constraint(equalTo: view.topAnchor),
                    output.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    output.widthAnchor.constraint(equalToConstant: 1),
                    output.heightAnchor.constraint(equalToConstant: 1),
                    grid.topAnchor.constraint(equalTo: view.topAnchor),
                    grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    grid.widthAnchor.constraint(equalToConstant: 1),
                    grid.heightAnchor.constraint(equalToConstant: 1),
                ])
            }
        #endif
    }

    // MARK: - Compact Height

    /// A landscape iPhone with the keyboard and the accessory bar up leaves
    /// one terminal row under the navigation bar, so the bar steps aside
    /// while the keyboard is up there and comes back with the theme menu
    /// when a tap on the terminal puts the keyboard away.
    private func observeSoftwareKeyboard() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(keyboardWillShow),
            name: UIResponder.keyboardWillShowNotification,
            object: nil,
        )
        center.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil,
        )
    }

    @objc private func keyboardWillShow() {
        isKeyboardVisible = true
        updateNavigationBarVisibility(animated: true)
    }

    @objc private func keyboardWillHide() {
        isKeyboardVisible = false
        updateNavigationBarVisibility(animated: true)
    }

    private func updateNavigationBarVisibility(animated: Bool) {
        guard let navigationController else { return }
        let hidden = isKeyboardVisible && view.window?.traitCollection.verticalSizeClass == .compact
        guard navigationController.isNavigationBarHidden != hidden else { return }
        navigationController.setNavigationBarHidden(hidden, animated: animated)
    }

    private func activateTerminal() {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-hidden-selection") {
                var text = "\u{1B}[2J\u{1B}[H" + String(repeating: "touch-copy-ready\r\n", count: 80)
                if ProcessInfo.processInfo.arguments.contains("--ui-testing-mouse-capture") {
                    text += "\u{1B}[?1000h\u{1B}[?1006h"
                }
                shellSession.terminalSession.receive(text)
                return
            }
        #endif
        terminalView.becomeFirstResponder()
        shellSession.start()
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-copy-fixture") {
                shellSession.terminalSession.sendInput(Data("clear\recho touch-copy-ready\r".utf8))
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-history-fixture") {
                let commands = (0 ..< 45).map { String(format: "echo history-%03d left middle right\r", $0) }
                shellSession.terminalSession.sendInput(Data(("clear\r" + commands.joined()).utf8))
            }
        #endif
    }

    // MARK: - Persistence

    private static func savedTerminalTheme() -> TerminalTheme {
        let lightConfig = savedThemeDefinition(forKey: lightThemeKey)?
            .toTerminalConfiguration() ?? .alabaster
        let darkConfig = savedThemeDefinition(forKey: darkThemeKey)?
            .toTerminalConfiguration() ?? .afterglow
        return TerminalTheme(light: lightConfig, dark: darkConfig)
    }

    private static func savedThemeDefinition(
        forKey key: String,
    ) -> GhosttyThemeDefinition? {
        guard let name = UserDefaults.standard.string(forKey: key) else {
            return nil
        }
        return GhosttyThemeCatalog.theme(named: name)
    }

    private var isDarkMode: Bool {
        traitCollection.userInterfaceStyle == .dark
    }

    private func saveTheme(_ theme: GhosttyThemeDefinition) {
        let key = isDarkMode ? Self.darkThemeKey : Self.lightThemeKey
        UserDefaults.standard.set(theme.name, forKey: key)
    }

    private func applyBackgroundForCurrentAppearance() {
        let key = isDarkMode ? Self.darkThemeKey : Self.lightThemeKey
        // Backgrounds of the `.afterglow` / `.alabaster` fallbacks in savedTerminalTheme().
        let defaultBackground = isDarkMode ? "212121" : "F7F7F7"
        // Foregrounds of the same fallbacks.
        let defaultForeground = isDarkMode ? "D0D0D0" : "000000"
        let theme = Self.savedThemeDefinition(forKey: key)
        if let bgColor = UIColor(hexString: theme?.background ?? defaultBackground) {
            view.backgroundColor = bgColor
        }
        // A dark theme picked in light mode (or the reverse) puts the
        // system-colored title on a background of the opposite shade, so
        // the bar takes the theme's foreground instead.
        let foreground = UIColor(hexString: theme?.foreground ?? defaultForeground) ?? .label
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.titleTextAttributes = [.foregroundColor: foreground]
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance
        navigationItem.rightBarButtonItem?.tintColor = foreground
    }

    // MARK: - Theme Menu

    private func configureThemeMenu() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "paintpalette"),
            menu: buildThemeMenu(),
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "terminal.themeButton"
    }

    private func buildThemeMenu() -> UIMenu {
        let popular = buildSubmenu(
            title: "Popular",
            themes: [
                "Dracula", "Catppuccin Mocha", "Catppuccin Latte",
                "Nord", "Solarized Dark", "Solarized Light",
                "Gruvbox Dark", "Gruvbox Light", "Tokyo Night",
                "One Half Dark", "One Half Light", "Rose Pine",
                "Monokai Pro", "GitHub Dark", "GitHub Light",
            ],
        )

        let dark = UIMenu(
            title: "Dark",
            image: UIImage(systemName: "moon.fill"),
            children: alphabeticalSubmenus(
                themes: GhosttyThemeCatalog.allThemes.filter(\.isDark),
            ),
        )

        let light = UIMenu(
            title: "Light",
            image: UIImage(systemName: "sun.max.fill"),
            children: alphabeticalSubmenus(
                themes: GhosttyThemeCatalog.allThemes.filter { !$0.isDark },
            ),
        )

        return UIMenu(title: "Theme", children: [popular, dark, light])
    }

    private func buildSubmenu(
        title: String,
        themes names: [String],
    ) -> UIMenu {
        let actions = names.compactMap { name -> UIAction? in
            guard let theme = GhosttyThemeCatalog.theme(named: name) else {
                return nil
            }
            return themeAction(for: theme)
        }
        return UIMenu(
            title: title,
            image: UIImage(systemName: "star.fill"),
            children: actions,
        )
    }

    private func alphabeticalSubmenus(
        themes: [GhosttyThemeDefinition],
    ) -> [UIMenu] {
        var grouped: [String: [GhosttyThemeDefinition]] = [:]
        for theme in themes {
            let letter = String(theme.name.prefix(1)).uppercased()
            let key = letter.first?.isLetter == true ? letter : "#"
            grouped[key, default: []].append(theme)
        }

        return grouped.sorted { $0.key < $1.key }.map { key, themes in
            UIMenu(
                title: key,
                children: themes.map { themeAction(for: $0) },
            )
        }
    }

    private func themeAction(for theme: GhosttyThemeDefinition) -> UIAction {
        UIAction(title: theme.name) { [weak self] _ in
            self?.applyTheme(theme)
        }
    }

    private func applyTheme(_ theme: GhosttyThemeDefinition) {
        saveTheme(theme)
        controller.setTheme(Self.savedTerminalTheme())
        applyBackgroundForCurrentAppearance()
    }
}

#if DEBUG
    private final class TerminalGridAccessibilityView: UIView {
        static let padding = 2
        var cellSize: CGSize?

        init() {
            super.init(frame: .zero)
            isAccessibilityElement = true
            accessibilityTraits = .staticText
            accessibilityIdentifier = "terminal.grid"
            accessibilityLabel = "Terminal Grid"
            isUserInteractionEnabled = false
            alpha = 0.01
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var accessibilityValue: String? {
            get {
                guard let cellSize else { return "" }
                return "cell=\(cellSize.width),\(cellSize.height) padding=\(Self.padding)"
            }
            set {}
        }
    }

    private final class TerminalOutputAccessibilityView: UIView {
        private let session: InMemoryTerminalSession

        init(session: InMemoryTerminalSession) {
            self.session = session
            super.init(frame: .zero)
            isAccessibilityElement = true
            accessibilityIdentifier = "terminal.output"
            accessibilityLabel = "Terminal Output"
            isUserInteractionEnabled = false
            alpha = 0.01
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var accessibilityValue: String? {
            get { session.readViewportText() }
            set {}
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
            let scale = terminalView.traitCollection.displayScale
            gridAccessibility?.cellSize = CGSize(
                width: CGFloat(size.cellWidthPixels) / scale,
                height: CGFloat(size.cellHeightPixels) / scale,
            )
        #endif
    }

    func terminalDidChangeTitle(_ title: String) {
        self.title = title
    }

    func terminalDidClose(processAlive _: Bool) {
        ApplicationExitController.requestExit()
    }
}

// MARK: - UIColor Hex

private extension UIColor {
    convenience init?(hexString: String) {
        let hex = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard hex.count == 6,
              let r = UInt8(hex.prefix(2), radix: 16),
              let g = UInt8(hex.dropFirst(2).prefix(2), radix: 16),
              let b = UInt8(hex.dropFirst(4).prefix(2), radix: 16)
        else { return nil }
        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1,
        )
    }
}

/// Demonstrates the independent subclass hooks without changing the default menu.
private final class MobileExampleTerminalView: TerminalView {
    #if DEBUG
        var onSystemMenuItems: (([UIMenuElement]) -> Void)?

        private var showsTestMenuItems: Bool {
            ProcessInfo.processInfo.arguments.contains("--ui-testing-touch-menu")
                || ProcessInfo.processInfo.arguments.contains("--ui-testing-host-menu")
        }
    #endif

    override func touchMenuItems(for context: TerminalTouchMenuContext) -> [UIMenuElement] {
        var items = super.touchMenuItems(for: context)
        #if DEBUG
            onSystemMenuItems?(context.systemMenuItems)
            if showsTestMenuItems {
                items.append(UIAction(title: "Host Action") { [weak self] _ in
                    self?.accessibilityValue = "host:none"
                })
            }
        #endif
        return items
    }

    override func touchSelectionMenuItems(for context: TerminalTouchSelectionMenuContext) -> [UIMenuElement] {
        var items = super.touchSelectionMenuItems(for: context)
        #if DEBUG
            onSystemMenuItems?(context.systemMenuItems)
            #if !targetEnvironment(macCatalyst)
                if ProcessInfo.processInfo.arguments.contains("--ui-testing-key-commands") {
                    for (title, input, modifiers) in [
                        ("Send Control A", "a", UIKeyModifierFlags.control),
                        ("Send Escape", UIKeyCommand.inputEscape, UIKeyModifierFlags()),
                    ] {
                        items.append(UIAction(title: title) { [weak self] _ in
                            guard let self, let command = keyCommands?.first(where: {
                                $0.input == input && $0.modifierFlags == modifiers
                            }), let action = command.action else { return }
                            UIApplication.shared.sendAction(action, to: self, from: command, for: nil)
                        })
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--ui-testing-public-copy") {
                    items.insert(UIAction(title: "Send Key") { [weak self] _ in
                        guard let self else { return }
                        UIPasteboard.general.items = []
                        accessibilityValue = nil
                        if ProcessInfo.processInfo.arguments.contains("--ui-testing-sticky-copy") {
                            toggleStickyModifier(.command)
                            _ = sendKey(.c)
                        } else {
                            _ = sendKey(.c, modifiers: .super_)
                        }
                    }, at: 0)
                }
            #endif
            if showsTestMenuItems {
                items.append(UIAction(title: "Inspect Selection") { [weak self] _ in
                    self?.accessibilityValue = "host:" + context.selectedText
                })
            }
        #endif
        return items
    }
}
