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
    /// momentum ends the viewport goes on to the row ahead; when the
    /// fingers lift it waits `smoothScrollLiftDelay` for momentum, then goes
    /// on the way it was going if it was still moving and to the nearer row
    /// if it had been dragged to a stop. A precise event with no phase at
    /// all (a synthesized pixel scroll, a smooth-scrolling utility) is left
    /// to the settler's own idle delay.
    extension AppTerminalView {
        /// AppKit sends the first momentum event right after the gesture's
        /// last one; a lift waits this long for it.
        static let smoothScrollLiftDelay: TimeInterval = 0.08
        /// Pixels in the last scroll of a gesture from which the viewport
        /// counts as still moving when the fingers lift. At 2x one point is
        /// two pixels, so a finger resting on a Magic Mouse that drifts a
        /// point does not.
        static let smoothScrollMovingDelta: Double = 3

        /// Before the event's scroll goes to the surface.
        func smoothScrollWillScroll(_ event: NSEvent) {
            guard event.hasPreciseScrollingDeltas else { return }
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
                // scroll dragged to a stop stays where it was put.
                settler.release(
                    after: Self.smoothScrollLiftDelay,
                    followingTravel: abs(settler.lastTravel) >= Self.smoothScrollMovingDelta,
                )
            } else if event.phase.contains(.cancelled) {
                // Fingers rested on a moving scroll and lifted.
                settler.release(followingTravel: false)
            }
        }
    }
#endif
