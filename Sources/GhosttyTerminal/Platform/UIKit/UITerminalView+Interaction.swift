//
//  UITerminalView+Interaction.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    extension UITerminalView {
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
                action: #selector(handleScrollWheelGesture(_:))
            ))
            let pointerInteraction = UIPointerInteraction(delegate: self)
            addInteraction(pointerInteraction)
            pointer.pointerInteraction = pointerInteraction
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
    }
#endif
