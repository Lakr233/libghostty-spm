//
//  UITerminalView+Scroll.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

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
        var scrollsLocally = false
        var localRow: CGFloat = 0

        /// A finger is dragging: from a pan's `.began` to its end, the
        /// scroll view's pan included.
        var panIsActive = false
        /// Invalidates a pending settle when a gesture or momentum follows.
        var settleToken = 0
    }

    extension UITerminalView {
        @objc func handleScrollWheelGesture(_ gesture: UIPanGestureRecognizer) {
            guard pointer.session.reported == nil else { return }
            switch gesture.state {
            case .began:
                dismissTouchSelection(restoringViewport: false)
                stopMomentumScrolling(settle: .none)
                core.scrollSettler.hold()
            case .changed:
                core.scrollSettler.hold()
            case .ended:
                // `.ended` still carries whatever moved since the last
                // `.changed`.
                break
            case .cancelled, .failed:
                core.scrollSettler.release(followingTravel: false)
                return
            default:
                return
            }
            defer {
                // Brought to a row once the wheel or the trackpad stops,
                // on iPadOS and Mac Catalyst alike: the pointer hovers and
                // clicks in whole rows. A notch can be under half a row, so
                // a viewport still moving goes on to the row ahead rather
                // than back; one dragged to a stop goes to the nearer row.
                if gesture.state == .ended {
                    let settler = core.scrollSettler
                    settler.release(
                        after: TerminalSmoothScrollSettler.idleDelay,
                        followingTravel: abs(settler.lastTravel) >= Self.scrollMovingDelta,
                    )
                }
            }

            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            TerminalDebugLog.log(
                .input,
                "scroll wheel translation=\(String(format: "%.2f", translation.x))x\(String(format: "%.2f", translation.y))",
            )

            // Ghostty's scroll C API has no key mods. The last mouse_pos
            // carries them, so a wheel event can target the cell under the
            // pointer (tmux, vim). View points: Ghostty applies content_scale
            // to a position, unlike the scroll delta below.
            let point = pointer.lastLocation ?? gesture.location(in: self)
            sendPointerPosition(at: point, remember: pointer.lastLocation == nil)

            // Always precision: UIKit hands a discrete wheel notch to the pan
            // recognizer as a point translation, not a line count, and
            // ghostty's non-precision path reads the value as lines times
            // the scroll multiplier.
            let scrollMods = TerminalScrollModifiers(precision: true)
            let pixels = TerminalScrollDistance.scrollPixels(
                for: translation,
                displayScale: resolvedDisplayScale(),
            )
            if pixels.x == 0, pixels.y == 0 { return }
            surface?.sendMouseScroll(
                x: Double(pixels.x),
                y: Double(pixels.y),
                mods: scrollMods.rawValue,
            )
        }

        /// Pixels in the last scroll from which the viewport counts as still
        /// moving when a wheel or trackpad gesture ends.
        static let scrollMovingDelta: Double = 3

        @objc func handleTouchScrollGesture(
            _ gesture: UIPanGestureRecognizer,
        ) {
            #if !targetEnvironment(macCatalyst)
                if usesInlineTextSelection {
                    if gesture.state == .began {
                        touchSelection.panUsesSelection = touchSelection.range != nil && gesture.numberOfTouches == 1
                        momentumScroll.scrollsLocally = gesture.numberOfTouches == 2
                        momentumScroll.localRow = CGFloat(touchViewportOffset)
                    }
                    if touchSelection.panUsesSelection {
                        handleTouchSelectionPan(gesture)
                        return
                    }
                }
            #endif
            switch gesture.state {
            case .began:
                guard pointer.session.reported == nil else { return }
                #if targetEnvironment(macCatalyst)
                    // The pointer is somewhere else on a Mac: a program
                    // tracking the mouse gets its wheel reports for the
                    // cell under the finger, not under the pointer.
                    if surface?.isMouseCaptured == true {
                        sendPointerPosition(at: gesture.location(in: self), remember: false)
                    }
                #else
                    softwareKeyboard.tapCandidateArmed = false
                #endif
                if !usesInlineTextSelection {
                    dismissTouchSelection(restoringViewport: false)
                }
                TerminalDebugLog.log(.input, "touch scroll began")
                // A drag that takes over from momentum goes on from where
                // it is. The two-finger scroll counts in rows, so it starts
                // from one.
                stopMomentumScrolling(settle: momentumScroll.scrollsLocally ? .now : .none)
                momentumScroll.panIsActive = true
                momentumScroll.settleToken += 1
                // Nothing settles under the finger (`TerminalSmoothScrollSettler`).
                core.scrollSettler.hold()

            case .changed:
                guard pointer.session.reported == nil else { return }
                let translation = gesture.translation(in: self)
                gesture.setTranslation(.zero, in: self)
                TerminalDebugLog.log(
                    .input,
                    "touch scroll changed translation=\(String(format: "%.2f", translation.x))x\(String(format: "%.2f", translation.y))",
                )

                if usesInlineTextSelection, !momentumScroll.scrollsLocally {
                    sendPointerPosition(at: gesture.location(in: self))
                }
                core.scrollSettler.hold()
                scrollTouchContent(by: translation, momentum: .none)

            case .ended:
                momentumScroll.panIsActive = false
                guard pointer.session.reported == nil else { return }
                let velocity = gesture.velocity(in: self)
                TerminalDebugLog.log(
                    .input,
                    "touch scroll ended velocity=\(String(format: "%.2f", velocity.x))x\(String(format: "%.2f", velocity.y))",
                )
                #if targetEnvironment(macCatalyst)
                    // A program tracking the mouse reads each report as a
                    // wheel notch; a glide would keep sending them.
                    let glides = surface?.isMouseCaptured != true
                #else
                    let glides = !usesInlineTextSelection || momentumScroll.scrollsLocally
                        || surface?.isMouseCaptured != true
                #endif
                if glides {
                    startMomentumScrolling(velocity: velocity)
                }
                // Too slow a lift for momentum: dragged to a stop, to the
                // nearer row. Otherwise the momentum settles when it stops.
                if momentumScroll.displayLink == nil {
                    core.scrollSettler.release(followingTravel: false)
                }

            case .cancelled, .failed:
                TerminalDebugLog.log(.input, "touch scroll cancelled")
                momentumScroll.panIsActive = false
                stopMomentumScrolling(settle: .none)
                // A system gesture took the touch: the viewport may be
                // between rows all the same.
                core.scrollSettler.release(followingTravel: false)

            default:
                break
            }
        }

        func scrollTouchContent(by delta: CGPoint, momentum: TerminalScrollModifiers.Momentum) {
            if usesInlineTextSelection, momentumScroll.scrollsLocally {
                guard let metrics = surface?.size(), let bar = core.bridge.scrollbar else { return }
                let cellHeight = CGFloat(metrics.cellHeightPixels) / resolvedDisplayScale()
                guard cellHeight > 0 else { return }
                momentumScroll.localRow = min(
                    max(0, CGFloat(bar.total) - CGFloat(bar.len)),
                    max(0, momentumScroll.localRow - delta.y / cellHeight),
                )
                _ = surface?.scrollToRow(UInt(momentumScroll.localRow.rounded()))
                core.requestImmediateTick()
                return
            }
            let pixels = TerminalScrollDistance.scrollPixels(for: delta, displayScale: resolvedDisplayScale())
            let mods = TerminalScrollModifiers(precision: true, momentum: momentum)
            surface?.sendMouseScroll(x: Double(pixels.x), y: Double(pixels.y), mods: mods.rawValue)
        }

        func startMomentumScrolling(velocity: CGPoint) {
            guard abs(velocity.x) > 50 || abs(velocity.y) > 50 else { return }

            momentumScroll.velocity = velocity
            TerminalDebugLog.log(
                .input,
                "momentum start velocity=\(String(format: "%.2f", velocity.x))x\(String(format: "%.2f", velocity.y))",
            )

            scrollTouchContent(by: .zero, momentum: .began)

            let link = CADisplayLink(
                target: self,
                selector: #selector(momentumScrollFrame(_:)),
            )
            // A link with no preferred range runs at 60 Hz on a ProMotion
            // display. The surface draws at 120, so every position was
            // shown for two frames and the glide moved in visible steps.
            link.preferredFrameRateRange = Self.momentumFrameRateRange
            link.add(to: .main, forMode: .common)
            momentumScroll.displayLink = link
        }

        static let momentumFrameRateRange = CAFrameRateRange(
            minimum: 80,
            maximum: 120,
            preferred: 120,
        )

        @objc func momentumScrollFrame(_ link: CADisplayLink) {
            let dt = link.targetTimestamp - link.timestamp
            // 0.92 per 1/60 s, scaled to the frame so a flick travels the
            // same distance at 120 Hz as at 60 Hz.
            let decay = CGFloat(pow(0.92, dt * 60))

            momentumScroll.velocity.x *= decay
            momentumScroll.velocity.y *= decay

            let deltaX = momentumScroll.velocity.x * dt
            let deltaY = momentumScroll.velocity.y * dt

            if abs(momentumScroll.velocity.x) < 50, abs(momentumScroll.velocity.y) < 50 {
                stopMomentumScrolling(settle: .none)
                // Run out: on to the row ahead.
                core.scrollSettler.release(followingTravel: true)
                return
            }

            TerminalDebugLog.log(
                .input,
                "momentum frame velocity=\(String(format: "%.2f", momentumScroll.velocity.x))x\(String(format: "%.2f", momentumScroll.velocity.y)) delta=\(String(format: "%.2f", deltaX))x\(String(format: "%.2f", deltaY))",
            )

            scrollTouchContent(by: CGPoint(x: deltaX, y: deltaY), momentum: .changed)
        }

        /// `.now` by default: most callers go on to work in whole rows, or
        /// are taking the view away.
        func stopMomentumScrolling(sendTerminalEndEvent: Bool = true, settle: ScrollSettle = .now) {
            #if !targetEnvironment(macCatalyst)
                if settle != ScrollSettle.none {
                    systemScrollStop()
                }
            #endif
            if momentumScroll.displayLink != nil {
                TerminalDebugLog.log(.input, "momentum stop")

                if sendTerminalEndEvent {
                    scrollTouchContent(by: .zero, momentum: .none)
                }

                momentumScroll.displayLink?.invalidate()
                momentumScroll.displayLink = nil
                momentumScroll.velocity = .zero
            }
            switch settle {
            case .none: break
            case .later: settleScrollSoon()
            case .now: settleScrollNow()
            case .pointer: settleScrollForPointer()
            }
        }
    }
#endif
