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
        override public func touchesBegan(
            _ touches: Set<UITouch>,
            with event: UIEvent?
        ) {
            #if targetEnvironment(macCatalyst)
                if handleIndirectPointerTouches(touches, phase: .began, event: event) {
                    return
                }
            #endif
            super.touchesBegan(touches, with: event)
            becomeFirstResponder()
        }

        override public func touchesMoved(
            _ touches: Set<UITouch>,
            with event: UIEvent?
        ) {
            #if targetEnvironment(macCatalyst)
                if handleIndirectPointerTouches(touches, phase: .moved, event: event) {
                    return
                }
            #endif
            super.touchesMoved(touches, with: event)
        }

        override public func touchesEnded(
            _ touches: Set<UITouch>,
            with event: UIEvent?
        ) {
            #if targetEnvironment(macCatalyst)
                if handleIndirectPointerTouches(touches, phase: .ended, event: event) {
                    return
                }
            #endif
            super.touchesEnded(touches, with: event)
        }

        override public func touchesCancelled(
            _ touches: Set<UITouch>,
            with event: UIEvent?
        ) {
            #if targetEnvironment(macCatalyst)
                if handleIndirectPointerTouches(touches, phase: .cancelled, event: event) {
                    return
                }
            #endif
            super.touchesCancelled(touches, with: event)
        }

        func setupPlatformInput() {
            #if targetEnvironment(macCatalyst)
                setupCatalystScrollWheelInput()
            #else
                setupTouchScrollInput()
            #endif
        }

        #if targetEnvironment(macCatalyst)
            func setupCatalystScrollWheelInput() {
                let gesture = UIPanGestureRecognizer(
                    target: self,
                    action: #selector(handleCatalystScrollWheelGesture(_:))
                )
                gesture.allowedScrollTypesMask = [.continuous, .discrete]
                gesture.cancelsTouchesInView = false
                gesture.delaysTouchesBegan = false
                gesture.delaysTouchesEnded = false
                addGestureRecognizer(gesture)
            }

            @objc func handleCatalystScrollWheelGesture(
                _ gesture: UIPanGestureRecognizer
            ) {
                guard activePointerButton == nil else { return }

                let translation = gesture.translation(in: self)
                gesture.setTranslation(.zero, in: self)
                TerminalDebugLog.log(
                    .input,
                    "catalyst scroll translation=\(String(format: "%.2f", translation.x))x\(String(format: "%.2f", translation.y))"
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
                guard let touch = touches.first(where: { $0.type == .indirectPointer }) else {
                    return false
                }

                becomeFirstResponder()
                stopMomentumScrolling()

                let button = pointerButton(from: event)
                let mods = ghostty_input_mods_e(rawValue: 0)
                let location = touch.location(in: self)
                surface?.sendMousePos(
                    x: location.x,
                    y: location.y,
                    mods: mods
                )

                switch phase {
                case .began:
                    activePointerButton = button
                    surface?.sendMouseButton(
                        state: GHOSTTY_MOUSE_PRESS,
                        button: button,
                        mods: mods
                    )

                case .moved:
                    break

                case .ended, .cancelled:
                    let releasedButton = activePointerButton ?? button
                    activePointerButton = nil
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
        #else
            func setupTouchScrollInput() {
                let gesture = UIPanGestureRecognizer(
                    target: self,
                    action: #selector(handleTouchScrollGesture(_:))
                )
                gesture.maximumNumberOfTouches = 1
                addGestureRecognizer(gesture)

                currentFontSize = configuration.fontSize ?? 14
                setupPinchZoomGesture()
            }
        #endif

        @objc func handleTouchScrollGesture(
            _ gesture: UIPanGestureRecognizer
        ) {
            switch gesture.state {
            case .began:
                TerminalDebugLog.log(.input, "touch scroll began")
                stopMomentumScrolling()

            case .changed:
                let translation = gesture.translation(in: self)
                gesture.setTranslation(.zero, in: self)
                TerminalDebugLog.log(
                    .input,
                    "touch scroll changed translation=\(String(format: "%.2f", translation.x))x\(String(format: "%.2f", translation.y))"
                )

                let scrollMods = TerminalScrollModifiers(precision: true)
                surface?.sendMouseScroll(
                    x: Double(translation.x * touchScrollMultiplier),
                    y: Double(translation.y * touchScrollMultiplier),
                    mods: scrollMods.rawValue
                )

            case .ended:
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

            momentumVelocity = velocity
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
            momentumDisplayLink = link
        }

        @objc func momentumScrollFrame(_ link: CADisplayLink) {
            let dt = link.targetTimestamp - link.timestamp
            let deceleration: CGFloat = 0.92

            momentumVelocity.x *= deceleration
            momentumVelocity.y *= deceleration

            let deltaX = momentumVelocity.x * dt * touchScrollMultiplier
            let deltaY = momentumVelocity.y * dt * touchScrollMultiplier

            if abs(momentumVelocity.x) < 50, abs(momentumVelocity.y) < 50 {
                stopMomentumScrolling()
                return
            }

            TerminalDebugLog.log(
                .input,
                "momentum frame velocity=\(String(format: "%.2f", momentumVelocity.x))x\(String(format: "%.2f", momentumVelocity.y)) delta=\(String(format: "%.2f", deltaX))x\(String(format: "%.2f", deltaY))"
            )

            let mods = TerminalScrollModifiers(precision: true, momentum: .changed)
            surface?.sendMouseScroll(
                x: Double(deltaX),
                y: Double(deltaY),
                mods: mods.rawValue
            )
        }

        func stopMomentumScrolling() {
            guard momentumDisplayLink != nil else { return }
            TerminalDebugLog.log(.input, "momentum stop")

            let mods = TerminalScrollModifiers(precision: true, momentum: .none)
            surface?.sendMouseScroll(x: 0, y: 0, mods: mods.rawValue)

            momentumDisplayLink?.invalidate()
            momentumDisplayLink = nil
            momentumVelocity = .zero
        }
    }
#endif
