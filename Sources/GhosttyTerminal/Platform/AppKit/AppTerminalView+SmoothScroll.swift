//
//  AppTerminalView+SmoothScroll.swift
//  libghostty-spm
//

#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    import GhosttyKit

    /// Trackpad smooth-scroll state; behavior lives in +SmoothScroll and
    /// +ScrollSnap.
    ///
    /// With the smooth-scrolling patch a precision scroll moves the viewport
    /// by the pixel, and it can rest at "row N plus some pixels". Ghostty's
    /// hit testing and this package's selection grid count in whole rows, so
    /// a viewport left between rows puts a click a row off: the view keeps a
    /// copy of the position (`TerminalSmoothScrollPosition`) and snaps it to
    /// a row when the scroll ends.
    struct SmoothScrollState {
        /// The view's copy of the viewport position.
        var position = TerminalSmoothScrollPosition()
        /// When a delta last went to the surface. A scrollbar report counts
        /// only once it is known to be later than this.
        var lastSend: CFTimeInterval = 0
        /// The part of a delta below one pixel, carried to the next event.
        var carry: CGFloat = 0
        /// The last delta an event sent to the surface, in whole pixels,
        /// positive toward the scrollback: which way the viewport was
        /// going, and how fast, when the scroll ended.
        var lastDelta = 0
        /// Whether the pending snap goes on the way the viewport was going
        /// or to the nearer row; decided when the scroll ends.
        var snapFollowsTravel = false
        /// Invalidates a pending settle when another scroll event arrives.
        var settleToken = 0
        /// The snap to a whole row: pixels to travel, pixels sent, start.
        var snapTimer: Timer?
        var snapTotal = 0
        var snapSent = 0
        var snapStart: CFTimeInterval = 0
    }

    extension AppTerminalView {
        /// Seconds a lift waits for momentum before it snaps: AppKit sends
        /// the first momentum event right after the gesture's last one.
        static let smoothScrollLiftDelay: TimeInterval = 0.08
        /// A scrollbar report older than this against the last send may
        /// still describe the viewport before it.
        static let smoothScrollReportLag: TimeInterval = 0.1
        /// Pixels in the last event of a gesture from which the viewport
        /// counts as still moving when the fingers lift. At 2x one point is
        /// two pixels, so a finger resting on a Magic Mouse that drifts a
        /// point does not.
        static let smoothScrollMovingDelta = 3

        func smoothScrollExtent() -> TerminalSmoothScrollPosition.Extent? {
            guard let metrics = surface?.size() else { return nil }
            return TerminalSmoothScrollPosition.Extent(
                cellHeightPixels: metrics.cellHeightPixels,
                rows: metrics.rows,
                scrollbar: core.bridge.scrollbar,
            )
        }

        /// A precision scroll the viewport takes by the pixel: a trackpad or
        /// a Magic Mouse over scrollback, no program tracking the mouse.
        /// Returns false for anything else — a wheel notch, a program
        /// tracking the mouse, nothing to scroll back to (the alternate
        /// screen included) — which `scrollWheel(with:)` sends on as before,
        /// to be reported to the program, turned into arrow keys or scrolled
        /// by the row; the copy of the position is dropped then.
        ///
        /// The delta is in view points and Ghostty reads it as pixels, so
        /// it is scaled by the backing scale (`TerminalScrollDistance`), as
        /// the UIKit paths do.
        func handleSmoothScroll(_ event: NSEvent) -> Bool {
            guard event.hasPreciseScrollingDeltas, !isMouseCaptured,
                  let extent = smoothScrollExtent(), extent.maxRow > 0
            else {
                cancelScrollSettle()
                smoothScroll.position.isValid = false
                smoothScroll.carry = 0
                return false
            }
            let mods = TerminalScrollModifiers(
                precision: true,
                momentum: TerminalScrollModifiers.momentumFrom(phase: event.momentumPhase),
            )
            let delta = TerminalScrollDistance.scrollPixels(
                for: CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY),
                displayScale: CGFloat(currentScaleFactor()),
            )

            cancelScrollSettle()
            // Whole pixels only, the rest carried. The primary screen has
            // nothing to scroll sideways, so x is not sent.
            let exact = delta.y + smoothScroll.carry
            let whole = exact.rounded()
            smoothScroll.carry = exact - whole
            if whole != 0 {
                smoothScroll.lastDelta = Int(whole)
                syncSmoothScrollModel(extent)
                applyToSmoothScrollModel(Int(whole), extent)
                surface?.sendMouseScroll(x: 0, y: Double(whole), mods: mods.rawValue)
            }

            // Momentum that has run out snaps at once. A lift waits: when
            // momentum follows, its first event cancels this.
            //
            // Momentum snaps the way it was going, and so does a lift with
            // the viewport still moving. The next touch on a Magic Mouse
            // (or the next flick on a trackpad) cuts the momentum of the
            // one before while each event still moves tens of pixels; a
            // snap to the nearer row then goes back up to half a row, and
            // the new gesture goes forward again some 60 ms later, which
            // reads as the text jumping back and forth. A scroll dragged
            // to a stop snaps to the nearer row: it stays where it was put.
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                smoothScroll.snapFollowsTravel = true
                settleScrollSoon(after: 0)
            } else if event.phase == .ended || event.phase == .cancelled {
                smoothScroll.snapFollowsTravel = abs(smoothScroll.lastDelta) >= Self.smoothScrollMovingDelta
                settleScrollSoon(after: Self.smoothScrollLiftDelay)
            }
            return true
        }

        /// Brings the copy up to date with the engine before it is used
        /// (`TerminalSmoothScrollPosition.sync`).
        func syncSmoothScrollModel(_ extent: TerminalSmoothScrollPosition.Extent) {
            smoothScroll.position.sync(
                with: core.bridge.scrollbar,
                in: extent,
                trustingReport: scrollbarReflectsLastScrollSend(),
            )
        }

        /// Whether the scrollbar in hand describes the viewport after the
        /// last delta sent.
        ///
        /// Time since the send is not enough: the report sits in Ghostty's
        /// mailbox until a main-thread tick reads it, and after a stall on
        /// the main thread the one in hand is from before the stall. So the
        /// report must also have been read well after the send, or no tick
        /// may be waiting — every controller shares one gate, so with
        /// another surface printing the second often fails and the next
        /// report passes the first.
        private func scrollbarReflectsLastScrollSend() -> Bool {
            let sent = smoothScroll.lastSend
            guard CACurrentMediaTime() - sent > Self.smoothScrollReportLag else { return false }
            if core.bridge.scrollbarStamp - sent > Self.smoothScrollReportLag { return true }
            return core.controller?.wakeupGate.isPending != true
        }

        func applyToSmoothScrollModel(_ pixels: Int, _ extent: TerminalSmoothScrollPosition.Extent) {
            guard pixels != 0 else { return }
            smoothScroll.position.scroll(by: pixels, in: extent)
            smoothScroll.lastSend = CACurrentMediaTime()
        }
    }
#endif
