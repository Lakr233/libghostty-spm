//
//  UITerminalView+SystemScrollAlign.swift
//  libghostty-spm
//

#if canImport(UIKit)
    #if !targetEnvironment(macCatalyst)
        import GhosttyKit
        import UIKit

        /// Stopping the scroll view, and bringing it to a whole row with the
        /// view's own display-link animation (see `SystemScrollState.alignLink`).
        extension UITerminalView {
            /// An alignment from rest; one that keeps a finger's speed is
            /// shorter (`TerminalScrollAlignmentCurve`).
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
                systemScroll.caughtDirection = systemScroll.motionDirection
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

            /// A lift slower than this (points per second) counts as a stop:
            /// its alignment goes to the nearest row.
            static let systemScrollAlignMinimumVelocity: CGFloat = 20

            /// Brings the content offset to a whole row; the engine follows
            /// through `scrollViewDidScroll`. Nothing to do on a row.
            ///
            /// To the nearest row, or ahead: `velocity` (points per second
            /// toward a larger offset) is how fast the finger still moved at a
            /// lift UIKit took for a stop, and the alignment goes on to the
            /// row ahead of it, setting off at that speed. An animated
            /// alignment after a touch stopped a moving scroll goes on the
            /// way that scroll went, from rest. An immediate one, for what
            /// hit-tests in whole rows next, moves least: the nearest row.
            ///
            /// `lifted`: called from `didEndDragging`, where the finger is up
            /// but UIKit still reports `isDragging`.
            func systemScrollAlign(animated: Bool, velocity: CGFloat = 0, lifted: Bool = false) {
                guard let driver = systemScroll.driver, let (mapping, position) = systemScrollMapping(),
                      position.isAvailable else { return }
                // A finger is down: the pan writes the offset, and a lift
                // aligns again.
                guard lifted || (!driver.isTracking && !driver.isDragging), !momentumScroll.panIsActive else { return }
                let travel = abs(velocity) < Self.systemScrollAlignMinimumVelocity ? 0 : velocity
                let caught = systemScroll.caughtDirection
                systemScroll.caughtDirection = 0
                let direction = travel != 0 ? travel : (animated ? caught : 0)
                let aligned = mapping.restingRow(enginePixels: position.pixels, travel: Double(direction))
                let targetPixels = mapping.offsetPixels(enginePixels: aligned)
                let offsetPixels = driver.contentOffset.y * mapping.scale
                guard Double(aligned) != position.pixels || abs(offsetPixels - targetPixels) > 0.5 else { return }
                // An offset UIKit rounds to where it already is moves nothing
                // and brings no `scrollViewDidScroll`: align the engine alone.
                // The scroll view is then under half a pixel out.
                let targetPoints = targetPixels / mapping.scale
                if TerminalScrollOffsetMapping.rounds(targetPoints, onto: driver.contentOffset.y, unit: contentOffsetUnit) {
                    surface?.smoothScroll(byPixels: position.pixels(to: aligned))
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
                systemScroll.alignCurve = TerminalScrollAlignmentCurve(
                    distance: targetPoints - driver.contentOffset.y,
                    velocity: travel,
                    longest: Self.systemScrollAlignDuration,
                )
                let link = CADisplayLink(target: self, selector: #selector(systemScrollAlignFrame(_:)))
                link.preferredFrameRateRange = Self.systemScrollAlignFrameRateRange
                link.add(to: .main, forMode: .common)
                systemScroll.alignLink = link
            }

            /// One frame of the alignment along its curve;
            /// `scrollViewDidScroll` sends each step to the engine like any
            /// other.
            @objc func systemScrollAlignFrame(_ link: CADisplayLink) {
                guard let driver = systemScroll.driver, systemScroll.alignLink === link else {
                    link.invalidate()
                    return
                }
                if systemScroll.alignStart == 0 {
                    systemScroll.alignStart = link.timestamp
                }
                let curve = systemScroll.alignCurve
                let progress = min(1, CGFloat((link.targetTimestamp - systemScroll.alignStart) / curve.duration))
                let eased = curve.value(at: progress)
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
#endif
