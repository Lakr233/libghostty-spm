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

        /// The grid a view reports as it gets its first size is not yet the
        /// one it keeps.
        private func waitForSteadyGrid(_ rig: AppKitInputRig) async {
            var grid = rig.view.surface?.size()
            var heldSince = ContinuousClock.now
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now - heldSince < .milliseconds(400), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
                let now = rig.view.surface?.size()
                if now != grid {
                    grid = now
                    heldSince = ContinuousClock.now
                }
            }
        }

        /// No snap running and the viewport on a row.
        private func settles(_ rig: AppKitInputRig) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(3)
            while rig.view.core.scrollSettler.isSnapping || (rig.view.surface?.smoothScrollPosition()?.fraction ?? 0) != 0 {
                if ContinuousClock.now > deadline { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return true
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

            // A resize drops the part of a row the viewport is past, so the
            // grid has to hold still first.
            await waitForSteadyGrid(rig)
            rig.receive((0 ..< 400).map { "line \($0)\r\n" }.joined())
            let row = try rowPoints(of: rig)
            let before = try #require(firstVisibleLine(of: rig))

            // The viewport moves by the pixel under the finger
            // (Patches/ghostty/0022) and, dragged to a stop, settles on the
            // nearer row.
            pan(rig, by: 10.4 * row)
            #expect(await settles(rig))
            let scrolledBack = try #require(firstVisibleLine(of: rig))
            #expect(before - scrolledBack == 10)

            pan(rig, by: -4.4 * row)
            #expect(await settles(rig))
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

            rig.view.handleDirectTouchHoldBegan(at: CGPoint(x: 4, y: 4))
            let held = String(decoding: await rig.take(), as: UTF8.self)
            #expect(held.contains("\u{1B}[<2;1;1M"))
            #expect(!held.contains("\u{1B}[<2;1;1m"))
            #expect(rig.view.handleDirectTouchHoldEnded(at: CGPoint(x: 4, y: 4)) == false)
            let lifted = String(decoding: await rig.take(), as: UTF8.self)
            #expect(lifted.contains("\u{1B}[<2;1;1m"))
        }

        @Test(.timeLimit(.minutes(1)))
        func `a hold over a selection asks for the copy menu and sends no click`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }

            rig.receive("hello world")
            #expect(rig.view.performBindingAction("select_all"))
            rig.view.handleDirectTouchHoldBegan(at: CGPoint(x: 4, y: 4))
            #expect(rig.view.handleDirectTouchHoldEnded(at: CGPoint(x: 4, y: 4)))
            #expect(rig.view.surface?.hasSelection() == true)
            // The menu was asked for once: a second lift has nothing pending.
            #expect(rig.view.pointer.pendingSelectionMenuPoint == nil)
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

            rig.view.directTouch.momentumTimestamp = CACurrentMediaTime() - 0.05
            rig.view.directTouchMomentumTick(timer)
            let gliding = try #require(firstVisibleLine(of: rig))
            #expect(gliding < atLift)

            rig.tearDown()
            #expect(rig.view.directTouch.momentumTimer == nil)
            #expect(!timer.isValid)
        }

        /// A recognizer reports the finger when its events arrive; the
        /// viewport moves once a refresh, to where the finger is by then.
        @Test(.timeLimit(.minutes(1)))
        func `with the display link ticking a pan scrolls at the refresh, not at the report`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }

            await waitForSteadyGrid(rig)
            rig.receive((0 ..< 400).map { "line \($0)\r\n" }.joined())
            let view = rig.view
            let scale = Double(view.currentScaleFactor())
            let start = try #require(view.surface?.smoothScrollPosition()?.pixels)
            func moved() -> Double { start - (view.surface?.smoothScrollPosition()?.pixels ?? start) }
            let at = CGPoint(x: 40, y: 40)

            // No refresh yet: the report scrolls by itself, as it did before.
            view.handleDirectTouchPan(state: .began, translation: .zero, velocity: .zero, location: at)
            // The refreshes are the test's own from here on.
            view.stopDirectTouchFrames()
            view.handleDirectTouchPan(state: .changed, translation: CGPoint(x: 0, y: 6), velocity: .zero, location: at)
            #expect(abs(moved() - 6 * scale) < 0.01)

            // A refresh ticked a moment ago: reports only add up.
            view.directTouch.lastFrame = CACurrentMediaTime() + 10
            view.handleDirectTouchPan(state: .changed, translation: CGPoint(x: 0, y: 4), velocity: .zero, location: at)
            let firstReport = view.directTouch.lastPanReport
            try await Task.sleep(for: .milliseconds(16))
            view.directTouch.lastFrame = CACurrentMediaTime() + 10
            view.handleDirectTouchPan(state: .changed, translation: CGPoint(x: 0, y: 4), velocity: .zero, location: at)
            let secondReport = view.directTouch.lastPanReport
            #expect(abs(moved() - 6 * scale) < 0.01)

            // The refresh scrolls to where the finger was a moment before
            // it: halfway between the last two reports, whatever the runner
            // slept for or the display's scale is.
            let halfway = (firstReport + secondReport) / 2 + TerminalTouchResampler.latency - AppTerminalView.directTouchFrameOffset
            view.directTouchFrameStep(at: halfway)
            #expect(moved() > 10 * scale)
            #expect(moved() < 14 * scale)

            // The finger rests, then lifts (even with a stale recognizer
            // velocity): no glide, and the lift brings the rest, to the pixel.
            try await Task.sleep(for: .milliseconds(80))
            view.directTouch.lastFrame = CACurrentMediaTime() + 10
            view.handleDirectTouchPan(
                state: .ended,
                translation: CGPoint(x: 0, y: 2),
                velocity: CGPoint(x: 0, y: 400),
                location: at,
            )
            #expect(view.directTouch.momentum == nil)
            #expect(abs(moved() - 16 * scale) < 0.01)
            #expect(!view.directTouch.isPanning)
        }

        /// The glide's timer stands down while refreshes move it, or a
        /// refresh and a timer tick would each take a step.
        @Test(.timeLimit(.minutes(1)))
        func `a glide moves on the refresh while the display link ticks and on its timer otherwise`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }

            rig.receive((0 ..< 400).map { "line \($0)\r\n" }.joined())
            let view = rig.view
            pan(rig, by: 10, liftVelocity: 2000)
            view.stopDirectTouchFrames()
            let timer = try #require(view.directTouch.momentumTimer)
            func position() -> Double { view.surface?.smoothScrollPosition()?.pixels ?? 0 }

            view.directTouch.lastFrame = CACurrentMediaTime()
            view.directTouch.momentumTimestamp = CACurrentMediaTime() - 0.02
            let held = position()
            view.directTouchMomentumTick(timer)
            #expect(position() == held)
            view.directTouchFrameStep(at: CACurrentMediaTime())
            #expect(position() < held)

            // The link stopped ticking: the timer takes over again.
            view.directTouch.lastFrame = 0
            view.directTouch.momentumTimestamp = CACurrentMediaTime() - 0.02
            let before = position()
            view.directTouchMomentumTick(timer)
            #expect(position() < before)
        }

        /// The nearer row is behind the finger half the time.
        @Test(.timeLimit(.minutes(1)))
        func `a lift still moving but too slow to glide goes on to the row ahead`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }

            await waitForSteadyGrid(rig)
            rig.receive((0 ..< 400).map { "line \($0)\r\n" }.joined())
            let row = try rowPoints(of: rig)
            let before = try #require(firstVisibleLine(of: rig))

            // A third of a row, lifted at 40 pt/s: under the glide's 50,
            // over the 30 a viewport counts as moving from.
            pan(rig, by: 0.3 * row, liftVelocity: 40)
            #expect(rig.view.directTouch.momentum == nil)
            #expect(await settles(rig))
            #expect(try before - #require(firstVisibleLine(of: rig)) == 1)

            // Dragged to a stop it goes to the nearer row, as before.
            pan(rig, by: 0.3 * row)
            #expect(await settles(rig))
            #expect(try before - #require(firstVisibleLine(of: rig)) == 1)
        }

        /// A finger that lands on a glide stops it, and the viewport goes
        /// on to the row ahead; the tap it turns out to be does nothing
        /// more — no settling to the nearer row in one frame.
        @Test(.timeLimit(.minutes(1)))
        func `a tap that stops a glide leaves the viewport to go on to the row ahead`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }

            await waitForSteadyGrid(rig)
            rig.receive((0 ..< 400).map { "line \($0)\r\n" }.joined())
            let view = rig.view
            let row = try rowPoints(of: rig)
            pan(rig, by: 2 * row, liftVelocity: 1500)
            view.stopDirectTouchFrames()
            // Glide until the viewport is past the middle of a row: the
            // nearer row is then the one behind it.
            var position = try #require(view.surface?.smoothScrollPosition())
            for _ in 0 ..< 200 {
                view.advanceDirectTouchMomentum(by: 1.0 / 240)
                position = try #require(view.surface?.smoothScrollPosition())
                let fraction = position.fraction / Double(position.cellHeight)
                if fraction > 0.6, fraction < 0.9 { break }
            }
            try #require(view.directTouch.momentum != nil)
            try #require(position.fraction > 0.6 * Double(position.cellHeight))
            let caught = position

            view.directTouchDown()
            #expect(view.directTouch.momentum == nil)
            view.handleDirectTouchTap(at: CGPoint(x: 40, y: 40))
            // Still between rows: the tap did not settle it.
            #expect(view.surface?.smoothScrollPosition() == caught)

            #expect(await settles(rig))
            let settled = try #require(view.surface?.smoothScrollPosition())
            // On to the row ahead, toward the scrollback: the nearer one
            // was the next row down.
            #expect(settled.row == caught.row)
            #expect(settled.fraction == 0)

            // The next tap is a tap again.
            #expect(view.directTouch.caughtGlide == nil)
        }

        /// The main thread's own frame could reach the layer after a newer
        /// one from the renderer thread.
        @Test(.timeLimit(.minutes(1)))
        func `a wakeup does not draw on the main thread while a finger scrolls or a glide runs`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }

            rig.receive((0 ..< 400).map { "line \($0)\r\n" }.joined())
            let view = rig.view
            let at = CGPoint(x: 40, y: 40)
            #expect(!view.core.wakeupSkipsDraw())
            view.handleDirectTouchPan(state: .began, translation: .zero, velocity: .zero, location: at)
            #expect(view.core.wakeupSkipsDraw())
            view.handleDirectTouchPan(state: .ended, translation: CGPoint(x: 0, y: 30), velocity: CGPoint(x: 0, y: 1200), location: at)
            #expect(view.directTouch.momentum != nil)
            #expect(view.core.wakeupSkipsDraw())
            view.stopDirectTouchMomentum()
            #expect(!view.core.wakeupSkipsDraw())
        }

        /// A slow lift after a refresh predicted past the finger must not
        /// step back and flip `scrollSettler.lastTravel` against the travel.
        @Test(.timeLimit(.minutes(1)))
        func `a slow lift behind an earlier prediction still goes on to the row ahead`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }

            await waitForSteadyGrid(rig)
            rig.receive((0 ..< 400).map { "line \($0)\r\n" }.joined())
            let view = rig.view
            let row = try rowPoints(of: rig)
            let before = try #require(firstVisibleLine(of: rig))
            let at = CGPoint(x: 40, y: 40)

            view.handleDirectTouchPan(state: .began, translation: .zero, velocity: .zero, location: at)
            view.stopDirectTouchFrames()
            let now = CACurrentMediaTime()
            view.directTouch.resampler.begin()
            view.directTouch.resampler.add(.zero, at: now - 0.034)
            view.directTouch.resampler.add(CGPoint(x: 0, y: 0.2 * row), at: now - 0.026)
            // Predict ahead to ~0.4 * row (still under half a row, so the
            // nearer row is `before` and the row ahead is `before - 1`).
            view.directTouchFrameStep(
                at: now - 0.018 + TerminalTouchResampler.latency - AppTerminalView.directTouchFrameOffset,
            )
            let predicted = try #require(view.surface?.smoothScrollPosition()?.pixels)
            view.directTouch.resampler.add(CGPoint(x: 0, y: 0.2 * row), at: now - 0.025)
            view.directTouch.panTranslation = CGPoint(x: 0, y: 0.2 * row)
            view.directTouch.lastFrame = now

            // Over the last 25 ms the finger moved 1 pt (40 pt/s: under the
            // glide's 50, over the settler's 30), ending behind `predicted`.
            view.handleDirectTouchPan(state: .ended, translation: CGPoint(x: 0, y: 1), velocity: CGPoint(x: 0, y: 40), location: at)
            let atLift = try #require(view.surface?.smoothScrollPosition()?.pixels)
            #expect(atLift == predicted)
            #expect(view.directTouch.momentum == nil)
            #expect(await settles(rig))
            #expect(try before - #require(firstVisibleLine(of: rig)) == 1)
        }

        /// Detaching from a window mid-pan clears `isPanning` and releases
        /// the settler, and a pinch clears `caughtGlide` so the next tap clicks.
        @Test(.timeLimit(.minutes(1)))
        func `detaching mid-pan clears wakeup suppression and a pinch clears caught glide`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }

            rig.receive((0 ..< 100).map { "line \($0)\r\n" }.joined())
            let view = rig.view
            let at = CGPoint(x: 40, y: 40)

            // Pinching on a glide clears `caughtGlide` so a tap afterwards clicks.
            pan(rig, by: 20, liftVelocity: 1500)
            view.stopDirectTouchFrames()
            view.directTouchDown()
            #expect(view.directTouch.caughtGlide != nil)
            view.handleDirectTouchPinch(state: .began, scale: 1)
            view.handleDirectTouchPinch(state: .ended, scale: 1)
            #expect(view.directTouch.caughtGlide == nil)

            // Detaching mid-pan stops the pan and restores wakeup draws.
            view.handleDirectTouchPan(state: .began, translation: CGPoint(x: 0, y: 4), velocity: .zero, location: at)
            #expect(view.directTouch.isPanning)
            #expect(view.core.wakeupSkipsDraw())
            rig.tearDown()
            #expect(!view.directTouch.isPanning)
            #expect(!view.core.wakeupSkipsDraw())
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
