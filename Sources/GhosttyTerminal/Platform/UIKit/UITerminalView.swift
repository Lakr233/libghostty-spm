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
    public final class UITerminalView: UIView {
        let core = TerminalSurfaceCoordinator()
        var momentumDisplayLink: CADisplayLink?
        var momentumVelocity: CGPoint = .zero
        #if !targetEnvironment(macCatalyst)
            static let minFontSize: Float = 4
            static let maxFontSize: Float = 64
        #endif
        #if targetEnvironment(macCatalyst)
            var activePointerButton: ghostty_input_mouse_button_e?
        #endif
        var hardwareKeyHandled = false
        let touchScrollMultiplier: CGFloat = 3.0
        #if !targetEnvironment(macCatalyst)
            var currentFontSize: Float = 14
            var lastPinchScale: CGFloat = 1.0
        #endif
        lazy var inputHandler = TerminalTextInputHandler(view: self)
        weak var _inputDelegate: (any UITextInputDelegate)?

        public weak var delegate: (any TerminalSurfaceViewDelegate)? {
            get { core.delegate }
            set { core.delegate = newValue }
        }

        public var controller: TerminalController? {
            get { core.controller }
            set { core.controller = newValue }
        }

        public var configuration: TerminalSurfaceOptions {
            get { core.configuration }
            set { core.configuration = newValue }
        }

        var surface: TerminalSurface? {
            core.surface
        }

        public var hasText: Bool {
            true
        }

        override public var canBecomeFirstResponder: Bool {
            true
        }

        override public init(frame: CGRect) {
            super.init(frame: frame)
            commonInit()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
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

            setupPlatformInput()
        }

        func refreshTextInputGeometry(reason: String) {
            guard isFirstResponder || inputHandler.hasMarkedText else { return }
            TerminalDebugLog.log(.ime, "refresh text geometry reason=\(reason)")
            inputHandler.notifyGeometryDidChange(reason: reason)
        }
    }
#endif
