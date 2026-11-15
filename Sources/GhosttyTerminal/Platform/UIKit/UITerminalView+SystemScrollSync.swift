//
//  UITerminalView+SystemScrollSync.swift
//  libghostty-spm
//

#if canImport(UIKit)
    #if !targetEnvironment(macCatalyst)
        import GhosttyKit
        import QuartzCore
        import UIKit

        /// Bringing the scroll view to the engine at rest, and showing
        /// UIKit's rubber band.
        extension UITerminalView {
            /// The engine changed — the scrollbar, the cell height, the
            /// view's size: the content size follows, and with nothing
            /// scrolling so does the content offset. Output at the bottom
            /// moves the bottom down and the offset with it; up in the
            /// scrollback the engine's row stays, so the offset does too and
            /// only the range grows.
            func systemScrollSyncFromEngine(afterMotion: Bool = false) {
                guard let driver = systemScroll.driver, bounds.height > 0,
                      let position = surface?.smoothScrollPosition() else { return }
                let scale = resolvedDisplayScale()
                let engineMax = position.maxPixels
                let size = CGSize(width: bounds.width, height: bounds.height + CGFloat(engineMax) / scale)
                if systemScrollBusy(countingRecentScroll: !afterMotion) {
                    // Mid-scroll the content offset is UIKit's. When the
                    // scrollback grew:
                    // - the engine follows the bottom: the content size
                    //   stays too, and the difference goes into the shift;
                    // - the engine is up in the scrollback: its row has not
                    //   moved, there is only more room below, and the
                    //   content size is widened.
                    let viewMax = Int((max(0, driver.contentSize.height - driver.bounds.height) * scale).rounded())
                    if position.isAtBottom {
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
                let target = CGFloat(position.pixels) / scale
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
            }

            /// Shows the scroll view's rubber band by moving the view's
            /// sublayers, as a scroll view moves its content, so the
            /// renderer draws no frame for it. Whole pixels: a layer moved
            /// by part of one is resampled, and the text blurs for as long
            /// as the bounce lasts.
            ///
            /// The strip the content uncovers is filled with the terminal's
            /// background (`SystemScrollState.overscrollFill`, a sublayer
            /// kept just outside the bounds on the uncovered side, so the
            /// same translation brings it in): the view is clear, and the
            /// host's own content behind it showed through the gap.
            func applyOverscroll(_ shown: CGFloat) {
                let pixels = shown.rounded()
                let points = pixels / resolvedDisplayScale()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.sublayerTransform = pixels == 0
                    ? CATransform3DIdentity
                    : CATransform3DMakeTranslation(0, points, 0)
                if let fill = systemScroll.overscrollFill {
                    fill.isHidden = pixels == 0
                    if pixels != 0 {
                        let height = abs(points)
                        fill.frame = CGRect(
                            x: 0,
                            y: points > 0 ? -height : bounds.height,
                            width: bounds.width,
                            height: height,
                        )
                        fill.backgroundColor = terminalBackgroundColor.cgColor
                    }
                }
                CATransaction.commit()
            }

            /// The terminal's background, as the config resolved it.
            private var terminalBackgroundColor: UIColor {
                let color = core.controller?.backgroundColor ?? TerminalColor(red: 0, green: 0, blue: 0)
                return UIColor(
                    red: CGFloat(color.red) / 255,
                    green: CGFloat(color.green) / 255,
                    blue: CGFloat(color.blue) / 255,
                    alpha: 1,
                )
            }

            /// A deceleration or an alignment has ended. Output on the way,
            /// or the top of the scrollback trimmed, can have moved the
            /// landing place off a row: align once more if so.
            func systemScrollSettled() {
                // The end callback can come after a finger is dragging
                // again; its lift aligns.
                if let driver = systemScroll.driver, driver.isTracking || driver.isDragging || momentumScroll.panIsActive {
                    return
                }
                systemScrollAlign(animated: true)
                if systemScroll.alignLink == nil {
                    systemScrollSyncFromEngine(afterMotion: true)
                }
            }

            /// The scrollbar changed.
            func systemScrollBarChanged() {
                let busy = systemScrollIsBusy
                systemScrollSyncFromEngine()
                // Scrolling: the content size may have been left for the
                // scroll's end, which a report coming after it would not
                // see. Sync once more at rest.
                if busy {
                    systemScrollResyncSoon()
                }
            }

            /// Brings the content offset to the engine once more, a little
            /// later and at rest. The engine is read directly, so nothing
            /// waits for a report.
            func systemScrollResyncSoon() {
                systemScroll.resyncToken += 1
                let token = systemScroll.resyncToken
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, systemScroll.resyncToken == token else { return }
                    // Still scrolling: its end syncs.
                    guard !systemScrollIsBusy else { return }
                    systemScrollSyncFromEngine()
                }
            }
        }
    #endif
#endif
