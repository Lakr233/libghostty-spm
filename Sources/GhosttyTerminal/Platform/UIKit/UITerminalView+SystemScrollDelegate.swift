//
//  UITerminalView+SystemScrollDelegate.swift
//  libghostty-spm
//

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    import GhosttyKit
    import UIKit

    /// The hidden scroll view's delegate: its offset becomes whole-pixel
    /// deltas for the surface, its landing place a whole row.
    extension UITerminalView: UIScrollViewDelegate {
        public func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard scrollView === systemScroll.driver, !systemScroll.isSyncing,
                  let mapping = systemScrollMapping(), let extent = scrollExtent() else { return }
            systemScroll.lastDidScroll = CACurrentMediaTime()
            let offsetPixels = scrollView.contentOffset.y * mapping.scale
            // Out of the scroll view's own range is its rubber band.
            applyOverscroll(mapping.overscroll(offsetPixels: offsetPixels))
            let target = mapping.enginePixels(offsetPixels: offsetPixels)
            // The row is the copy's, not the scrollbar's: the engine is
            // sent what the content offset travelled and nothing else.
            syncScrollModel(adoptingBar: false)
            var delta = momentumScroll.position.pixels(cellHeight: extent.cellHeight) - target
            // Entering a bounce, send a screenful more: the engine clamps
            // at the end and drops its fraction, and a copy a few rows out
            // (output was arriving) is put right by the same step.
            let edge = mapping.edge(offsetPixels: offsetPixels, enginePixels: target)
            if edge != 0, systemScroll.clampedEdge != edge {
                delta += edge < 0 ? mapping.screenPixels : -mapping.screenPixels
            }
            systemScroll.clampedEdge = edge
            if delta != 0 {
                let mods = TerminalScrollModifiers(precision: true, momentum: systemScrollInMotion ? .changed : .none)
                surface?.sendMouseScroll(x: 0, y: Double(delta), mods: mods.rawValue)
                applyToScrollModel(delta, extent)
            }
        }

        public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            guard scrollView === systemScroll.driver else { return }
            TerminalDebugLog.log(.input, "system scroll drag began")
            // The view's own momentum (the two-finger scroll's) may still
            // be running; UIKit has stopped its own deceleration itself.
            if momentumScroll.displayLink != nil {
                stopMomentumScrolling(settle: .none)
            }
            systemScrollCancelAlign()
            systemScroll.isUIKitMoving = false
            momentumScroll.panIsActive = true
            momentumScroll.settleToken += 1
            softwareKeyboard.tapCandidateArmed = false
            if !usesInlineTextSelection {
                dismissTouchSelection(restoringViewport: false)
            }
        }

        /// The landing place becomes a whole row, and UIKit decelerates
        /// to it.
        public func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity _: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>,
        ) {
            guard scrollView === systemScroll.driver, let mapping = systemScrollMapping() else { return }
            // Rounded in the engine's rows (offset + shift), then back.
            targetContentOffset.pointee.y = mapping.landingOffset(proposed: targetContentOffset.pointee.y)
        }

        public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard scrollView === systemScroll.driver else { return }
            momentumScroll.panIsActive = false
            if decelerate {
                systemScroll.isUIKitMoving = true
                systemScroll.lastDidScroll = CACurrentMediaTime()
                watchUIKitMotion()
            } else {
                // No deceleration — hardly moved, or already at the landing
                // place: the alignment is ours.
                systemScrollAlign(animated: true)
                systemScrollResyncSoon()
            }
        }

        /// The fallback for `isUIKitMoving`: every quarter second, a scroll
        /// view that is not decelerating and has not scrolled since is
        /// taken to have finished. `didEndDecelerating` normally comes
        /// first.
        private func watchUIKitMotion() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, systemScroll.isUIKitMoving, let driver = systemScroll.driver else { return }
                if driver.isDecelerating || CACurrentMediaTime() - systemScroll.lastDidScroll < 0.25 {
                    watchUIKitMotion()
                    return
                }
                systemScroll.isUIKitMoving = false
                systemScrollSettled()
            }
        }

        public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            guard scrollView === systemScroll.driver else { return }
            systemScroll.isUIKitMoving = false
            systemScrollSettled()
        }

        /// Nothing here animates the offset through UIKit; a tap on the
        /// status bar (`scrollsToTop`) ends up here.
        public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            guard scrollView === systemScroll.driver else { return }
            systemScroll.isUIKitMoving = false
            systemScrollSettled()
        }

        /// Every finger is up and none dragged: a tap, or a hold. UIKit
        /// stopped its deceleration the moment the finger came down — what
        /// lets a new drag carry on from a moving scroll — and no delegate
        /// call says it stopped between rows. Align shortly unless a drag
        /// follows.
        func systemScrollTouchEnded() {
            guard systemScroll.driver != nil, !momentumScroll.panIsActive else { return }
            settleScrollSoon()
        }
    }
#endif
