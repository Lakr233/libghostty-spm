#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    @MainActor
    public final class AppKitTerminalView: NSView {
        let core = TerminalCore()
        private var metalLayer: CAMetalLayer?
        private var inputHandler: InputHandler?

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

        // MARK: - Initializers

        override public init(frame: NSRect) {
            super.init(frame: frame)
            commonInit()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func commonInit() {
            wantsLayer = true

            let metal = CAMetalLayer()
            metal.device = MTLCreateSystemDefaultDevice()
            metal.pixelFormat = .bgra8Unorm
            metal.framebufferOnly = true
            metal.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            layer = metal
            metalLayer = metal

            inputHandler = InputHandler(view: self)
            setupTrackingArea()

            core.isAttached = { [weak self] in self?.window != nil }
            core.scaleFactor = { [weak self] in
                Double(
                    self?.window?.backingScaleFactor
                        ?? NSScreen.main?.backingScaleFactor ?? 2.0
                )
            }
            core.viewSize = { [weak self] in
                guard let self else { return (0, 0) }
                return (bounds.width, bounds.height)
            }
            core.platformSetup = { [weak self] config in
                guard let self else { return }
                config.platform_tag = GHOSTTY_PLATFORM_MACOS
                config.platform = ghostty_platform_u(
                    macos: ghostty_platform_macos_s(
                        nsview: Unmanaged.passUnretained(self).toOpaque()
                    )
                )
            }
            core.onMetricsUpdate = { [weak self] in
                self?.updateMetalLayerMetrics()
            }
        }

        // MARK: - Tracking Area

        private func setupTrackingArea() {
            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ]
            let area = NSTrackingArea(
                rect: bounds,
                options: options,
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
        }

        override public func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            setupTrackingArea()
        }

        // MARK: - First Responder

        override public var acceptsFirstResponder: Bool {
            true
        }

        override public func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            core.setFocus(true)
            return result
        }

        override public func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            core.setFocus(false)
            return result
        }

        // MARK: - Key Events

        override public func keyDown(with event: NSEvent) {
            inputHandler?.handleKeyDown(with: event)
        }

        override public func keyUp(with event: NSEvent) {
            inputHandler?.handleKeyUp(with: event)
        }

        override public func flagsChanged(with event: NSEvent) {
            inputHandler?.handleFlagsChanged(with: event)
        }

        override public func doCommand(by _: Selector) {
            // Suppress NSBeep for unhandled commands — terminal handles all input
        }

        // MARK: - Mouse Events

        private func mousePoint(from event: NSEvent) -> (x: CGFloat, y: CGFloat) {
            let point = convert(event.locationInWindow, from: nil)
            return (point.x, bounds.height - point.y)
        }

        override public func mouseDown(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = InputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_LEFT,
                mods: mods.ghosttyMods
            )
        }

        override public func mouseUp(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = InputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_LEFT,
                mods: mods.ghosttyMods
            )
        }

        override public func rightMouseDown(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = InputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_RIGHT,
                mods: mods.ghosttyMods
            )
        }

        override public func rightMouseUp(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = InputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_RIGHT,
                mods: mods.ghosttyMods
            )
        }

        override public func otherMouseDown(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = InputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_MIDDLE,
                mods: mods.ghosttyMods
            )
        }

        override public func otherMouseUp(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = InputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_MIDDLE,
                mods: mods.ghosttyMods
            )
        }

        override public func mouseMoved(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = InputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
        }

        override public func mouseDragged(with event: NSEvent) {
            mouseMoved(with: event)
        }

        override public func rightMouseDragged(with event: NSEvent) {
            mouseMoved(with: event)
        }

        override public func otherMouseDragged(with event: NSEvent) {
            mouseMoved(with: event)
        }

        override public func scrollWheel(with event: NSEvent) {
            let scrollMods = ScrollModifiers(
                precision: event.hasPreciseScrollingDeltas,
                momentum: ScrollModifiers.momentumFrom(phase: event.momentumPhase)
            )
            surface?.sendMouseScroll(
                x: event.scrollingDeltaX,
                y: event.scrollingDeltaY,
                mods: scrollMods.rawValue
            )
        }

        // MARK: - Window Lifecycle

        override public func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                core.rebuildIfReady()
                core.startDisplayLink()

                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidBecomeKey),
                    name: NSWindow.didBecomeKeyNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidResignKey),
                    name: NSWindow.didResignKeyNotification,
                    object: window
                )
            } else {
                core.stopDisplayLink()
                NotificationCenter.default.removeObserver(self)
            }
        }

        @objc private func windowDidBecomeKey(_: Notification) {
            let focused = window?.isKeyWindow == true
                && window?.firstResponder === self
            core.setFocus(focused)
        }

        @objc private func windowDidResignKey(_: Notification) {
            core.setFocus(false)
        }

        // MARK: - Layout

        override public func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            core.synchronizeMetrics()
        }

        override public func layout() {
            super.layout()
            core.synchronizeMetrics()
        }

        override public func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateMetalLayerMetrics()
            core.synchronizeMetrics()
        }

        public func fitToSize() {
            core.fitToSize()
        }

        private func updateMetalLayerMetrics() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = core.scaleFactor()
            metalLayer?.contentsScale = scale
            metalLayer?.drawableSize = CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )
        }

        // MARK: - Color Scheme

        override public func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            let scheme: ghostty_color_scheme_e = switch effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua:
                GHOSTTY_COLOR_SCHEME_DARK
            default:
                GHOSTTY_COLOR_SCHEME_LIGHT
            }
            surface?.setColorScheme(scheme)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }

    // MARK: - NSTextInputClient

    extension AppKitTerminalView: @preconcurrency NSTextInputClient {
        public func insertText(_ string: Any, replacementRange _: NSRange) {
            inputHandler?.inputMethodHandler?.insertText(string)
        }

        public func setMarkedText(
            _ string: Any,
            selectedRange: NSRange,
            replacementRange _: NSRange
        ) {
            inputHandler?.inputMethodHandler?.setMarkedText(
                string,
                selectedRange: selectedRange
            )
        }

        public func unmarkText() {
            inputHandler?.inputMethodHandler?.unmarkText()
        }

        public func selectedRange() -> NSRange {
            NSRange(location: NSNotFound, length: 0)
        }

        public func markedRange() -> NSRange {
            inputHandler?.inputMethodHandler?.markedRange()
                ?? NSRange(location: NSNotFound, length: 0)
        }

        public func hasMarkedText() -> Bool {
            inputHandler?.inputMethodHandler?.hasMarkedText ?? false
        }

        public func attributedSubstring(
            forProposedRange _: NSRange,
            actualRange _: NSRangePointer?
        ) -> NSAttributedString? {
            nil
        }

        public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
            [.underlineStyle, .backgroundColor]
        }

        public func firstRect(
            forCharacterRange _: NSRange,
            actualRange _: NSRangePointer?
        ) -> NSRect {
            guard let surface else { return .zero }

            let point = surface.imePoint()
            let viewRect = NSRect(
                x: point.x,
                y: bounds.height - point.y - point.height,
                width: point.width,
                height: point.height
            )

            guard let window else { return viewRect }
            let windowRect = convert(viewRect, to: nil)
            return window.convertToScreen(windowRect)
        }

        public func characterIndex(for _: NSPoint) -> Int {
            NSNotFound
        }
    }
#endif
