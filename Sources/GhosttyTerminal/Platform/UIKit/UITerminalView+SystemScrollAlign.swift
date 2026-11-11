//
//  UITerminalView+SystemScrollAlign.swift
//  libghostty-spm
//

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    import GhosttyKit
    import UIKit

    /// Stopping the scroll view, and bringing it to a whole row with the
    /// view's own display-link animation (see `SystemScrollState.alignLink`).
    extension UITerminalView {
        static let systemScrollAlignDuration: TimeInterval = 0.25
        static let systemScrollAlignFrameRateRange = CAFrameRateRange(
            minimum: 80,
            maximum: 120,
            preferred: 120,
        )

        /// Stops a deceleration, a bounce or an alignment where it is.
        /// Returns whether there was one.
        @discardableResult
        func systemScrollStop() -> Bool {
            guard let driver = systemScroll.driver, systemScrollInMotion else { return false }
            systemScrollCancelAlign()
            if driver.isDecelerating || systemScroll.isUIKitMoving {
                // Setting the offset, unanimated, ends UIKit's deceleration.
                driver.setContentOffset(driver.contentOffset, animated: false)
            }
            systemScroll.isUIKitMoving = false
            return true
        }

        /// Stops the alignment at the frame it has reached.
        func systemScrollCancelAlign() {
            systemScroll.alignLink?.invalidate()
            systemScroll.alignLink = nil
        }

        /// Brings the content offset to the nearest whole row; the engine
        /// follows through `scrollViewDidScroll`. Nothing to do on a row.
        func systemScrollAlign(animated: Bool) {
            guard let driver = systemScroll.driver, let mapping = systemScrollMapping() else { return }
            // A finger is down: the pan writes the offset, and a lift
            // aligns again.
            guard !driver.isTracking, !driver.isDragging, !momentumScroll.panIsActive else { return }
            // The row is the copy's: one taken from the scrollbar here
            // would be sent to the engine by the alignment's first frame.
            syncScrollModel(adoptingBar: false)
            let position = momentumScroll.position.pixels(cellHeight: mapping.cellHeight)
            let aligned = mapping.nearestRow(enginePixels: position)
            let targetPixels = mapping.offsetPixels(enginePixels: aligned)
            let offsetPixels = driver.contentOffset.y * mapping.scale
            guard aligned != position || abs(offsetPixels - targetPixels) > 0.5 else { return }
            // An offset UIKit rounds to where it already is moves nothing
            // and brings no `scrollViewDidScroll`: align the engine alone.
            // The scroll view is then under half a pixel out.
            let targetPoints = targetPixels / mapping.scale
            if TerminalScrollOffsetMapping.rounds(targetPoints, onto: driver.contentOffset.y, unit: contentOffsetUnit) {
                if aligned != position, let extent = scrollExtent() {
                    surface?.sendMouseScroll(
                        x: 0,
                        y: Double(position - aligned),
                        mods: TerminalScrollModifiers(precision: true).rawValue,
                    )
                    applyToScrollModel(position - aligned, extent)
                }
                return
            }
            systemScrollCancelAlign()
            guard animated else {
                driver.contentOffset = CGPoint(x: 0, y: targetPoints)
                return
            }
            systemScroll.alignFrom = driver.contentOffset.y
            systemScroll.alignTo = targetPoints
            systemScroll.alignStart = 0
            let link = CADisplayLink(target: self, selector: #selector(systemScrollAlignFrame(_:)))
            link.preferredFrameRateRange = Self.systemScrollAlignFrameRateRange
            link.add(to: .main, forMode: .common)
            systemScroll.alignLink = link
        }

        /// One frame of the alignment, eased out; `scrollViewDidScroll`
        /// sends each step to the engine like any other.
        @objc func systemScrollAlignFrame(_ link: CADisplayLink) {
            guard let driver = systemScroll.driver, systemScroll.alignLink === link else {
                link.invalidate()
                return
            }
            if systemScroll.alignStart == 0 {
                systemScroll.alignStart = link.timestamp
            }
            let progress = min(1, CGFloat((link.targetTimestamp - systemScroll.alignStart) / Self.systemScrollAlignDuration))
            let eased = 1 - pow(1 - progress, 3)
            driver.contentOffset = CGPoint(
                x: 0,
                y: systemScroll.alignFrom + (systemScroll.alignTo - systemScroll.alignFrom) * eased,
            )
            if progress >= 1 {
                systemScrollCancelAlign()
                systemScrollSettled()
            }
        }
    }
#endif
