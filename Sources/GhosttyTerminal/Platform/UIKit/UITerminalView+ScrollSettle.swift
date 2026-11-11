//
//  UITerminalView+ScrollSettle.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    /// Bringing a viewport left between rows to a whole row once a scroll
    /// stops: hit testing counts whole rows, and a viewport between two puts
    /// a tap a row off.
    ///
    /// One finger over scrollback belongs to the system's scroll view
    /// (+SystemScroll): its gesture, its deceleration, its bounce, and a
    /// resting place on a whole row (`systemScrollAlign`). The pan and the
    /// momentum in +Scroll keep what the scroll view does not take: a
    /// program tracking the mouse, a screen with nothing to scroll back to
    /// (the alternate screen included), the two-finger row scroll, and the
    /// wheel.
    extension UITerminalView {
        /// What becomes of the viewport once a scroll is stopped.
        enum ScrollSettle {
            /// Nothing: more deltas follow at once (a finger drags on).
            case none
            /// Stay, and align shortly unless something takes over (a finger
            /// came down on a moving scroll).
            case later
            /// Align to a row now.
            case now
        }

        /// A finger came down while momentum, the scroll view's deceleration
        /// or an alignment was moving the viewport (`touchesBegan`, or the
        /// tap recognizer receiving the touch).
        func stopMomentumForTouchDown() {
            #if !targetEnvironment(macCatalyst)
                systemScrollStop()
            #endif
            stopMomentumScrolling(settle: .later)
        }

        /// How long a touch that stopped momentum may rest before the
        /// viewport is aligned: a drag that follows cancels it.
        static let scrollTouchDownSettleDelay: TimeInterval = 0.12

        /// Eases a viewport resting between rows to the nearer one, when no
        /// finger and no momentum is moving it.
        func snapScrollToRow() {
            guard !momentumScroll.scrollsLocally else { return }
            #if !targetEnvironment(macCatalyst)
                if systemScrollIsActive {
                    systemScrollAlign(animated: true)
                }
            #endif
        }

        /// Aligns to a row at once: what follows hit-tests in whole rows (a
        /// selection, a menu, a pinch) or takes the view off screen.
        func settleScrollNow() {
            momentumScroll.settleToken += 1
            #if targetEnvironment(macCatalyst)
                // No system scrolling and no touch scrolling on Catalyst:
                // only the wheel leaves the viewport between rows, and the
                // engine is sent the rest of the row directly.
                guard surface?.isMouseCaptured != true, let extent = syncScrollModel() else { return }
                guard momentumScroll.position.fraction != 0 else { return }
                let delta = momentumScroll.position.pixelsToNearestRow(cellHeight: extent.cellHeight)
                surface?.sendMouseScroll(x: 0, y: Double(delta), mods: TerminalScrollModifiers(precision: true).rawValue)
                applyToScrollModel(delta, extent)
            #else
                systemScrollStop()
                if systemScrollIsActive {
                    systemScrollAlign(animated: false)
                }
            #endif
        }

        /// A finger came down on a moving scroll and stopped it. The
        /// viewport stays where it stopped, as a scroll view's does, and is
        /// aligned a moment later unless a drag followed.
        func settleScrollSoon() {
            momentumScroll.settleToken += 1
            let token = momentumScroll.settleToken
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollTouchDownSettleDelay) { [weak self] in
                guard let self, token == momentumScroll.settleToken, !momentumScroll.panIsActive,
                      momentumScroll.displayLink == nil else { return }
                #if !targetEnvironment(macCatalyst)
                    // The touch has only just stopped the scroll view, so a
                    // recent `scrollViewDidScroll` is not motion here; and a
                    // bounce held and let go without a drag is left out of
                    // range, to be brought back by this.
                    if systemScrollBusy(countingRecentScroll: false, countingOutOfRange: false) { return }
                #endif
                snapScrollToRow()
            }
        }

    }
#endif
