//
//  UITerminalView+SystemScrollSync.swift
//  libghostty-spm
//

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    import GhosttyKit
    import UIKit

    /// Bringing the scroll view and the copy of the viewport position to
    /// the engine at rest, and showing UIKit's rubber band.
    extension UITerminalView {
        /// The engine changed — the scrollbar, the cell height, the view's
        /// size: the content size follows, and with nothing scrolling so
        /// does the content offset. Output at the bottom moves the bottom
        /// down and the offset with it; up in the scrollback the engine's
        /// row stays, so the offset does too and only the range grows.
        func systemScrollSyncFromEngine(afterMotion: Bool = false) {
            guard let driver = systemScroll.driver, bounds.height > 0, let extent = scrollExtent() else { return }
            let scale = resolvedDisplayScale()
            let engineMax = extent.maxPixels
            let size = CGSize(width: bounds.width, height: bounds.height + CGFloat(engineMax) / scale)
            if systemScrollBusy(countingRecentScroll: !afterMotion) {
                // Mid-scroll the content offset is UIKit's. When the
                // scrollback grew:
                // - the engine follows the bottom: the content size stays
                //   too, and the difference goes into the shift;
                // - the engine is up in the scrollback: its row has not
                //   moved, there is only more room below, and the content
                //   size is widened.
                let viewMax = Int((max(0, driver.contentSize.height - driver.bounds.height) * scale).rounded())
                if momentumScroll.position.isAtBottom {
                    systemScroll.shiftPixels = engineMax - viewMax
                } else if driver.contentSize.height < size.height {
                    systemScroll.isSyncing = true
                    driver.contentSize = CGSize(
                        width: size.width,
                        height: size.height - CGFloat(systemScroll.shiftPixels) / scale,
                    )
                    systemScroll.isSyncing = false
                }
                return
            }
            syncScrollModel()
            let target = CGFloat(momentumScroll.position.pixels(cellHeight: extent.cellHeight)) / scale
            systemScroll.isSyncing = true
            if driver.contentSize != size {
                driver.contentSize = size
            }
            if abs(driver.contentOffset.y - target) > 0.001 || driver.contentOffset.x != 0 {
                driver.contentOffset = CGPoint(x: 0, y: target)
            }
            systemScroll.isSyncing = false
            // `scrollViewDidScroll` was held off by `isSyncing`, so the
            // overscroll it would have cleared is cleared here.
            applyOverscroll(0)
            systemScroll.shiftPixels = 0
            systemScroll.clampedEdge = 0
        }

        /// Shows the scroll view's rubber band by moving the view's
        /// sublayers, as a scroll view moves its content, so the renderer
        /// draws no frame for it; the strip uncovered is the view's own
        /// background. Whole pixels: a layer moved by part of one is
        /// resampled, and the text blurs for as long as the bounce lasts.
        func applyOverscroll(_ shown: CGFloat) {
            let pixels = shown.rounded()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayerTransform = pixels == 0
                ? CATransform3DIdentity
                : CATransform3DMakeTranslation(0, pixels / resolvedDisplayScale(), 0)
            CATransaction.commit()
        }

        /// A deceleration or an alignment has ended. Output on the way, or
        /// the top of the scrollback trimmed, can have moved the landing
        /// place off a row: align once more if so.
        func systemScrollSettled() {
            // The end callback can come after a finger is dragging again;
            // its lift aligns.
            if let driver = systemScroll.driver, driver.isTracking || driver.isDragging || momentumScroll.panIsActive {
                return
            }
            systemScroll.clampedEdge = 0
            systemScrollAlign(animated: true)
            if systemScroll.alignLink == nil {
                systemScrollSyncFromEngine(afterMotion: true)
            }
            systemScrollResyncSoon()
        }

        /// The scrollbar changed.
        func systemScrollBarChanged() {
            let busy = systemScrollIsBusy
            systemScrollSyncFromEngine()
            // Scrolling, or a delta only just sent, so that the report
            // cannot be placed: sync again at rest.
            if busy || CACurrentMediaTime() - momentumScroll.lastSend <= Self.scrollReportLag {
                systemScrollResyncSoon()
            }
        }

        /// Brings the copy and the content offset to the engine once more,
        /// a little later, at rest and with every report read.
        ///
        /// Mid-scroll the copy ignores the scrollbar (`syncScrollModel`).
        /// When something else moved the viewport meanwhile — the top of a
        /// full scrollback trimmed, typing that returns to the bottom — the
        /// copy and the offset are rows away from the engine, and with no
        /// further report nothing would correct them. The engine does not
        /// move for this, only the two numbers here, so nothing jumps.
        func systemScrollResyncSoon(retries: Int = 6) {
            systemScroll.resyncToken += 1
            let token = systemScroll.resyncToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, systemScroll.resyncToken == token else { return }
                // Still scrolling: its end asks again.
                guard !systemScrollIsBusy else { return }
                // A tick is waiting, so reports are unread — the gate is
                // shared, and a surface printing in the background keeps it
                // taken. Try again shortly, a few times.
                if retries > 0, core.controller?.wakeupGate.isPending == true {
                    systemScrollResyncSoon(retries: retries - 1)
                    return
                }
                systemScrollSyncFromEngine()
            }
        }
    }
#endif
