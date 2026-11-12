//
//  AppTerminalView+DirectTouch.swift
//  libghostty-spm
//

#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    import GhosttyKit

    /// Direct-touch state — a finger on a Mac's touch display or on a
    /// Sidecar iPad; behavior lives in +DirectTouch.
    struct DirectTouchState {
        var gestureDelegate: TerminalDirectTouchGestureDelegate?
        var pinch = TerminalPinchFontZoom()
        var momentum: TerminalScrollMomentum?
        var momentumTimer: Timer?
        var momentumTimestamp: TimeInterval = 0
    }

    /// Keeps the two recognizers on fingers alone and tells the view when
    /// one lands. A separate object, not a conformance on the view: a host
    /// subclass may already be an `NSGestureRecognizerDelegate` itself.
    @MainActor
    final class TerminalDirectTouchGestureDelegate: NSObject, NSGestureRecognizerDelegate {
        weak var view: AppTerminalView?

        init(view: AppTerminalView) {
            self.view = view
        }

        /// Asked for mouse and trackpad input only. A trackpad pinch would
        /// otherwise begin the magnification recognizer, and a host that
        /// overrides `magnify(with:)` would see it twice.
        func gestureRecognizer(_: NSGestureRecognizer, shouldAttemptToRecognizeWith _: NSEvent) -> Bool {
            false
        }

        /// Asked for every finger that lands, before either recognizer
        /// moves: a touch catches a glide, as it does on iOS.
        func gestureRecognizer(_: NSGestureRecognizer, shouldReceive _: NSTouch) -> Bool {
            view?.stopDirectTouchMomentum()
            return true
        }
    }

    extension AppTerminalView {
        /// How often a glide moves the viewport.
        static let directTouchMomentumInterval: TimeInterval = 1.0 / 120.0

        /// On a Mac with a touch display AppKit turns a finger into mouse
        /// events for a view that overrides `mouseDown(with:)`, as this one
        /// does: a tap clicks, a hold is a context click, and a drag is a
        /// mouse drag — it selects text — while two fingers reach nothing at
        /// all. Scrolling and pinching come only from gesture recognizers
        /// that take direct touches ("Adopting gesture recognizers in your
        /// app", TN3216), so one finger gets a pan and two a magnification.
        ///
        /// A view with a direct-touch recognizer of its own loses that
        /// emulation altogether (`-[NSView
        /// _gestureRecognizersForMouseEmulation]` goes from three
        /// recognizers to nil on macOS 27.0), so the tap and the hold it
        /// provided are recognizers here too. `buttonMask = 0` and the
        /// delegate keep all four off the mouse and the trackpad, whose
        /// `mouseDown` / `scrollWheel` paths stay exactly as they were.
        func setupDirectTouchInput() {
            // Direct touches reach a view only from macOS 27 on.
            guard #available(macOS 27.0, *) else { return }
            let delegate = TerminalDirectTouchGestureDelegate(view: self)
            directTouch.gestureDelegate = delegate

            let pan = NSPanGestureRecognizer(
                target: self,
                action: #selector(handleDirectTouchPanGesture(_:)),
            )
            pan.buttonMask = 0
            pan.allowedTouchTypes = .direct
            // One finger, as on iOS and Catalyst: left at its default the
            // pan begins under two and locks the pinch out. The property is
            // new in the macOS 27 SDK; set by key so an older SDK still
            // builds this file.
            pan.setValue(1, forKey: "maximumNumberOfTouches")
            pan.delegate = delegate
            addGestureRecognizer(pan)

            let magnification = NSMagnificationGestureRecognizer(
                target: self,
                action: #selector(handleDirectTouchMagnificationGesture(_:)),
            )
            magnification.allowedTouchTypes = .direct
            // On by default for this class, and it would hold a trackpad
            // pinch back from a host's own `magnify(with:)`.
            magnification.delaysMagnificationEvents = false
            magnification.delegate = delegate
            addGestureRecognizer(magnification)

            let tap = NSClickGestureRecognizer(
                target: self,
                action: #selector(handleDirectTouchTapGesture(_:)),
            )
            tap.buttonMask = 0
            tap.allowedTouchTypes = .direct
            tap.delegate = delegate
            addGestureRecognizer(tap)

            let hold = NSPressGestureRecognizer(
                target: self,
                action: #selector(handleDirectTouchHoldGesture(_:)),
            )
            hold.buttonMask = 0
            hold.allowedTouchTypes = .direct
            hold.delegate = delegate
            addGestureRecognizer(hold)
        }

        /// A point a recognizer reports, in the terminal's coordinates
        /// (y down from the top left).
        private func terminalPoint(of gesture: NSGestureRecognizer) -> CGPoint {
            let location = gesture.location(in: self)
            return CGPoint(x: location.x, y: bounds.height - location.y)
        }

        @objc func handleDirectTouchTapGesture(_ gesture: NSClickGestureRecognizer) {
            guard gesture.state == .ended else { return }
            handleDirectTouchTap(at: terminalPoint(of: gesture))
        }

        /// A tap is the click AppKit's emulation used to send: focus, then
        /// a left press and release where the finger was.
        func handleDirectTouchTap(at point: CGPoint) {
            window?.makeFirstResponder(self)
            pointer.pendingSelectionMenuPoint = nil
            surface?.sendMousePos(x: point.x, y: point.y, mods: GHOSTTY_MODS_NONE)
            surface?.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)
            surface?.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)
        }

        @objc func handleDirectTouchHoldGesture(_ gesture: NSPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            if handleDirectTouchHold(at: terminalPoint(of: gesture)) {
                selectionContextMenu().popUp(positioning: nil, at: gesture.location(in: self), in: self)
            }
        }

        /// A hold is the secondary click: over a selection it asks for the
        /// copy menu (true), otherwise the terminal gets a right press and
        /// release, as `rightMouseDown` / `rightMouseUp` send them.
        func handleDirectTouchHold(at point: CGPoint) -> Bool {
            window?.makeFirstResponder(self)
            stopDirectTouchMomentum()
            surface?.sendMousePos(x: point.x, y: point.y, mods: GHOSTTY_MODS_NONE)
            if selectionMenuPoint(at: point) != nil {
                return true
            }
            surface?.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT, mods: GHOSTTY_MODS_NONE)
            surface?.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT, mods: GHOSTTY_MODS_NONE)
            return false
        }

        @objc func handleDirectTouchPanGesture(_ gesture: NSPanGestureRecognizer) {
            // The view is not flipped: up is positive here, and the terminal
            // scrolls with y pointing down, as a trackpad reports it.
            let translation = gesture.translation(in: self)
            let velocity = gesture.velocity(in: self)
            let location = gesture.location(in: self)
            gesture.setTranslation(.zero, in: self)
            handleDirectTouchPan(
                state: gesture.state,
                translation: CGPoint(x: translation.x, y: -translation.y),
                velocity: CGPoint(x: velocity.x, y: -velocity.y),
                location: CGPoint(x: location.x, y: bounds.height - location.y),
            )
        }

        /// One step of a finger's pan, in the terminal's own coordinates
        /// (y down, origin at the top left, view points).
        func handleDirectTouchPan(
            state: NSGestureRecognizer.State,
            translation: CGPoint,
            velocity: CGPoint,
            location: CGPoint,
        ) {
            switch state {
            case .began:
                stopDirectTouchMomentum()
                // The pointer is somewhere else: a program tracking the
                // mouse gets its wheel reports for the cell under the
                // finger, not under the pointer.
                if surface?.isMouseCaptured == true {
                    surface?.sendMousePos(x: location.x, y: location.y, mods: GHOSTTY_MODS_NONE)
                }
                scrollDirectTouch(by: translation, momentum: .none)

            case .changed:
                scrollDirectTouch(by: translation, momentum: .none)

            case .ended:
                scrollDirectTouch(by: translation, momentum: .none)
                // A program tracking the mouse reads each report as a wheel
                // notch; a glide would keep sending them after the lift.
                if surface?.isMouseCaptured != true {
                    startDirectTouchMomentum(velocity: velocity)
                }

            case .cancelled, .failed:
                stopDirectTouchMomentum()

            default:
                break
            }
        }

        @objc func handleDirectTouchMagnificationGesture(_ gesture: NSMagnificationGestureRecognizer) {
            handleDirectTouchPinch(state: gesture.state, scale: 1 + gesture.magnification)
        }

        /// One step of a two-finger pinch; `scale` is 1 where it began.
        func handleDirectTouchPinch(state: NSGestureRecognizer.State, scale: CGFloat) {
            switch state {
            case .began:
                stopDirectTouchMomentum()
                directTouch.pinch.begin(scale: scale)

            case .changed:
                let steps = directTouch.pinch.takeSteps(at: scale)
                guard steps != 0 else { return }
                if core.applyPinchFontZoom(steps: steps) {
                    inputContext?.invalidateCharacterCoordinates()
                }

            case .ended, .cancelled, .failed:
                directTouch.pinch.end()

            default:
                break
            }
        }

        /// Ghostty reads a precision delta as device pixels, so the content
        /// moves with the finger on every display scale.
        func scrollDirectTouch(by delta: CGPoint, momentum: TerminalScrollModifiers.Momentum) {
            let pixels = TerminalScrollDistance.scrollPixels(
                for: delta,
                displayScale: CGFloat(currentScaleFactor()),
            )
            let mods = TerminalScrollModifiers(precision: true, momentum: momentum)
            surface?.sendMouseScroll(x: Double(pixels.x), y: Double(pixels.y), mods: mods.rawValue)
        }

        func startDirectTouchMomentum(velocity: CGPoint) {
            guard let momentum = TerminalScrollMomentum(velocity: velocity) else { return }
            directTouch.momentum = momentum
            directTouch.momentumTimestamp = ProcessInfo.processInfo.systemUptime
            scrollDirectTouch(by: .zero, momentum: .began)

            let timer = Timer(
                timeInterval: Self.directTouchMomentumInterval,
                target: self,
                selector: #selector(directTouchMomentumTick(_:)),
                userInfo: nil,
                repeats: true,
            )
            RunLoop.main.add(timer, forMode: .common)
            directTouch.momentumTimer = timer
        }

        @objc func directTouchMomentumTick(_: Timer) {
            let now = ProcessInfo.processInfo.systemUptime
            advanceDirectTouchMomentum(by: now - directTouch.momentumTimestamp)
            directTouch.momentumTimestamp = now
        }

        func advanceDirectTouchMomentum(by interval: TimeInterval) {
            guard surface != nil, let delta = directTouch.momentum?.advance(by: interval) else {
                stopDirectTouchMomentum()
                return
            }
            scrollDirectTouch(by: delta, momentum: .changed)
        }

        func stopDirectTouchMomentum() {
            guard directTouch.momentum != nil else { return }
            scrollDirectTouch(by: .zero, momentum: .none)
            directTouch.momentumTimer?.invalidate()
            directTouch.momentumTimer = nil
            directTouch.momentum = nil
        }
    }
#endif
