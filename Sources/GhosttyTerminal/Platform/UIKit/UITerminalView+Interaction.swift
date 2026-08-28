//
//  UITerminalView+Interaction.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    /// Mouse/trackpad interaction state; behavior lives in +Interaction.
    struct PointerInteractionState {
        var activeButton: ghostty_input_mouse_button_e?
        var selectionStartPoint: CGPoint?
        var lastSelectionRect: CGRect?
        var pendingSelectionMenuPoint: CGPoint?
        var panOwnsTouchSequence = false
        var suppressNextTouchEnd = false
    }

    /// A pan recognizer fed by wheel and trackpad scroll events alone.
    ///
    /// A scroll event is neither a touch nor a pointer drag: it reaches a
    /// pan recognizer only through `allowedScrollTypesMask`, and the touch
    /// recognizers never see it. Refusing every other event here keeps a
    /// finger on the touch-scroll recognizer and a pointer drag on the
    /// selection one without the view's delegate having to tell them apart.
    final class TerminalScrollWheelGestureRecognizer: UIPanGestureRecognizer {
        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            allowedScrollTypesMask = [.continuous, .discrete]
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
                        // Tap-to-toggle can be host-disabled (a keyboard
                        // lock); the click above still lands either way.
                        if isKeyboardTapToggleEnabled {
                            if softwareKeyboard.isVisible {
                                resignFirstResponder()
                            } else {
                                becomeFirstResponder()
                            }
                        }
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
                action: #selector(handleScrollWheelGesture(_:))
            ))
            #if !targetEnvironment(macCatalyst)
                setupTouchScrollInput()
            #endif
        }

        @objc func handleScrollWheelGesture(_ gesture: UIPanGestureRecognizer) {
            guard pointer.activeButton == nil else { return }
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

            let scrollMods = TerminalScrollModifiers(precision: true)
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
            let mods = ghostty_input_mods_e(rawValue: 0)
            let location = touch.location(in: self)
            let suppressSurfacePositionForSelectionMenu =
                button == GHOSTTY_MOUSE_RIGHT &&
                (pointer.pendingSelectionMenuPoint != nil || pointIsInsidePointerSelection(location))
            TerminalDebugLog.log(
                .input,
                "pointer touch phase=\(phase) type=\(touch.type.rawValue) button=\(button.rawValue) location=\(NSCoder.string(for: location)) mask=\(event?.buttonMask.rawValue ?? 0)"
            )
            if !suppressSurfacePositionForSelectionMenu {
                surface?.sendMousePos(
                    x: location.x,
                    y: location.y,
                    mods: mods
                )
            }

            switch phase {
            case .began:
                pointer.activeButton = button
                switch button {
                case GHOSTTY_MOUSE_LEFT:
                    pointer.selectionStartPoint = location
                    pointer.pendingSelectionMenuPoint = nil
                    surface?.sendMouseButton(
                        state: GHOSTTY_MOUSE_PRESS,
                        button: button,
                        mods: mods
                    )

                case GHOSTTY_MOUSE_RIGHT:
                    if pointIsInsidePointerSelection(location) {
                        pointer.pendingSelectionMenuPoint = location
                    } else {
                        pointer.pendingSelectionMenuPoint = selectionMenuPoint(at: location)
                    }

                default:
                    surface?.sendMouseButton(
                        state: GHOSTTY_MOUSE_PRESS,
                        button: button,
                        mods: mods
                    )
                }

            case .moved:
                updatePointerSelectionRect(to: location)

            case .ended:
                let releasedButton = pointer.activeButton ?? button
                pointer.activeButton = nil

                if releasedButton == GHOSTTY_MOUSE_RIGHT,
                   pointer.pendingSelectionMenuPoint != nil
                {
                    if selectionMenuPoint(at: location) != nil {
                        showSelectionCopyMenu(at: location)
                    }
                    pointer.pendingSelectionMenuPoint = nil
                    return true
                }

                if releasedButton == GHOSTTY_MOUSE_RIGHT {
                    surface?.sendMouseButton(
                        state: GHOSTTY_MOUSE_PRESS,
                        button: releasedButton,
                        mods: mods
                    )
                }

                surface?.sendMouseButton(
                    state: GHOSTTY_MOUSE_RELEASE,
                    button: releasedButton,
                    mods: mods
                )

                if releasedButton == GHOSTTY_MOUSE_LEFT {
                    finishPointerSelection(at: location)
                }
                pointer.pendingSelectionMenuPoint = nil

            case .cancelled:
                let releasedButton = pointer.activeButton ?? button
                pointer.activeButton = nil
                pointer.pendingSelectionMenuPoint = nil
                pointer.selectionStartPoint = nil
                surface?.sendMouseButton(
                    state: GHOSTTY_MOUSE_RELEASE,
                    button: releasedButton,
                    mods: mods
                )
            }

            return true
        }

        func pointerButton(from event: UIEvent?) -> ghostty_input_mouse_button_e {
            guard let event else { return GHOSTTY_MOUSE_LEFT }
            if event.buttonMask.contains(.secondary) {
                return GHOSTTY_MOUSE_RIGHT
            }
            if event.buttonMask.contains(.primary) {
                return GHOSTTY_MOUSE_LEFT
            }
            return GHOSTTY_MOUSE_LEFT
        }

        func updatePointerSelectionRect(to point: CGPoint) {
            guard pointer.activeButton == GHOSTTY_MOUSE_LEFT,
                  let start = pointer.selectionStartPoint
            else { return }

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

        func pointIsInsidePointerSelection(_ point: CGPoint) -> Bool {
            pointer.lastSelectionRect.map {
                $0.insetBy(dx: -4, dy: -4).contains(point)
            } ?? false
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
                fontZoom.currentFontSize = configuration.fontSize ?? 14
                setupPinchZoomGesture()
            }

            /// One left click at `point`, the way a finger tap reaches the
            /// terminal: a press and a release with no drag between them.
            /// Any pointer-drag selection is over by definition — ghostty
            /// clears its selection on the click.
            func sendTapClick(at point: CGPoint) {
                guard let surface else { return }
                let mods = ghostty_input_mods_e(rawValue: 0)
                surface.sendMousePos(x: point.x, y: point.y, mods: mods)
                surface.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, mods: mods)
                surface.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, mods: mods)
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
                let mods = ghostty_input_mods_e(rawValue: 0)
                TerminalDebugLog.log(
                    .input,
                    "indirect pointer gesture state=\(gesture.state.rawValue) location=\(NSCoder.string(for: location)) translation=\(NSCoder.string(for: gesture.translation(in: self)))"
                )

                switch gesture.state {
                case .began:
                    core.setFocus(true)
                    stopMomentumScrolling()
                    pointer.panOwnsTouchSequence = true
                    if pointer.activeButton != GHOSTTY_MOUSE_LEFT {
                        pointer.activeButton = GHOSTTY_MOUSE_LEFT
                        surface?.sendMouseButton(
                            state: GHOSTTY_MOUSE_PRESS,
                            button: GHOSTTY_MOUSE_LEFT,
                            mods: mods
                        )
                    }
                    if pointer.selectionStartPoint == nil {
                        pointer.selectionStartPoint = location
                    }
                    pointer.pendingSelectionMenuPoint = nil
                    surface?.sendMousePos(x: location.x, y: location.y, mods: mods)

                case .changed:
                    updatePointerSelectionRect(to: location)
                    surface?.sendMousePos(x: location.x, y: location.y, mods: mods)

                case .ended:
                    pointer.activeButton = nil
                    updatePointerSelectionRect(to: location)
                    surface?.sendMousePos(x: location.x, y: location.y, mods: mods)
                    surface?.sendMouseButton(
                        state: GHOSTTY_MOUSE_RELEASE,
                        button: GHOSTTY_MOUSE_LEFT,
                        mods: mods
                    )
                    finishPointerSelection(at: location)
                    pointer.panOwnsTouchSequence = false
                    pointer.suppressNextTouchEnd = true

                case .cancelled, .failed:
                    pointer.activeButton = nil
                    pointer.panOwnsTouchSequence = false
                    pointer.suppressNextTouchEnd = true
                    pointer.selectionStartPoint = nil
                    pointer.pendingSelectionMenuPoint = nil
                    pointer.lastSelectionRect = nil
                    surface?.sendMouseButton(
                        state: GHOSTTY_MOUSE_RELEASE,
                        button: GHOSTTY_MOUSE_LEFT,
                        mods: mods
                    )

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
                surface.sendMousePos(
                    x: Double(viewPoint.x),
                    y: Double(viewPoint.y),
                    mods: ghostty_input_mods_e(rawValue: 0)
                )

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
                    let scale = Double(resolvedDisplayScale())
                    // cellWidth/HeightPixels are surface pixels; ghostty's
                    // tl_px_x/y are host points. Convert to points before
                    // dividing so units match inside resolveRange.
                    let cellWidthPoints = scale > 0 ? Double(size.cellWidthPixels) / scale : 0
                    let cellHeightPoints = scale > 0 ? Double(size.cellHeightPixels) / scale : 0
                    anchorRange = TerminalSelectionAnchor.resolveRange(
                        in: text,
                        word: w.word,
                        pointX: w.pointX,
                        pointY: w.pointY,
                        cellWidthPoints: cellWidthPoints,
                        cellHeightPoints: cellHeightPoints
                    )
                }

                TerminalDebugLog.log(
                    .input,
                    "long-press selection dispatch viewPoint=\(NSCoder.string(for: viewPoint)) word=\(TerminalDebugLog.describe(wordResult?.word ?? "nil")) anchor=\(anchorRange.map { NSStringFromRange($0) } ?? "nil")"
                )

                UIImpactFeedbackGenerator(style: .medium).impactOccurred()

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
                guard pointer.activeButton == nil else { return }
                #if !targetEnvironment(macCatalyst)
                    softwareKeyboard.tapCandidateArmed = false
                #endif
                TerminalDebugLog.log(.input, "touch scroll began")
                stopMomentumScrolling()

            case .changed:
                guard pointer.activeButton == nil else { return }
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
                guard pointer.activeButton == nil else { return }
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
            let deceleration: CGFloat = 0.92

            momentumScroll.velocity.x *= deceleration
            momentumScroll.velocity.y *= deceleration

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

        open func contextMenuInteraction(
            _: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            surface?.sendMousePos(
                x: location.x,
                y: location.y,
                mods: ghostty_input_mods_e(rawValue: 0)
            )
            guard selectionMenuPoint(at: location) != nil else { return nil }

            return selectionContextMenuConfiguration(at: location)
        }

    }
#endif
