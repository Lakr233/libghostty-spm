#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    @MainActor
    public final class UIKitTerminalView: UIView, UIKeyInput {
        let core = TerminalCore()

        // MARK: - Public API

        public weak var delegate: (any TerminalViewDelegate)? {
            get { core.delegate }
            set { core.delegate = newValue }
        }

        public var controller: TerminalController? {
            get { core.controller }
            set { core.controller = newValue }
        }

        public var configuration: TerminalSurfaceConfiguration {
            get { core.configuration }
            set { core.configuration = newValue }
        }

        var surface: Surface? {
            core.surface
        }

        // MARK: - UIKeyInput

        public var hasText: Bool {
            true
        }

        override public var canBecomeFirstResponder: Bool {
            true
        }

        // MARK: - Initializers

        override public init(frame: CGRect) {
            super.init(frame: frame)
            commonInit()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func commonInit() {
            backgroundColor = .black
            isUserInteractionEnabled = true

            core.isAttached = { [weak self] in self?.window != nil }
            core.scaleFactor = { [weak self] in
                Double(self?.contentScaleFactor ?? 2.0)
            }
            core.viewSize = { [weak self] in
                guard let self else { return (0, 0) }
                return (bounds.width, bounds.height)
            }
            core.platformSetup = { [weak self] config in
                guard let self else { return }
                config.platform_tag = GHOSTTY_PLATFORM_IOS
                config.platform = ghostty_platform_u(
                    ios: ghostty_platform_ios_s(
                        uiview: Unmanaged.passUnretained(self).toOpaque()
                    )
                )
            }
        }

        // MARK: - Text Input

        public func insertText(_ text: String) {
            surface?.sendText(text)
        }

        public func deleteBackward() {
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = GHOSTTY_ACTION_PRESS
            keyEvent.mods = ghostty_input_mods_e(rawValue: 0)
            keyEvent.keycode = UInt32(GHOSTTY_KEY_BACKSPACE.rawValue)
            keyEvent.text = nil
            keyEvent.composing = false
            surface?.sendKeyEvent(keyEvent)
        }

        // MARK: - Hardware Keyboard

        override public func pressesBegan(
            _ presses: Set<UIPress>,
            with _: UIPressesEvent?
        ) {
            for press in presses {
                guard let key = press.key else { continue }
                handleKeyPress(key, action: GHOSTTY_ACTION_PRESS)
            }
        }

        override public func pressesEnded(
            _ presses: Set<UIPress>,
            with _: UIPressesEvent?
        ) {
            for press in presses {
                guard let key = press.key else { continue }
                handleKeyPress(key, action: GHOSTTY_ACTION_RELEASE)
            }
        }

        private func handleKeyPress(
            _ key: UIKey,
            action: ghostty_input_action_e
        ) {
            let ghosttyKey = InputKey.from(key.keyCode)
            let mods = InputModifiers(from: key.modifierFlags)

            var keyEvent = ghostty_input_key_s()
            keyEvent.action = action
            keyEvent.mods = mods.ghosttyMods
            keyEvent.keycode = UInt32(ghosttyKey.rawValue)
            keyEvent.composing = false

            if action == GHOSTTY_ACTION_PRESS || action == GHOSTTY_ACTION_REPEAT {
                let chars = key.characters
                if !chars.isEmpty {
                    chars.withCString { ptr in
                        keyEvent.text = ptr
                        surface?.sendKeyEvent(keyEvent)
                    }
                    return
                }
            }

            surface?.sendKeyEvent(keyEvent)
        }

        // MARK: - Touch Handling

        override public func touchesBegan(
            _ touches: Set<UITouch>,
            with event: UIEvent?
        ) {
            super.touchesBegan(touches, with: event)
            becomeFirstResponder()
        }

        // MARK: - View Lifecycle

        override public func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                core.rebuildIfReady()
                core.synchronizeMetrics()
                core.startDisplayLink()
            } else {
                core.stopDisplayLink()
                core.setFocus(false)
            }
        }

        override public func layoutSubviews() {
            super.layoutSubviews()
            core.synchronizeMetrics()
        }

        public func fitToSize() {
            core.fitToSize()
        }

        // MARK: - Color Scheme

        override public func traitCollectionDidChange(
            _ previousTraitCollection: UITraitCollection?
        ) {
            super.traitCollectionDidChange(previousTraitCollection)
            guard traitCollection.hasDifferentColorAppearance(
                comparedTo: previousTraitCollection
            ) else { return }

            let scheme: ghostty_color_scheme_e =
                traitCollection.userInterfaceStyle == .dark
                    ? GHOSTTY_COLOR_SCHEME_DARK
                    : GHOSTTY_COLOR_SCHEME_LIGHT
            surface?.setColorScheme(scheme)
        }

        // MARK: - First Responder

        @discardableResult
        override public func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            core.setFocus(true)
            return result
        }

        @discardableResult
        override public func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            core.setFocus(false)
            return result
        }
    }
#endif
