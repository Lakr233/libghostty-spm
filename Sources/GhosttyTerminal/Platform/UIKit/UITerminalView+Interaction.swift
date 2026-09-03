//
//  UITerminalView+Interaction.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit
    #if targetEnvironment(macCatalyst)
        import AppKit
        import CoreGraphics
    #elseif canImport(GameController)
        import GameController
    #endif

    /// Mouse/trackpad interaction state; behavior lives in +Interaction.
    struct PointerInteractionState {
        var session = TerminalPointerButtonSession()
        var lastLocation: CGPoint?
        var hoverRecognizer: UIHoverGestureRecognizer?
        var selectionStartPoint: CGPoint?
        var lastSelectionRect: CGRect?
        var pendingSelectionMenuPoint: CGPoint?
        /// Capture sampled at the matching press. Nil when no button is down.
        var gestureCaptured: Bool?
        var panOwnsTouchSequence = false
        var suppressNextTouchEnd = false
        var mouseShape: TerminalMouseShape = .default

        var activeButton: ghostty_input_mouse_button_e? {
            session.reported
        }
    }

    /// A pan recognizer fed by wheel and trackpad scroll events alone.
    ///
    /// A scroll event is neither a touch nor a pointer drag: it reaches a
    /// pan recognizer only through `allowedScrollTypesMask`, and the touch
    /// recognizers never see it. Refusing every other event here keeps a
    /// finger on the touch-scroll recognizer and a pointer drag on the
    /// selection one without the view's delegate having to tell them apart.
    final class TerminalScrollWheelGestureRecognizer: UIPanGestureRecognizer {
        let precision: Bool

        init(target: Any?, action: Selector?, precision: Bool) {
            self.precision = precision
            super.init(target: target, action: action)
            allowedScrollTypesMask = precision ? [.continuous] : [.discrete]
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func shouldReceive(_ event: UIEvent) -> Bool {
            event.type == .scroll
        }
    }

    /// Touch-scroll momentum state; behavior lives in +Interaction.
    struct MomentumScrollState {
        var displayLink: CADisplayLink?
        var velocity: CGPoint = .zero
    }

    extension UITerminalView {
        static let touchScrollMultiplier: CGFloat = 3.0
        /// How far a finger may wander and still count as a tap.
        static let tapCandidateSlop: CGFloat = 10
        /// How long a press may last and still count as a tap. Below the
        /// long-press recognizer's 0.5s so a stationary hold never
        /// toggles the keyboard even when no selection delegate is
        /// installed and the recognizer itself refuses to begin.
        static let tapCandidateMaxDuration: TimeInterval = 0.35

        override open func touchesBegan(
            _ touches: Set<UITouch>,
            with event: UIEvent?
        ) {
            if handleIndirectPointerTouches(touches, phase: .began, event: event) {
                return
            }
            super.touchesBegan(touches, with: event)
            #if targetEnvironment(macCatalyst)
                becomeFirstResponder()
            #else
                if momentumScroll.displayLink != nil {
                    // A touch during momentum is a scroll-stop, not a tap.
                    stopMomentumScrolling()
                    softwareKeyboard.tapCandidateArmed = false
                } else if let touch = touches.first,
                          // View-scoped on purpose: `allTouches` spans the
                          // whole app, and a finger resting on host chrome
                          // (sidebar, tab bar) must not swallow a tap here.
                          (event?.touches(for: self)?.count ?? touches.count) == 1
                {
                    softwareKeyboard.tapCandidateArmed = true
                    softwareKeyboard.tapCandidateStart = touch.location(in: self)
                    softwareKeyboard.tapCandidateTimestamp = touch.timestamp
                } else {
                    // A second finger means pinch (or some other
                    // multi-touch gesture) — the sequence can no longer
                    // be a tap.
                    softwareKeyboard.tapCandidateArmed = false
                }
            #endif
        }

        override open func touchesMoved(
            _ touches: Set<UITouch>,
            with event: UIEvent?
        ) {
            if handleIndirectPointerTouches(touches, phase: .moved, event: event) {
                return
            }
            #if !targetEnvironment(macCatalyst)
                if softwareKeyboard.tapCandidateArmed, let touch = touches.first {
                    let point = touch.location(in: self)
                    let start = softwareKeyboard.tapCandidateStart
                    if hypot(point.x - start.x, point.y - start.y) > Self.tapCandidateSlop {
                        softwareKeyboard.tapCandidateArmed = false
                    }
                }
            #endif
            super.touchesMoved(touches, with: event)
        }

        override open func touchesEnded(
            _ touches: Set<UITouch>,
            with event: UIEvent?
        ) {
            if handleIndirectPointerTouches(touches, phase: .ended, event: event) {
                return
            }
            #if !targetEnvironment(macCatalyst)
                if softwareKeyboard.tapCandidateArmed, let touch = touches.first {
                    softwareKeyboard.tapCandidateArmed = false
                    let duration = touch.timestamp - softwareKeyboard.tapCandidateTimestamp
                    if duration <= Self.tapCandidateMaxDuration {
                        TerminalDebugLog.log(
                            .input,
                            "tap toggles keyboard visible=\(softwareKeyboard.isVisible) duration=\(String(format: "%.3f", duration))"
                        )
                        // The tap is a click first and a keyboard toggle
                        // second, in both directions: a TUI tracking the
                        // mouse gets its press before the resize the
                        // keyboard causes, and the shell sees the
                        // click-to-move at its prompt either way.
                        sendTapClick(at: touch.location(in: self))
                        // Overridable: a host keyboard lock overrides
                        // `toggleSoftwareKeyboard()` to swallow the toggle;
                        // the click above still lands either way.
                        toggleSoftwareKeyboard()
                    }
                }
            #endif
            super.touchesEnded(touches, with: event)
        }

        override open func touchesCancelled(
            _ touches: Set<UITouch>,
            with event: UIEvent?
        ) {
            if handleIndirectPointerTouches(touches, phase: .cancelled, event: event) {
                return
            }
            #if !targetEnvironment(macCatalyst)
                softwareKeyboard.tapCandidateArmed = false
            #endif
            super.touchesCancelled(touches, with: event)
        }

        func setupPlatformInput() {
            addInteraction(selectionContextMenuInteraction)
            setupDropInput()
            addGestureRecognizer(TerminalScrollWheelGestureRecognizer(
                target: self,
                action: #selector(handleScrollWheelGesture(_:)),
                precision: true
            ))
            addGestureRecognizer(TerminalScrollWheelGestureRecognizer(
                target: self,
                action: #selector(handleScrollWheelGesture(_:)),
                precision: false
            ))
            #if !targetEnvironment(macCatalyst)
                addInteraction(UIPointerInteraction(delegate: self))
            #endif
            let hover = UIHoverGestureRecognizer(
                target: self,
                action: #selector(handlePointerHover(_:))
            )
            hover.cancelsTouchesInView = false
            hover.delegate = self
            addGestureRecognizer(hover)
            pointer.hoverRecognizer = hover
            #if !targetEnvironment(macCatalyst)
                setupTouchScrollInput()
            #endif
        }

        @objc func handlePointerHover(_ gesture: UIHoverGestureRecognizer) {
            switch gesture.state {
            case .began, .changed:
                let point = gesture.location(in: self)
                pointer.lastLocation = point
                guard pointer.session.reported == nil else { return }
                sendPointerPosition(at: point, remember: false)
            default:
                break
            }
        }

        @objc func handleScrollWheelGesture(_ gesture: UIPanGestureRecognizer) {
            guard pointer.session.reported == nil else { return }
            switch gesture.state {
            case .began:
                stopMomentumScrolling()
            case .changed, .ended:
                // `.ended` still carries whatever moved since the last
                // `.changed`.
                break
            default:
                return
            }

            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            TerminalDebugLog.log(
                .input,
                "scroll wheel translation=\(String(format: "%.2f", translation.x))x\(String(format: "%.2f", translation.y))"
            )

            // Ghostty's scroll C API has no key mods. The last mouse_pos
            // carries them, so a wheel event can target the cell under the
            // pointer (tmux, vim). View points: Ghostty applies
            // content_scale internally.
            let point = pointer.lastLocation ?? gesture.location(in: self)
            sendPointerPosition(at: point, remember: pointer.lastLocation == nil)

            let precision =
                (gesture as? TerminalScrollWheelGestureRecognizer)?.precision ?? true
            let scrollMods = TerminalScrollModifiers(precision: precision)
            surface?.sendMouseScroll(
                x: Double(translation.x),
                y: Double(translation.y),
                mods: scrollMods.rawValue
            )
        }

        enum IndirectPointerPhase {
            case began
            case moved
            case ended
            case cancelled
        }

        func handleIndirectPointerTouches(
            _ touches: Set<UITouch>,
            phase: IndirectPointerPhase,
            event: UIEvent?
        ) -> Bool {
            let hasIndirectPointerTouch = touches.contains { $0.type == .indirectPointer }

            #if !targetEnvironment(macCatalyst)
                if pointer.suppressNextTouchEnd, hasIndirectPointerTouch {
                    if phase == .ended || phase == .cancelled {
                        pointer.suppressNextTouchEnd = false
                        return true
                    }
                    pointer.suppressNextTouchEnd = false
                }

                if pointer.panOwnsTouchSequence, hasIndirectPointerTouch {
                    if phase == .began {
                        pointer.panOwnsTouchSequence = false
                    } else {
                        return true
                    }
                }
            #endif

            guard hasIndirectPointerTouch,
                  let touch = touches.first(where: { $0.type == .indirectPointer })
            else {
                return false
            }

            core.setFocus(true)
            // A pointer click claims keyboard focus the way a finger tap
            // does — without this, clicking a terminal with a mouse or
            // trackpad never made it first responder and hardware keys kept
            // going to whatever held focus before.
            if phase == .began, !isFirstResponder {
                becomeFirstResponder()
            }
            stopMomentumScrolling()

            let button = pointerButton(from: event)
            let location = touch.location(in: self)
            TerminalDebugLog.log(
                .input,
                "pointer touch phase=\(phase) type=\(touch.type.rawValue) button=\(button.rawValue) location=\(NSCoder.string(for: location)) mask=\(event?.buttonMask.rawValue ?? 0)"
            )

            switch phase {
            case .began:
                if button == GHOSTTY_MOUSE_RIGHT,
                   TerminalPointerPolicy.shouldPresentHostSecondaryMenu(
                       mouseCaptured: surface?.isMouseCaptured == true
                   ),
                   let menuPoint = selectionMenuPoint(at: location)
                {
                    pointer.pendingSelectionMenuPoint = menuPoint
                    pointer.gestureCaptured = false
                    return true
                }

                pointer.pendingSelectionMenuPoint = nil
                pointer.gestureCaptured = surface?.isMouseCaptured == true
                if button == GHOSTTY_MOUSE_LEFT {
                    pointer.selectionStartPoint = location
                }
                sendPointerPosition(at: location)
                if let sent = pointer.session.press(button) {
                    surface?.sendMouseButton(
                        state: GHOSTTY_MOUSE_PRESS,
                        button: sent,
                        mods: pointerMods()
                    )
                }

            case .moved:
                sendPointerPosition(at: location)
                if pointer.gestureCaptured != true {
                    updatePointerSelectionRect(to: location)
                }

            case .ended:
                if pointer.pendingSelectionMenuPoint != nil {
                    if selectionMenuPoint(at: location) != nil {
                        showSelectionCopyMenu(at: location)
                    }
                    pointer.pendingSelectionMenuPoint = nil
                    pointer.gestureCaptured = nil
                    return true
                }

                sendPointerPosition(at: location)
                let released = pointer.session.reported
                if let sent = pointer.session.finish() {
                    surface?.sendMouseButton(
                        state: GHOSTTY_MOUSE_RELEASE,
                        button: sent,
                        mods: pointerMods()
                    )
                }
                if released == GHOSTTY_MOUSE_LEFT {
                    finishPointerSelection(at: location)
                }
                pointer.gestureCaptured = nil
                pointer.pendingSelectionMenuPoint = nil

            case .cancelled:
                cancelReportedPointerButton(at: location)
            }

            return true
        }

        func pointerButton(from event: UIEvent?) -> ghostty_input_mouse_button_e {
            guard let event else { return GHOSTTY_MOUSE_LEFT }
            let mask = event.buttonMask
            var extra: Int?
            for number in TerminalPointerPolicy.extraButtonRange where mask.contains(.button(number)) {
                extra = number
                break
            }
            return TerminalPointerPolicy.ghosttyButton(
                secondary: mask.contains(.secondary),
                middle: mask.contains(.button(3)),
                extraButtonNumber: extra
            )
        }

        func pointerMods() -> ghostty_input_mods_e {
            if let hover = pointer.hoverRecognizer,
               hover.state == .began || hover.state == .changed
            {
                return TerminalInputModifiers(from: hover.modifierFlags).ghosttyMods
            }
            #if !targetEnvironment(macCatalyst) && canImport(GameController)
                if let live = gameControllerPointerMods() {
                    return live
                }
            #endif
            if !hardwareKeyboard.heldModifierFlags.isEmpty {
                return TerminalInputModifiers(from: hardwareKeyboard.heldModifierFlags)
                    .ghosttyMods
            }
            #if targetEnvironment(macCatalyst)
                if let flags = CGEvent(source: nil)?.flags {
                    var mods = TerminalInputModifiers()
                    if flags.contains(.maskCommand) { mods.insert(.super_) }
                    if flags.contains(.maskControl) { mods.insert(.ctrl) }
                    if flags.contains(.maskShift) { mods.insert(.shift) }
                    if flags.contains(.maskAlternate) { mods.insert(.alt) }
                    return mods.ghosttyMods
                }
            #endif
            return TerminalInputModifiers(from: hardwareKeyboard.heldModifierFlags)
                .ghosttyMods
        }

        #if !targetEnvironment(macCatalyst) && canImport(GameController)
            func gameControllerPointerMods() -> ghostty_input_mods_e? {
                guard let keyboard = GCKeyboard.coalesced?.keyboardInput else { return nil }
                let pressed: (GCKeyCode) -> Bool = { key in
                    keyboard.button(forKeyCode: key)?.isPressed == true
                }
                var mods = TerminalInputModifiers()
                if pressed(.leftShift) || pressed(.rightShift) { mods.insert(.shift) }
                if pressed(.leftControl) || pressed(.rightControl) { mods.insert(.ctrl) }
                if pressed(.leftAlt) || pressed(.rightAlt) { mods.insert(.alt) }
                if pressed(.leftGUI) || pressed(.rightGUI) { mods.insert(.super_) }
                return mods.ghosttyMods
            }
        #endif

        func applyMouseShape(_ raw: ghostty_action_mouse_shape_e) {
            let shape = TerminalMouseShape(raw)
            pointer.mouseShape = shape
            #if targetEnvironment(macCatalyst)
                switch shape {
                case .text:
                    NSCursor.iBeam.set()
                case .pointer:
                    NSCursor.pointingHand.set()
                case .notAllowed:
                    NSCursor.operationNotAllowed.set()
                case .default, .other:
                    NSCursor.arrow.set()
                }
            #endif
        }

        /// View points. Ghostty applies `content_scale` internally.
        func sendPointerPosition(at point: CGPoint, remember: Bool = true) {
            if remember {
                pointer.lastLocation = point
            }
            surface?.sendMousePos(
                x: Double(point.x),
                y: Double(point.y),
                mods: pointerMods()
            )
        }

        func refreshPointerPositionForModifierChange() {
            guard pointer.session.reported == nil,
                  let point = pointer.lastLocation
            else { return }
            sendPointerPosition(at: point, remember: false)
        }

        func cancelReportedPointerButton(at point: CGPoint? = nil) {
            if let point {
                sendPointerPosition(at: point)
            }
            if let sent = pointer.session.cancel() {
                surface?.sendMouseButton(
                    state: GHOSTTY_MOUSE_RELEASE,
                    button: sent,
                    mods: pointerMods()
                )
            }
            pointer.pendingSelectionMenuPoint = nil
            pointer.gestureCaptured = nil
            pointer.selectionStartPoint = nil
        }

        func updatePointerSelectionRect(to point: CGPoint) {
            guard let start = pointer.selectionStartPoint else { return }

            pointer.lastSelectionRect = CGRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(start.x - point.x),
                height: abs(start.y - point.y)
            ).insetBy(dx: -2, dy: -2)
            logPointerSelectionDiagnostics(
                context: "updatePointerSelectionRect",
                point: point
            )
        }

        func finishPointerSelection(at point: CGPoint) {
            defer { pointer.selectionStartPoint = nil }
            guard let start = pointer.selectionStartPoint else { return }
            let dragDistance = hypot(point.x - start.x, point.y - start.y)
            if dragDistance < 2 {
                pointer.lastSelectionRect = nil
            } else {
                updatePointerSelectionRect(to: point)
            }
            logPointerSelectionDiagnostics(
                context: "finishPointerSelection",
                point: point
            )
        }

        func logPointerSelectionDiagnostics(context: String, point: CGPoint) {
            guard TerminalDebugLog.isEnabled,
                  TerminalDebugLog.categories.contains(.input)
            else { return }

            let rectDescription = pointer.lastSelectionRect.map {
                NSCoder.string(for: $0)
            } ?? "nil"
            let metricsDescription = surface?.size().map(\.debugSummary) ?? "nil"
            let selection = surface?.readSelectionResult()
            let selectionDescription = selection.map {
                "text=\(TerminalDebugLog.describe($0.text)) offset=\($0.offsetStart)+\($0.offsetLength)"
            } ?? "nil"
            let word = surface?.quicklookWord()
            let wordDescription = word.map {
                "word=\(TerminalDebugLog.describe($0.word)) offset=\($0.offsetStart)+\($0.offsetLength) point=\(String(format: "%.2f", $0.pointX))x\(String(format: "%.2f", $0.pointY))"
            } ?? "nil"
            TerminalDebugLog.log(
                .input,
                "pointer selection \(context) viewBounds=\(NSCoder.string(for: bounds)) point=\(NSCoder.string(for: point)) rect=\(rectDescription) metrics=\(metricsDescription) selection=\(selectionDescription) quicklook=\(wordDescription)"
            )
        }

        @IBAction override open func copy(_: Any?) {
            guard copySelectedTextToPasteboard() else { return }
        }

        /// A paste has to reach the surface as a paste.
        ///
        /// `UIResponder`'s default implementation for a `UIKeyInput` conformer
        /// pastes by calling `insertText(_:)`, and that path now encodes text
        /// as key input — which strips the bracketed-paste markers a shell
        /// relies on to tell pasted text from typing. A pasted command with
        /// newlines would run line by line instead of landing in the edit
        /// buffer. Taking the action ourselves routes it through ghostty's
        /// own paste binding (`pasteFromPasteboard`), where the text path,
        /// the mode 2004 wrapping, and paste protection all live.
        @IBAction override open func paste(_: Any?) {
            pasteFromPasteboard()
        }

        /// Every host-driven paste — the edit menu, the accessory bar's
        /// button — of text enters through ghostty's own paste binding, the
        /// pipeline a hardware Cmd+V already used: the `read_clipboard`
        /// callback reads the pasteboard, and paste protection gets to ask
        /// before an unsafe paste lands.
        ///
        /// A pasteboard holding only image or document data is the one case
        /// handled here: the data is written to a file and its escaped path
        /// goes straight to the text path. A path carries nothing paste
        /// protection weighs (no line breaks, no control characters), and a
        /// program's own clipboard read must never write a file — so that
        /// work belongs to the host's button, not the callback.
        func pasteFromPasteboard() {
            if inputHandler.hasMarkedText {
                inputHandler.unmarkText()
            }
            if TerminalPasteboardContent.text() != nil {
                _ = surface?.performBindingAction("paste_from_clipboard")
                return
            }
            TerminalPasteboardContent.files { [weak self] paths in
                guard let self, let paths else {
                    TerminalDebugLog.log(.input, "paste skipped: pasteboard has nothing pasteable")
                    return
                }
                TerminalDebugLog.log(.input, "paste files bytes=\(paths.utf8.count)")
                surface?.sendText(paths)
            }
        }

        override open func canPerformAction(
            _ action: Selector,
            withSender sender: Any?
        ) -> Bool {
            if action == #selector(copy(_:)) {
                return surface?.hasSelection() == true
            }
            if action == #selector(paste(_:)) {
                return TerminalPasteboardContent.hasContent()
            }
            return super.canPerformAction(action, withSender: sender)
        }

        #if !targetEnvironment(macCatalyst)
            func setupTouchScrollInput() {
                let gesture = UIPanGestureRecognizer(
                    target: self,
                    action: #selector(handleTouchScrollGesture(_:))
                )
                gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                gesture.maximumNumberOfTouches = 1
                addGestureRecognizer(gesture)

                let longPress = UILongPressGestureRecognizer(
                    target: self,
                    action: #selector(handleLongPressForSelection(_:))
                )
                longPress.minimumPressDuration = 0.5
                longPress.allowableMovement = 10
                longPress.numberOfTouchesRequired = 1
                longPress.numberOfTapsRequired = 0
                longPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                longPress.cancelsTouchesInView = false
                longPress.delegate = self
                addGestureRecognizer(longPress)

                setupIndirectPointerSelectionGesture()
                setupPinchZoomGesture()
            }

            /// One left click at `point`, the way a finger tap reaches the
            /// terminal: a press and a release with no drag between them.
            /// Any pointer-drag selection is over by definition — ghostty
            /// clears its selection on the click.
            func sendTapClick(at point: CGPoint) {
                guard let surface else { return }
                let mods = pointerMods()
                sendPointerPosition(at: point)
                surface.sendMouseButton(
                    state: GHOSTTY_MOUSE_PRESS,
                    button: GHOSTTY_MOUSE_LEFT,
                    mods: mods
                )
                surface.sendMouseButton(
                    state: GHOSTTY_MOUSE_RELEASE,
                    button: GHOSTTY_MOUSE_LEFT,
                    mods: mods
                )
                pointer.lastSelectionRect = nil
                pointer.selectionStartPoint = nil
            }

            func setupIndirectPointerSelectionGesture() {
                let gesture = UIPanGestureRecognizer(
                    target: self,
                    action: #selector(handleIndirectPointerSelectionGesture(_:))
                )
                gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
                gesture.minimumNumberOfTouches = 1
                gesture.maximumNumberOfTouches = 1
                gesture.cancelsTouchesInView = false
                gesture.delaysTouchesBegan = false
                gesture.delaysTouchesEnded = false
                addGestureRecognizer(gesture)
            }

            @objc func handleIndirectPointerSelectionGesture(
                _ gesture: UIPanGestureRecognizer
            ) {
                let location = gesture.location(in: self)
                TerminalDebugLog.log(
                    .input,
                    "indirect pointer gesture state=\(gesture.state.rawValue) location=\(NSCoder.string(for: location)) translation=\(NSCoder.string(for: gesture.translation(in: self)))"
                )

                switch gesture.state {
                case .began:
                    if let reported = pointer.session.reported,
                       reported != GHOSTTY_MOUSE_LEFT
                    {
                        return
                    }
                    core.setFocus(true)
                    stopMomentumScrolling()
                    pointer.panOwnsTouchSequence = true
                    if pointer.gestureCaptured == nil {
                        pointer.gestureCaptured = surface?.isMouseCaptured == true
                    }
                    if pointer.session.reported != GHOSTTY_MOUSE_LEFT,
                       let sent = pointer.session.press(GHOSTTY_MOUSE_LEFT)
                    {
                        surface?.sendMouseButton(
                            state: GHOSTTY_MOUSE_PRESS,
                            button: sent,
                            mods: pointerMods()
                        )
                    }
                    if pointer.selectionStartPoint == nil {
                        pointer.selectionStartPoint = location
                    }
                    pointer.pendingSelectionMenuPoint = nil
                    sendPointerPosition(at: location)

                case .changed:
                    if pointer.gestureCaptured != true {
                        updatePointerSelectionRect(to: location)
                    }
                    sendPointerPosition(at: location)

                case .ended:
                    if pointer.gestureCaptured != true {
                        updatePointerSelectionRect(to: location)
                    }
                    sendPointerPosition(at: location)
                    if let sent = pointer.session.finish() {
                        surface?.sendMouseButton(
                            state: GHOSTTY_MOUSE_RELEASE,
                            button: sent,
                            mods: pointerMods()
                        )
                    }
                    finishPointerSelection(at: location)
                    pointer.panOwnsTouchSequence = false
                    pointer.suppressNextTouchEnd = true
                    pointer.gestureCaptured = nil

                case .cancelled, .failed:
                    pointer.panOwnsTouchSequence = false
                    pointer.suppressNextTouchEnd = true
                    pointer.lastSelectionRect = nil
                    cancelReportedPointerButton(at: location)

                default:
                    break
                }
            }

            /// The delegate to hand a long-press selection to, or nil when no
            /// host opted in. A `TerminalViewState` delegate conforms
            /// unconditionally, so for SwiftUI hosts the opt-in is its
            /// `onTextSelectionRequest` closure being set.
            var activeTextSelectionDelegate: (any TerminalSurfaceTextSelectionRequestDelegate)? {
                guard let delegate = delegate as? any TerminalSurfaceTextSelectionRequestDelegate else {
                    return nil
                }
                if let state = delegate as? TerminalViewState, state.onTextSelectionRequest == nil {
                    return nil
                }
                return delegate
            }

            @objc func handleLongPressForSelection(
                _ gesture: UILongPressGestureRecognizer
            ) {
                guard gesture.state == .began else { return }
                softwareKeyboard.tapCandidateArmed = false
                guard let delegate = activeTextSelectionDelegate else { return }
                guard let surface else { return }
                guard case let .inMemory(session) = configuration.backend else {
                    TerminalDebugLog.log(.input, "long-press selection ignored: backend not inMemory")
                    return
                }

                stopMomentumScrolling()

                let viewPoint = gesture.location(in: self)
                sendPointerPosition(at: viewPoint)

                let wordResult = surface.quicklookWord()

                guard let text = session.readViewportText() else {
                    TerminalDebugLog.log(
                        .input,
                        "long-press selection aborted: readViewportText returned nil"
                    )
                    return
                }

                var anchorRange: NSRange?
                if let w = wordResult, !text.isEmpty, let size = surface.size() {
                    anchorRange = TerminalSelectionAnchor.resolveRange(
                        in: text,
                        word: w.word,
                        offsetStart: w.offsetStart,
                        columns: UInt32(size.columns)
                    )
                }

                TerminalDebugLog.log(
                    .input,
                    "long-press selection dispatch viewPoint=\(NSCoder.string(for: viewPoint)) word=\(TerminalDebugLog.describe(wordResult?.word ?? "nil")) anchor=\(anchorRange.map { NSStringFromRange($0) } ?? "nil")"
                )

                #if !os(visionOS) // no haptics on a headset
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #endif

                delegate.terminalDidRequestTextSelection(.init(
                    text: text,
                    anchorRange: anchorRange,
                    sourcePoint: viewPoint
                ))
            }
        #endif

        @objc func handleTouchScrollGesture(
            _ gesture: UIPanGestureRecognizer
        ) {
            switch gesture.state {
            case .began:
                guard pointer.session.reported == nil else { return }
                #if !targetEnvironment(macCatalyst)
                    softwareKeyboard.tapCandidateArmed = false
                #endif
                TerminalDebugLog.log(.input, "touch scroll began")
                stopMomentumScrolling()

            case .changed:
                guard pointer.session.reported == nil else { return }
                let translation = gesture.translation(in: self)
                gesture.setTranslation(.zero, in: self)
                TerminalDebugLog.log(
                    .input,
                    "touch scroll changed translation=\(String(format: "%.2f", translation.x))x\(String(format: "%.2f", translation.y))"
                )

                let scrollMods = TerminalScrollModifiers(precision: true)
                surface?.sendMouseScroll(
                    x: Double(translation.x * Self.touchScrollMultiplier),
                    y: Double(translation.y * Self.touchScrollMultiplier),
                    mods: scrollMods.rawValue
                )

            case .ended:
                guard pointer.session.reported == nil else { return }
                let velocity = gesture.velocity(in: self)
                TerminalDebugLog.log(
                    .input,
                    "touch scroll ended velocity=\(String(format: "%.2f", velocity.x))x\(String(format: "%.2f", velocity.y))"
                )
                startMomentumScrolling(velocity: velocity)

            case .cancelled, .failed:
                TerminalDebugLog.log(.input, "touch scroll cancelled")
                stopMomentumScrolling()

            default:
                break
            }
        }

        func startMomentumScrolling(velocity: CGPoint) {
            guard abs(velocity.x) > 50 || abs(velocity.y) > 50 else { return }

            momentumScroll.velocity = velocity
            TerminalDebugLog.log(
                .input,
                "momentum start velocity=\(String(format: "%.2f", velocity.x))x\(String(format: "%.2f", velocity.y))"
            )

            let mods = TerminalScrollModifiers(precision: true, momentum: .began)
            surface?.sendMouseScroll(x: 0, y: 0, mods: mods.rawValue)

            let link = CADisplayLink(
                target: self,
                selector: #selector(momentumScrollFrame(_:))
            )
            link.add(to: .main, forMode: .common)
            momentumScroll.displayLink = link
        }

        @objc func momentumScrollFrame(_ link: CADisplayLink) {
            let dt = link.targetTimestamp - link.timestamp
            // 0.92 per 1/60 s, scaled to the frame so a flick travels the
            // same distance at 120 Hz as at 60 Hz.
            let decay = CGFloat(pow(0.92, dt * 60))

            momentumScroll.velocity.x *= decay
            momentumScroll.velocity.y *= decay

            let deltaX = momentumScroll.velocity.x * dt * Self.touchScrollMultiplier
            let deltaY = momentumScroll.velocity.y * dt * Self.touchScrollMultiplier

            if abs(momentumScroll.velocity.x) < 50, abs(momentumScroll.velocity.y) < 50 {
                stopMomentumScrolling()
                return
            }

            TerminalDebugLog.log(
                .input,
                "momentum frame velocity=\(String(format: "%.2f", momentumScroll.velocity.x))x\(String(format: "%.2f", momentumScroll.velocity.y)) delta=\(String(format: "%.2f", deltaX))x\(String(format: "%.2f", deltaY))"
            )

            let mods = TerminalScrollModifiers(precision: true, momentum: .changed)
            surface?.sendMouseScroll(
                x: Double(deltaX),
                y: Double(deltaY),
                mods: mods.rawValue
            )
        }

        func stopMomentumScrolling(sendTerminalEndEvent: Bool = true) {
            guard momentumScroll.displayLink != nil else { return }
            TerminalDebugLog.log(.input, "momentum stop")

            if sendTerminalEndEvent {
                let mods = TerminalScrollModifiers(precision: true, momentum: .none)
                surface?.sendMouseScroll(x: 0, y: 0, mods: mods.rawValue)
            }

            momentumScroll.displayLink?.invalidate()
            momentumScroll.displayLink = nil
            momentumScroll.velocity = .zero
        }
    }

    extension UITerminalView: UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
        /// Gate the long-press recognizer at the gesture layer when no host
        /// has opted into selection delegate. Without this, the recognizer
        /// still enters the touch arena for 0.5s and can subtly delay pan
        /// recognition for hosts that don't want the feature at all.
        override open func gestureRecognizerShouldBegin(
            _ gestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if gestureRecognizer is UILongPressGestureRecognizer {
                #if targetEnvironment(macCatalyst)
                    return (delegate as? any TerminalSurfaceTextSelectionRequestDelegate) != nil
                #else
                    return activeTextSelectionDelegate != nil
                #endif
            }
            return true
        }

        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === pointer.hoverRecognizer
                || otherGestureRecognizer === pointer.hoverRecognizer
        }

        open func contextMenuInteraction(
            _: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            sendPointerPosition(at: location)
            guard TerminalPointerPolicy.shouldPresentHostSecondaryMenu(
                mouseCaptured: surface?.isMouseCaptured == true
            ) else { return nil }
            guard selectionMenuPoint(at: location) != nil else { return nil }

            return selectionContextMenuConfiguration(at: location)
        }

    }

    #if !targetEnvironment(macCatalyst)
        extension UITerminalView: UIPointerInteractionDelegate {
            public func pointerInteraction(
                _: UIPointerInteraction,
                styleFor _: UIPointerRegion
            ) -> UIPointerStyle? {
                switch pointer.mouseShape {
                case .text:
                    return UIPointerStyle(shape: .verticalBeam(length: 24))
                case .notAllowed:
                    return .hidden()
                case .pointer, .default, .other:
                    return nil
                }
            }
        }
    #endif
#endif
