//
//  AppTerminalView+SmoothScroll.swift
//  libghostty-spm
//

#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    import GhosttyKit

    /// The trackpad's and the Magic Mouse's gestures, told to the settler
    /// that brings a viewport left between rows back to a row
    /// (`TerminalSmoothScrollSettler`, Patches/ghostty/0022). The scroll
    /// itself goes to the surface in `scrollWheel(with:)` as before; the
    /// engine decides whether it moves by the pixel.
    ///
    /// While fingers are down or momentum runs, the settler is held. When
    /// momentum ends the viewport goes on to the row ahead, at the speed the
    /// momentum ended at. When the fingers lift with the viewport still
    /// moving it does the same at once: momentum that follows holds the
    /// settler and carries on from wherever the snap got to, the same way.
    /// When they lift from a viewport dragged to a stop it waits
    /// `smoothScrollLiftDelay` for momentum, then goes to the nearer row. A
    /// touch that lifts without moving resumes what it stopped: after
    /// momentum, or a snap on the way it went, on to the row ahead that
    /// way; after a snap from a stop, on to the nearer row it was heading
    /// for. A precise event with no phase at all (a
    /// synthesized pixel scroll, a smooth-scrolling utility) is left to the
    /// settler's own idle delay.
    extension AppTerminalView {
        /// AppKit sends the first momentum event right after the gesture's
        /// last one; a lift waits this long for it.
        static let smoothScrollLiftDelay: TimeInterval = 0.08
        /// The speed (points per second, over the settler's
        /// `velocityWindow`) from which the viewport counts as still moving
        /// when the fingers lift. A finger resting on a Magic Mouse that
        /// drifts a point in one event comes to 20 pt/s and does not.
        ///
        /// Not the last event's size: a trackpad at 120 Hz moving 150 pt/s
        /// sends a point or two an event, which read as a stop half the
        /// time, and fingers held still send nothing, so the last event
        /// was the one from before they stopped.
        static let smoothScrollMovingSpeed: Double = 30

        /// Before the event's scroll goes to the surface.
        func smoothScrollWillScroll(_ event: NSEvent) {
            guard event.hasPreciseScrollingDeltas else { return }
            if !event.phase.isDisjoint(with: [.mayBegin, .began]) {
                core.scrollSettler.touchDown(moving: smoothScrollIsMoving)
            }
            let gesture: NSEvent.Phase = [.mayBegin, .began, .changed, .stationary]
            if !event.phase.isDisjoint(with: gesture) || !event.momentumPhase.isDisjoint(with: [.began, .changed]) {
                core.scrollSettler.hold()
            }
        }

        /// After it went.
        func smoothScrollDidScroll(_ event: NSEvent) {
            guard event.hasPreciseScrollingDeltas else { return }
            let settler = core.scrollSettler
            if !event.momentumPhase.isDisjoint(with: [.ended, .cancelled]) {
                settler.release(followingTravel: true)
            } else if event.phase.contains(.ended) {
                // The next touch on a Magic Mouse, or the next flick on a
                // trackpad, cuts the momentum of the one before while it
                // still moves tens of pixels; a snap to the nearer row then
                // goes back up to half a row and the new gesture forward
                // again, which reads as the text jumping back and forth. A
                // scroll dragged to a stop stays where it was put. A moving
                // one sets off at once rather than pausing for momentum: the
                // momentum that follows holds the settler and carries on the
                // same way from wherever the snap got to.
                let moving = smoothScrollIsMoving
                settler.release(after: moving ? 0 : Self.smoothScrollLiftDelay, followingTravel: moving)
            } else if event.phase.contains(.cancelled) {
                // Fingers rested on the viewport and lifted: on with what
                // they stopped (`touchDown`). Momentum, or the snap after
                // it, goes on the way it went: to the nearer row, half the
                // time that went back against it. A snap from a stop goes
                // on to the nearer row it was heading for: sent the way of
                // the drag, it turned round.
                settler.release(followingTravel: settler.touchFollowsTravel || smoothScrollIsMoving)
            }
        }

        /// The viewport moves at `smoothScrollMovingSpeed` or more.
        private var smoothScrollIsMoving: Bool {
            let pixelsPerPoint = Double(currentScaleFactor())
            return abs(core.scrollSettler.velocity()) >= Self.smoothScrollMovingSpeed * pixelsPerPoint
        }
    }
#endif
