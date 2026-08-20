//
//  UITerminalView.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    @MainActor
    open class UITerminalView: UIView {
        let core = TerminalSurfaceCoordinator()

        // Grouped view state, one struct per concern. Each type is defined
        // in the extension that owns the behavior (+Keyboard, +Interaction,
        // +PinchZoom); the storage lives here because extensions cannot add
        // stored properties.
        var hardwareKeyboard = HardwareKeyboardState()
        var pointer = PointerInteractionState()
        var momentumScroll = MomentumScrollState()
        #if !targetEnvironment(macCatalyst)
            var softwareKeyboard = SoftwareKeyboardState()
            var fontZoom = FontZoomState()
            static let minFontSize: Float = 4
            static let maxFontSize: Float = 64
        #endif

        lazy var selectionContextMenuInteraction = UIContextMenuInteraction(delegate: self)
        let touchScrollMultiplier: CGFloat = 3.0
        lazy var inputHandler = TerminalTextInputHandler(view: self)
        weak var _inputDelegate: (any UITextInputDelegate)?
        var onFocusChange: ((Bool) -> Void)?
        /// Fires when the view lands in a window. The SwiftUI focus bridge
        /// needs it: a focus request that arrives before the window exists
        /// cannot become first responder and would otherwise be dropped —
        /// the launch-time case, where the surface is created and focused in
        /// the same transaction.
        var onWindowAttach: (() -> Void)?

        #if !targetEnvironment(macCatalyst)
            lazy var terminalInputAccessory = TerminalInputAccessoryView(terminalView: self)
            let stickyModifiers = TerminalStickyModifierState()
        #endif

        #if !targetEnvironment(macCatalyst)
            open var inputAccessoryStyle: TerminalInputAccessoryStyle {
                get { terminalInputAccessory.style }
                set { terminalInputAccessory.style = newValue }
            }

            open var inputAccessoryItems: [TerminalInputAccessoryItem] = TerminalInputAccessoryItem.defaultItems {
                didSet {
                    terminalInputAccessory.rebuildContent()
                    reloadInputViews()
                }
            }
        #endif

        open weak var delegate: (any TerminalSurfaceViewDelegate)? {
            get { core.delegate }
            set { core.delegate = newValue }
        }

        open var controller: TerminalController? {
            get { core.controller }
            set { core.controller = newValue }
        }

        open var configuration: TerminalSurfaceOptions {
            get { core.configuration }
            set { core.configuration = newValue }
        }

        var surface: TerminalSurface? {
            core.surface
        }

        open var hasText: Bool {
            true
        }

        override open var canBecomeFirstResponder: Bool {
            true
        }

        override public init(frame: CGRect) {
            super.init(frame: frame)
            commonInit()
        }

        @available(*, unavailable)
        public required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func commonInit() {
            backgroundColor = .clear
            isOpaque = false
            isUserInteractionEnabled = true
            updateDisplayScale()

            core.isAttached = { [weak self] in self?.window != nil }
            core.scaleFactor = { [weak self] in
                Double(self?.resolvedDisplayScale() ?? UIScreen.main.nativeScale)
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
            core.onMetricsUpdate = { [weak self] in
                self?.updateSublayerFrames()
            }
            core.onCellSizeDidChange = { [weak self] in
                self?.refreshTextInputGeometry(reason: "cell-size-action")
            }
            core.onPostRender = { [weak self] in
                self?.enforceSublayerScale()
            }

            setupApplicationLifecycleObservers()
            syncApplicationActiveState()
            setupPlatformInput()
            #if !targetEnvironment(macCatalyst)
                setupKeyboardObservers()
            #endif
        }

        open func selectionMenuPoint(at point: CGPoint) -> CGPoint? {
            logPointerSelectionDiagnostics(
                context: "selectionMenuPoint",
                point: point
            )
            if let rect = pointer.lastSelectionRect {
                let pointIsInsidePointerSelection = rect.insetBy(dx: -4, dy: -4).contains(point)
                guard pointIsInsidePointerSelection else {
                    TerminalDebugLog.log(
                        .input,
                        "selection menu miss point=\(NSCoder.string(for: point)) outside pointer selection"
                    )
                    return nil
                }
                guard surface?.hasSelection() == true else {
                    TerminalDebugLog.log(
                        .input,
                        "selection menu miss point=\(NSCoder.string(for: point)) inside pointer selection without active selection"
                    )
                    return nil
                }
                TerminalDebugLog.log(
                    .input,
                    "selection menu hit point=\(NSCoder.string(for: point)) inside pointer selection"
                )
                return point
            }

            guard surface?.hasSelection() == true else {
                TerminalDebugLog.log(
                    .input,
                    "selection menu miss point=\(NSCoder.string(for: point))"
                )
                return nil
            }

            guard surface?.selectionContainsQuicklookWord() == true else {
                TerminalDebugLog.log(
                    .input,
                    "selection menu miss point=\(NSCoder.string(for: point)) outside quicklook word"
                )
                return nil
            }

            TerminalDebugLog.log(
                .input,
                "selection menu hit point=\(NSCoder.string(for: point))"
            )
            return point
        }

        open func showSelectionCopyMenu(at point: CGPoint) {
            becomeFirstResponder()
            let menu = UIMenuController.shared
            menu.menuItems = nil
            menu.showMenu(
                from: self,
                rect: CGRect(x: point.x, y: point.y, width: 1, height: 1)
            )
            menu.update()
        }

        @discardableResult
        open func copySelectedTextToPasteboard() -> Bool {
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                    accessibilityValue = nil
                }
            #endif
            guard let text = surface?.readSelection(), !text.isEmpty else {
                return false
            }
            UIPasteboard.general.string = text
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                    accessibilityValue = text
                }
            #endif
            TerminalDebugLog.log(
                .input,
                "selection copied bytes=\(text.utf8.count) lines=\(TerminalInputText.lineCount(in: text))"
            )
            return true
        }

        open func selectionContextMenuConfiguration(
            at _: CGPoint
        ) -> UIContextMenuConfiguration {
            UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(children: self?.selectionContextMenuElements() ?? [])
            }
        }

        open func selectionContextMenuElements() -> [UIMenuElement] {
            let copy = UIAction(
                title: "Copy",
                image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in
                self?.copySelectedTextToPasteboard()
            }
            return [copy]
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        #if !targetEnvironment(macCatalyst)
            func setupKeyboardObservers() {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(keyboardDidShow),
                    name: UIResponder.keyboardDidShowNotification,
                    object: nil
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(keyboardDidHide),
                    name: UIResponder.keyboardDidHideNotification,
                    object: nil
                )
            }

            @objc func keyboardDidShow(_ notification: Notification) {
                guard isFirstResponder else { return }
                softwareKeyboard.isVisible = isSoftwareKeyboardNotification(notification)
            }

            /// A hardware keyboard posts keyboardDidShow too — for the
            /// accessory bar alone. Believing it means the next tap on the
            /// terminal runs the tap-to-dismiss path and resigns first
            /// responder, killing all hardware input. Only a frame tall
            /// enough to hold actual keys counts as the software keyboard.
            private func isSoftwareKeyboardNotification(
                _ notification: Notification
            ) -> Bool {
                guard
                    let value = notification
                        .userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
                else { return true }
                let screenBounds = window?.screen.bounds ?? UIScreen.main.bounds
                let visibleHeight = value.cgRectValue
                    .intersection(screenBounds).height
                return visibleHeight > terminalInputAccessory.bounds.height + 44
            }

            @objc func keyboardDidHide(_: Notification) {
                softwareKeyboard.isVisible = false
            }
        #endif

        func refreshTextInputGeometry(reason: String) {
            guard isFirstResponder || inputHandler.hasMarkedText else { return }
            TerminalDebugLog.log(.ime, "refresh text geometry reason=\(reason)")
            inputHandler.notifyGeometryDidChange(reason: reason)
        }

        func refreshInputAccessoryContent() {
            #if !targetEnvironment(macCatalyst)
                terminalInputAccessory.refreshContent()
            #endif
        }
    }
#endif
