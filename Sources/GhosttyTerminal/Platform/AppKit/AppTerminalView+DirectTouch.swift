//
//  AppTerminalView+DirectTouch.swift
//  libghostty-spm
//

#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    import DisplayLink
    import GhosttyKit

    /// Direct-touch state — a finger on a Mac's touch display or on a
    /// Sidecar iPad; behavior lives in +DirectTouch.
    struct DirectTouchState {
        var gestureDelegate: TerminalDirectTouchGestureDelegate?
        var pinch = TerminalPinchFontZoom()
        var momentum: TerminalScrollMomentum?
        var momentumTimer: Timer?
        var momentumTimestamp: TimeInterval = 0
        /// A pan under way, and the finger's translation since it began.
        var isPanning = false
        var panTranslation: CGPoint = .zero
        var lastPanReport: TimeInterval = 0
        var resampler = TerminalTouchResampler()
        /// Ticks while a finger pans or a glide runs (`directTouchFrame`).
        var frameDriver: TerminalDirectTouchFrameDriver?
        /// When the display link last ticked; 0 before it ever did.
        var lastFrame: TimeInterval = 0
        /// The time the last refresh's scroll was made for.
        var lastFrameStep: TimeInterval = 0
        /// Invalidates a pending `directTouchFrame` step when frames stop.
        var frameToken = 0
        /// When a finger last landed on a glide and stopped it.
        var caughtGlide: TimeInterval?
        var idleFrames = 0
    }

    /// The display's refreshes while a finger pans or a glide runs. A
    /// separate object for the reason the gesture delegate is one.
    @MainActor
    final class TerminalDirectTouchFrameDriver: DisplayLinkDelegate {
        weak var view: AppTerminalView?
        let link: DisplayLink

        init(view: AppTerminalView) {
            self.view = view
            link = DisplayLink(
                context: .view(view),
                preferredFrameRateRange: DisplayLinkFrameRateRange(minimum: 60, maximum: 120, preferred: 120),
            )
            link.isPaused = true
            link.delegate = self
        }

        func displayLink(_: DisplayLink, didUpdate frame: DisplayLinkFrame) {
            view?.directTouchFrame(at: frame.timestamp)
        }
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
            view?.directTouchDown()
            return true
        }
    }

    extension AppTerminalView {
        /// How often a glide moves the viewport.
        static let directTouchMomentumInterval: TimeInterval = 1.0 / 120.0
        /// How long a finger that caught a glide may rest before the
        /// viewport is brought to a row.
        static let directTouchCatchSettleDelay: TimeInterval = 0.12
        /// The display link counts as ticking while its last refresh is no
        /// older than this; the pan and the glide then move on its
        /// refreshes, and by themselves otherwise (a window off screen).
        static let directTouchFrameTimeout: TimeInterval = 0.05
        /// Refreshes with nothing to move before the link is paused.
        static let directTouchIdleFrames = 30
        /// How long after a refresh the viewport is moved. Moved at the
        /// refresh itself, one refresh in seven showed no new frame and
        /// another took two steps; 3 ms on, none did. The frame that holds
        /// a scroll reaches the layer a couple of milliseconds after it,
        /// and from the refresh that is about where the window server
        /// takes its frame: this refresh or the next, as the threads
        /// happen to wake.
        static let directTouchFrameOffset: TimeInterval = 0.003

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
            return CGPoint(x: location.x, y: bounds.height - location.y + pointerRowOffset)
        }

        @objc func handleDirectTouchTapGesture(_ gesture: NSClickGestureRecognizer) {
            guard gesture.state == .ended else { return }
            handleDirectTouchTap(at: terminalPoint(of: gesture))
        }

        /// A finger landed. On a glide it stops it, and the tap it may turn
        /// out to be does nothing else (`handleDirectTouchTap`).
        func directTouchDown() {
            guard directTouch.momentum != nil else { return }
            directTouch.caughtGlide = CACurrentMediaTime()
            stopDirectTouchMomentum()
        }

        /// How long after a finger caught a glide its lift still counts as
        /// the tap that stopped it (under `NSPressGestureRecognizer`'s 0.5 s
        /// hold threshold).
        static let directTouchCatchTapWindow: TimeInterval = 0.5

        /// A tap is the click AppKit's emulation used to send: focus, then
        /// a left press and release where the finger was. A tap that
        /// stopped a glide is only that, as on iOS: no click for the
        /// program, and the viewport is not brought to the nearer row at
        /// once — up to half a row in one frame, back as often as on — but
        /// goes on to the row ahead in a moment (`stopDirectTouchMomentum`).
        func handleDirectTouchTap(at point: CGPoint) {
            window?.makeFirstResponder(self)
            if let caught = directTouch.caughtGlide {
                directTouch.caughtGlide = nil
                if CACurrentMediaTime() - caught < Self.directTouchCatchTapWindow { return }
            }
            core.settleScrollForPointer()
            pointer.pendingSelectionMenuPoint = nil
            surface?.sendMousePos(x: point.x, y: point.y, mods: GHOSTTY_MODS_NONE)
            surface?.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)
            surface?.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)
        }

        @objc func handleDirectTouchHoldGesture(_ gesture: NSPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                handleDirectTouchHoldBegan(at: terminalPoint(of: gesture))
            case .ended, .cancelled:
                // The finger is up: a menu's tracking loop no longer runs
                // under a recognizer that is still mid-gesture.
                if handleDirectTouchHoldEnded(at: terminalPoint(of: gesture)) {
                    selectionContextMenu().popUp(positioning: nil, at: gesture.location(in: self), in: self)
                }
            default:
                break
            }
        }

        /// A hold is the secondary click, split as `rightMouseDown` and
        /// `rightMouseUp` split it: over a selection the press is kept back
        /// for the copy menu, otherwise the terminal gets a right press.
        /// While it lasts the pan cannot begin — two recognizers on a view
        /// do not recognize together unless a delegate allows it.
        func handleDirectTouchHoldBegan(at point: CGPoint) {
            window?.makeFirstResponder(self)
            directTouch.caughtGlide = nil
            stopDirectTouchMomentum()
            core.settleScrollForPointer()
            surface?.sendMousePos(x: point.x, y: point.y, mods: GHOSTTY_MODS_NONE)
            if let menuPoint = selectionMenuPoint(at: point) {
                pointer.pendingSelectionMenuPoint = menuPoint
                return
            }
            surface?.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT, mods: GHOSTTY_MODS_NONE)
        }

        /// The lift: true when the copy menu is due, otherwise the right
        /// button is released where the finger left.
        func handleDirectTouchHoldEnded(at point: CGPoint) -> Bool {
            surface?.sendMousePos(x: point.x, y: point.y, mods: GHOSTTY_MODS_NONE)
            if pointer.pendingSelectionMenuPoint != nil {
                pointer.pendingSelectionMenuPoint = nil
                return true
            }
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
            // What a touch display's reports look like, and when they come:
            // the one thing no test without the hardware can know.
            TerminalDebugLog.log(
                .input,
                "direct touch pan state=\(gesture.state.rawValue) t=\(CACurrentMediaTime()) dy=\(-translation.y) vy=\(-velocity.y)",
            )
            handleDirectTouchPan(
                state: gesture.state,
                translation: CGPoint(x: translation.x, y: -translation.y),
                velocity: CGPoint(x: velocity.x, y: -velocity.y),
                location: CGPoint(x: location.x, y: bounds.height - location.y),
            )
        }

        /// One step of a finger's pan, in the terminal's own coordinates
        /// (y down, origin at the top left, view points).
        ///
        /// A recognizer reports the finger when its events arrive, not once
        /// a refresh, so the step is not scrolled here: it is added to the
        /// finger's travel, and `directTouchFrame` scrolls to where the
        /// finger is at each refresh (`TerminalTouchResampler`). With no
        /// display link ticking — a window off screen — it scrolls at once,
        /// as it did before.
        func handleDirectTouchPan(
            state: NSGestureRecognizer.State,
            translation: CGPoint,
            velocity: CGPoint,
            location: CGPoint,
        ) {
            switch state {
            case .began:
                directTouch.caughtGlide = nil
                stopDirectTouchMomentum()
                // Nothing settles under the finger (`TerminalSmoothScrollSettler`).
                core.scrollSettler.hold()
                // The pointer is somewhere else: a program tracking the
                // mouse gets its wheel reports for the cell under the
                // finger, not under the pointer.
                if surface?.isMouseCaptured == true {
                    surface?.sendMousePos(x: location.x, y: location.y, mods: GHOSTTY_MODS_NONE)
                }
                directTouch.isPanning = true
                directTouch.panTranslation = .zero
                directTouch.lastFrameStep = 0
                directTouch.resampler.begin()
                trackDirectTouchPan(translation)
                startDirectTouchFrames()

            case .changed:
                core.scrollSettler.hold()
                trackDirectTouchPan(translation)

            case .ended:
                trackDirectTouchPan(translation)
                directTouch.isPanning = false
                // The finger's speed from its own reports
                // (`TerminalTouchResampler.velocity`). The recognizer's
                // when they say nothing, or came with no display link
                // ticking: handed over in one go, their times are not a
                // finger's.
                let now = CACurrentMediaTime()
                let velocity = directTouchFramesAreTicking(at: now)
                    ? directTouch.resampler.velocity(at: now) ?? velocity
                    : velocity
                // A program tracking the mouse reads each report as a wheel
                // notch; a glide would keep sending them after the lift.
                if surface?.isMouseCaptured != true {
                    startDirectTouchMomentum(velocity: velocity)
                }
                if directTouch.momentum == nil {
                    // Whatever the refreshes have not scrolled yet, never
                    // back behind a prediction that ran ahead: a backwards
                    // step would jerk a resting viewport at the lift and
                    // flip `scrollSettler.lastTravel` against a slow lift.
                    let rest = directTouch.resampler.finish(followingDirection: true)
                    if rest != .zero {
                        scrollDirectTouch(by: rest, momentum: .none)
                    }
                    let moving = abs(velocity.y) >= CGFloat(Self.smoothScrollMovingSpeed)
                    core.scrollSettler.release(followingTravel: moving)
                }
                // A glide carries on from where the last refresh put the
                // viewport instead: the few milliseconds it is behind the
                // finger, made up in one frame, were a frame half as long
                // again as its neighbours. The settler waits for the glide
                // to run out.

            case .cancelled, .failed:
                cancelDirectTouchPan()
                stopDirectTouchMomentum()

            default:
                break
            }
        }

        func cancelDirectTouchPan() {
            guard directTouch.isPanning else { return }
            directTouch.isPanning = false
            core.scrollSettler.release(followingTravel: false)
        }

        /// Adds a report to the finger's travel, and scrolls it at once
        /// when no refresh will.
        private func trackDirectTouchPan(_ translation: CGPoint) {
            guard directTouch.isPanning else { return }
            let now = CACurrentMediaTime()
            directTouch.lastPanReport = now
            directTouch.panTranslation.x += translation.x
            directTouch.panTranslation.y += translation.y
            directTouch.resampler.add(directTouch.panTranslation, at: now)
            if !directTouchFramesAreTicking(at: now) {
                scrollDirectTouch(by: directTouch.resampler.finish(), momentum: .none)
            }
        }

        /// A finger pans or a glide runs. While one does, a tick only the
        /// engine's wakeup asked for does not refresh and draw on the main
        /// thread (`TerminalSurfaceCoordinator.wakeupSkipsDraw`), for the
        /// reasons it does not under UIKit's system scroll: every row the
        /// viewport crosses posts a wakeup, and the frame the main thread
        /// then drew could reach the layer after a newer one from the
        /// renderer thread — the picture went back a step and stayed there
        /// for a refresh. Bounded by `heldIdleDelay` so a finger held still
        /// or a pan whose end was lost never starves wakeups indefinitely.
        var directTouchIsScrolling: Bool {
            if directTouch.momentum != nil { return true }
            guard directTouch.isPanning else { return false }
            return CACurrentMediaTime() - directTouch.lastPanReport < TerminalSmoothScrollSettler.heldIdleDelay
        }

        private func directTouchFramesAreTicking(at now: TimeInterval) -> Bool {
            now - directTouch.lastFrame < Self.directTouchFrameTimeout
        }

        private func startDirectTouchFrames() {
            guard window != nil else { return }
            if directTouch.frameDriver == nil {
                directTouch.frameDriver = TerminalDirectTouchFrameDriver(view: self)
            }
            directTouch.idleFrames = 0
            directTouch.frameDriver?.link.isPaused = false
        }

        func stopDirectTouchFrames() {
            directTouch.frameToken &+= 1
            directTouch.frameDriver?.link.isPaused = true
            directTouch.lastFrame = 0
        }

        /// One refresh of the display: `directTouchFrameOffset` later the
        /// pan scrolls to where the finger is, and a glide moves by the
        /// time since the refresh before.
        func directTouchFrame(at timestamp: TimeInterval) {
            // The refresh's own time, evenly spaced, unless it is stale: a
            // main thread that was held up delivers it late.
            let now = CACurrentMediaTime()
            let refresh = min(now, max(timestamp, now - Self.directTouchFrameTimeout))
            directTouch.lastFrame = now
            guard directTouch.isPanning || directTouch.momentum != nil else {
                directTouch.idleFrames += 1
                if directTouch.idleFrames >= Self.directTouchIdleFrames {
                    stopDirectTouchFrames()
                }
                return
            }
            directTouch.idleFrames = 0
            let delay = refresh + Self.directTouchFrameOffset - now
            guard delay > 0 else {
                directTouchFrameStep(at: refresh)
                return
            }
            let token = directTouch.frameToken
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.directTouch.frameToken == token else { return }
                    self.directTouchFrameStep(at: refresh)
                }
            }
        }

        /// The scroll for one refresh, with the finger and the glide read
        /// as of the time it is made.
        func directTouchFrameStep(at refresh: TimeInterval) {
            let time = refresh + Self.directTouchFrameOffset
            if directTouch.isPanning {
                guard time > directTouch.lastFrameStep else { return }
                directTouch.lastFrameStep = time
                // A finger at rest sends nothing, and neither does this.
                let step = directTouch.resampler.advance(to: time, grid: 1 / CGFloat(currentScaleFactor()))
                if step != .zero {
                    scrollDirectTouch(by: step, momentum: .none)
                }
            } else if directTouch.momentum != nil {
                guard time > directTouch.momentumTimestamp else { return }
                advanceDirectTouchMomentum(by: time - directTouch.momentumTimestamp)
                directTouch.momentumTimestamp = time
            }
        }

        @objc func handleDirectTouchMagnificationGesture(_ gesture: NSMagnificationGestureRecognizer) {
            handleDirectTouchPinch(state: gesture.state, scale: 1 + gesture.magnification)
        }

        /// One step of a two-finger pinch; `scale` is 1 where it began.
        func handleDirectTouchPinch(state: NSGestureRecognizer.State, scale: CGFloat) {
            switch state {
            case .began:
                directTouch.caughtGlide = nil
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

        /// The glide moves on the display's refreshes (`directTouchFrame`),
        /// one step a frame however the timer and the display drift apart.
        /// The timer is what moves it with no display link ticking, and
        /// what says a glide is running.
        func startDirectTouchMomentum(velocity: CGPoint) {
            guard let momentum = TerminalScrollMomentum(velocity: velocity) else { return }
            directTouch.momentum = momentum
            // From the pan's last refresh while refreshes move it, so the
            // glide's first frame is a whole one.
            let now = CACurrentMediaTime()
            let sinceStep = now - directTouch.lastFrameStep
            let continues = directTouchFramesAreTicking(at: now) && sinceStep >= 0 && sinceStep < Self.directTouchFrameTimeout
            directTouch.momentumTimestamp = continues ? directTouch.lastFrameStep : now
            scrollDirectTouch(by: .zero, momentum: .began)
            startDirectTouchFrames()

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
            let now = CACurrentMediaTime()
            guard !directTouchFramesAreTicking(at: now) else { return }
            advanceDirectTouchMomentum(by: now - directTouch.momentumTimestamp)
            directTouch.momentumTimestamp = now
        }

        func advanceDirectTouchMomentum(by interval: TimeInterval) {
            guard surface != nil, let delta = directTouch.momentum?.advance(by: interval) else {
                stopDirectTouchMomentum()
                // Run out: on to the row ahead.
                core.scrollSettler.release(followingTravel: true)
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
            // A touch caught the glide: the viewport stays where it stopped
            // and goes on to the row ahead, the way the glide went, unless
            // a drag follows (its `.began` holds the settler again). To the
            // nearer row it went back half the time.
            core.scrollSettler.release(after: Self.directTouchCatchSettleDelay, followingTravel: true)
        }
    }
#endif
