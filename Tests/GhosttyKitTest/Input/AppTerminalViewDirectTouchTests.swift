#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    @testable import GhosttyTerminal
    import Testing

    /// A finger on a Mac's touch display. AppKit hands it to the view's
    /// gesture recognizers; the tests drive the handlers those call, with
    /// the values a recognizer reports.
    @Suite("AppTerminalViewDirectTouch", .serialized)
    @MainActor
    struct AppTerminalViewDirectTouchTests {
        private func rowPoints(of rig: AppKitInputRig) throws -> CGFloat {
            let metrics = try #require(rig.view.surface?.size())
            return CGFloat(metrics.cellHeightPixels) / CGFloat(rig.view.currentScaleFactor())
        }

        /// The number in the viewport's first row of `line N` output.
        private func firstVisibleLine(of rig: AppKitInputRig) -> Int? {
            rig.session.readViewportText()?
                .components(separatedBy: "\n").first?
                .split(separator: " ").last
                .flatMap { Int($0) }
        }

        private func pan(_ rig: AppKitInputRig, by points: CGFloat, steps: Int = 4, liftVelocity: CGFloat = 0) {
            let view = rig.view
            let at = CGPoint(x: 40, y: 40)
            view.handleDirectTouchPan(state: .began, translation: .zero, velocity: .zero, location: at)
            for _ in 0 ..< steps {
                view.handleDirectTouchPan(
                    state: .changed, translation: CGPoint(x: 0, y: points / CGFloat(steps)),
                    velocity: .zero, location: at,
                )
            }
            view.handleDirectTouchPan(
                state: .ended, translation: .zero, velocity: CGPoint(x: 0, y: liftVelocity), location: at,
            )
        }

        @Test(.timeLimit(.minutes(1)))
        func `a finger dragged down brings back as many rows as it moved`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }

            rig.receive((0 ..< 400).map { "line \($0)\r\n" }.joined())
            let row = try rowPoints(of: rig)
            let before = try #require(firstVisibleLine(of: rig))

            pan(rig, by: 10.5 * row)
            let scrolledBack = try #require(firstVisibleLine(of: rig))
            #expect(before - scrolledBack == 10)

            // The half row left over from the way back counts against the
            // way forward: Ghostty moves whole rows and keeps the rest.
            pan(rig, by: -4.5 * row)
            let scrolledForward = try #require(firstVisibleLine(of: rig))
            #expect(scrolledForward - scrolledBack == 4)
            #expect(rig.view.directTouch.momentumTimer == nil)
        }

        @Test(.timeLimit(.minutes(1)))
        func `a flick glides on after the lift and a new touch catches it`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }

            rig.receive((0 ..< 400).map { "line \($0)\r\n" }.joined())
            let row = try rowPoints(of: rig)
            pan(rig, by: 2 * row, liftVelocity: 1500)
            #expect(rig.view.directTouch.momentumTimer != nil)
            let atLift = try #require(firstVisibleLine(of: rig))

            for _ in 0 ..< 30 {
                rig.view.advanceDirectTouchMomentum(by: 1.0 / 120)
            }
            let gliding = try #require(firstVisibleLine(of: rig))
            #expect(gliding < atLift)

            // What the recognizers' delegate does when a finger lands.
            rig.view.stopDirectTouchMomentum()
            #expect(rig.view.directTouch.momentumTimer == nil)
            #expect(rig.view.directTouch.momentum == nil)
        }

        @Test(.timeLimit(.minutes(1)))
        func `a glide runs out by itself`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }

            rig.receive((0 ..< 50).map { "line \($0)\r\n" }.joined())
            pan(rig, by: 10, liftVelocity: 600)
            #expect(rig.view.directTouch.momentumTimer != nil)
            for _ in 0 ..< 2000 where rig.view.directTouch.momentum != nil {
                rig.view.advanceDirectTouchMomentum(by: 1.0 / 120)
            }
            #expect(rig.view.directTouch.momentumTimer == nil)
        }

        @Test(.timeLimit(.minutes(1)))
        func `a program tracking the mouse gets wheel reports at the finger and no glide`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }

            rig.receive("\u{1B}[?1000h\u{1B}[?1006h")
            _ = await rig.take()
            let row = try rowPoints(of: rig)

            pan(rig, by: 3 * row, liftVelocity: 1500)
            let down = String(decoding: await rig.take(), as: UTF8.self)
            // SGR button 64 is wheel up: the finger moved down, toward
            // earlier content, as a trackpad's natural scroll does.
            #expect(down.contains("\u{1B}[<64;"))
            #expect(!down.contains("\u{1B}[<65;"))
            #expect(rig.view.directTouch.momentumTimer == nil)

            pan(rig, by: -3 * row)
            let up = String(decoding: await rig.take(), as: UTF8.self)
            #expect(up.contains("\u{1B}[<65;"))
            #expect(!up.contains("\u{1B}[<64;"))
        }

        @Test(.timeLimit(.minutes(1)))
        func `a pinch steps the font size and stops at the gesture's range`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }

            let start = try #require(rig.view.fontSize)
            rig.view.handleDirectTouchPinch(state: .began, scale: 1)
            rig.view.handleDirectTouchPinch(state: .changed, scale: 1.05)
            #expect(rig.view.fontSize == start)
            rig.view.handleDirectTouchPinch(state: .changed, scale: 1.32)
            #expect(rig.view.fontSize == start + 3)
            rig.view.handleDirectTouchPinch(state: .changed, scale: 1.0)
            #expect(rig.view.fontSize == start)
            rig.view.handleDirectTouchPinch(state: .ended, scale: 1.0)

            rig.view.handleDirectTouchPinch(state: .began, scale: 1)
            rig.view.handleDirectTouchPinch(state: .changed, scale: 30)
            #expect(rig.view.fontSize == TerminalPinchFontZoom.maxFontSize)
            rig.view.handleDirectTouchPinch(state: .ended, scale: 30)

            rig.view.handleDirectTouchPinch(state: .began, scale: 1)
            rig.view.handleDirectTouchPinch(state: .changed, scale: -30)
            #expect(rig.view.fontSize == TerminalPinchFontZoom.minFontSize)
            rig.view.handleDirectTouchPinch(state: .cancelled, scale: 1)
        }

        /// AppKit's mouse emulation leaves a view that has a direct-touch
        /// recognizer of its own, so the tap and the hold are ours to send.
        @Test(.timeLimit(.minutes(1)))
        func `a tap is a left click and a hold a right click where the finger is`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }

            rig.receive("\u{1B}[?1000h\u{1B}[?1006h")
            _ = await rig.take()

            rig.view.handleDirectTouchTap(at: CGPoint(x: 4, y: 4))
            let tap = String(decoding: await rig.take(), as: UTF8.self)
            #expect(tap.contains("\u{1B}[<0;1;1M"))
            #expect(tap.contains("\u{1B}[<0;1;1m"))

            #expect(rig.view.handleDirectTouchHold(at: CGPoint(x: 4, y: 4)) == false)
            let hold = String(decoding: await rig.take(), as: UTF8.self)
            #expect(hold.contains("\u{1B}[<2;1;1M"))
            #expect(hold.contains("\u{1B}[<2;1;1m"))
        }

        @Test(.timeLimit(.minutes(1)))
        func `a hold over a selection asks for the copy menu and sends no click`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }

            rig.receive("hello world")
            #expect(rig.view.performBindingAction("select_all"))
            #expect(rig.view.handleDirectTouchHold(at: CGPoint(x: 4, y: 4)))
            #expect(rig.view.surface?.hasSelection() == true)
        }

        /// The recognizer reports in the view's own coordinates, y up; the
        /// handler it calls must turn that over, or a finger scrolls
        /// backwards.
        @Test(.timeLimit(.minutes(1)))
        func `the recognizer's upward y is turned over before it scrolls`() async throws {
            final class Pan: NSPanGestureRecognizer {
                var reportedState: NSGestureRecognizer.State = .possible
                var reportedTranslation = NSPoint.zero
                override var state: NSGestureRecognizer.State {
                    get { reportedState }
                    set { reportedState = newValue }
                }

                override func translation(in _: NSView?) -> NSPoint { reportedTranslation }
                override func velocity(in _: NSView?) -> NSPoint { .zero }
                override func location(in _: NSView?) -> NSPoint { NSPoint(x: 40, y: 40) }
                override func setTranslation(_: NSPoint, in _: NSView?) {}
            }

            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }

            rig.receive((0 ..< 400).map { "line \($0)\r\n" }.joined())
            let row = try rowPoints(of: rig)
            let before = try #require(firstVisibleLine(of: rig))

            let pan = Pan(target: nil, action: nil)
            pan.reportedState = .began
            rig.view.handleDirectTouchPanGesture(pan)
            pan.reportedState = .changed
            // The finger moves down the screen: negative in a view whose
            // y points up.
            pan.reportedTranslation = NSPoint(x: 0, y: -6 * row)
            rig.view.handleDirectTouchPanGesture(pan)
            pan.reportedState = .ended
            pan.reportedTranslation = .zero
            rig.view.handleDirectTouchPanGesture(pan)

            let after = try #require(firstVisibleLine(of: rig))
            #expect(before - after == 6)
        }

        @Test(.timeLimit(.minutes(1)))
        func `a glide's tick moves by the time since the last one and stops off a window`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()

            rig.receive((0 ..< 400).map { "line \($0)\r\n" }.joined())
            pan(rig, by: 10, liftVelocity: 2000)
            let timer = try #require(rig.view.directTouch.momentumTimer)
            let atLift = try #require(firstVisibleLine(of: rig))

            rig.view.directTouch.momentumTimestamp = ProcessInfo.processInfo.systemUptime - 0.05
            rig.view.directTouchMomentumTick(timer)
            let gliding = try #require(firstVisibleLine(of: rig))
            #expect(gliding < atLift)

            rig.tearDown()
            #expect(rig.view.directTouch.momentumTimer == nil)
            #expect(!timer.isValid)
        }

        /// What keeps a Mac without touch input exactly where it was: the
        /// recognizers take no mouse button and refuse every `NSEvent`, so a
        /// click, a drag and a trackpad pinch never reach them.
        @Test
        func `the recognizers take fingers only`() throws {
            let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            let recognizers = view.gestureRecognizers
            guard #available(macOS 27.0, *) else {
                #expect(recognizers.isEmpty)
                return
            }
            let pan = try #require(recognizers.compactMap { $0 as? NSPanGestureRecognizer }.first)
            let magnification = try #require(recognizers.compactMap { $0 as? NSMagnificationGestureRecognizer }.first)
            let tap = try #require(recognizers.compactMap { $0 as? NSClickGestureRecognizer }.first)
            let hold = try #require(recognizers.compactMap { $0 as? NSPressGestureRecognizer }.first)
            #expect(recognizers.count == 4)
            #expect(tap.buttonMask == 0)
            #expect(hold.buttonMask == 0)
            #expect(tap.allowedTouchTypes == .direct)
            #expect(hold.allowedTouchTypes == .direct)
            #expect(pan.buttonMask == 0)
            #expect(pan.allowedTouchTypes == .direct)
            #expect(pan.value(forKey: "maximumNumberOfTouches") as? Int == 1)
            #expect(magnification.allowedTouchTypes == .direct)

            let click = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
            ))
            for recognizer in [pan, magnification, tap, hold] as [NSGestureRecognizer] {
                let delegate = try #require(recognizer.delegate)
                #expect(delegate.gestureRecognizer?(recognizer, shouldAttemptToRecognizeWith: click) == false)
                #expect(!recognizer.delaysPrimaryMouseButtonEvents)
                #expect(!recognizer.delaysMagnificationEvents)
                #expect(!recognizer.delaysSecondaryMouseButtonEvents)
            }
        }
    }
#endif
