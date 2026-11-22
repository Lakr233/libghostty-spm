//
//  UITerminalView+SystemScroll.swift
//  libghostty-spm
//

#if canImport(UIKit)
    #if !targetEnvironment(macCatalyst)
        import GhosttyKit
        import QuartzCore
        import UIKit

        /// System-scrolling state; behavior lives in +SystemScroll,
        /// +SystemScrollSync, +SystemScrollAlign and +SystemScrollDelegate.
        ///
        /// One finger over scrollback is the system's scroll: a
        /// `UIScrollView` that is never seen, whose pan recognizer is
        /// attached to the terminal view. It tracks the finger, decelerates,
        /// bounces at the ends and picks up a moving scroll under a new
        /// touch, as every other scroll view does; its content offset moves
        /// the engine's viewport by the pixel
        /// (`TerminalSurface.smoothScroll(byPixels:)`, Patches/ghostty/0022).
        /// The view's own pan keeps what a scroll view has no use for (see
        /// `systemPanWouldBegin`).
        struct SystemScrollState {
            var driver: TerminalScrollDriverView?
            /// The scroll view's delegate. A separate object, not a
            /// conformance on the view: `UITerminalView` is open, and a
            /// host subclass may be a scroll view delegate itself.
            var delegate: TerminalScrollDriverDelegate?
            /// Fills the strip the rubber band uncovers with the terminal's
            /// background, so the bounce does not show what the host has
            /// behind the (clear) view.
            var overscrollFill: CALayer?
            /// The content offset is being written from the engine's
            /// position: `scrollViewDidScroll` must not send it back.
            var isSyncing = false
            /// UIKit is decelerating or bouncing after a lift: from
            /// `didEndDragging(willDecelerate: true)` to
            /// `didEndDecelerating`. Kept beside `isDecelerating` so it does
            /// not rest on that flag alone.
            var isUIKitMoving = false
            /// When `scrollViewDidScroll` last ran: the fallback for
            /// `isUIKitMoving` when no end callback comes.
            var lastDidScroll: CFTimeInterval = 0
            /// The alignment to a whole row, a display link writing the
            /// content offset frame by frame. Not
            /// `setContentOffset(_:animated:)`: that animation cannot be
            /// cancelled once it runs — setting the same offset again
            /// unanimated does not stop it — so under a finger that drags
            /// again it and the finger each write the offset every frame,
            /// and the picture jumps between the two.
            var alignLink: CADisplayLink?
            var alignFrom: CGFloat = 0
            var alignTo: CGFloat = 0
            var alignStart: CFTimeInterval = 0
            /// The alignment's duration and starting speed.
            var alignCurve = TerminalScrollAlignmentCurve(distance: 0, velocity: 0, longest: 0)
            /// A lift UIKit took for a stop (it reports no velocity under
            /// about 250 pt/s) while the finger still moved: the finger's
            /// speed, in points per second toward a larger offset, kept by
            /// `willEndDragging` for the alignment `didEndDragging` starts.
            var releaseVelocity: CGFloat = 0
            /// The way the content offset last moved (±1), and where it was:
            /// kept by `scrollViewDidScroll`.
            var motionDirection: CGFloat = 0
            var lastOffset: CGFloat = 0
            /// The way a glide, a bounce or an alignment was going when a
            /// touch stopped it. The animated alignment that follows goes to
            /// the row ahead that way: to the nearer row, half the time it
            /// went back against the glide.
            var caughtDirection: CGFloat = 0
            /// Pixels the engine's position is ahead of the scroll view's:
            /// engine position = content offset (in pixels) + shift.
            ///
            /// Zero at rest. Output that arrives while the viewport follows
            /// the bottom under a finger or a bounce moves the engine down
            /// with the active area and lengthens the scrollback. The
            /// content size and offset cannot follow then without fighting
            /// UIKit's tracking, so the scroll view's bottom goes on
            /// standing for the engine's, the difference is kept here, and
            /// both are brought to the engine in one step once the scroll
            /// rests.
            var shiftPixels = 0
            /// Invalidates a pending resync (`systemScrollResyncSoon`).
            var resyncToken = 0
        }

        extension UITerminalView {
            /// The engine would move this viewport by the pixel now: there
            /// is scrollback, and neither mouse reporting nor alternate
            /// scroll takes the scroll (Ghostty's own decision, so
            /// `mouse-reporting = false` counts).
            var systemScrollIsActive: Bool {
                systemScroll.driver != nil && surface?.smoothScrollPosition()?.isAvailable == true
            }

            /// A one-finger drag starting now is the scroll view's: the
            /// above, and no selection for the finger to extend. Two
            /// fingers, a drag with a selection, a program tracking the
            /// mouse and a screen with nothing to scroll back to stay with
            /// the view's own pan.
            var systemPanWouldBegin: Bool {
                systemScrollIsActive && touchSelection.range == nil
            }

            /// UIKit is decelerating or bouncing, or the alignment is
            /// running.
            var systemScrollInMotion: Bool {
                guard let driver = systemScroll.driver else { return false }
                return driver.isDecelerating || systemScroll.isUIKitMoving || systemScroll.alignLink != nil
            }

            /// Something is moving the scroll view: a finger down or
            /// dragging, deceleration, the alignment, or an offset still out
            /// of range (a bounce not done). While it is, nothing here
            /// writes the content offset or starts an alignment: two writers
            /// show as the picture jumping back and forth.
            var systemScrollIsBusy: Bool {
                systemScrollBusy(countingRecentScroll: true)
            }

            /// The scroll view moved in the last 0.1 s: a finger dragging,
            /// deceleration, a bounce and the alignment all write the offset
            /// every frame. What the coordinator's wakeups go by
            /// (`wakeupSkipsDraw`), not `systemScrollIsBusy`: that one also
            /// holds while an offset rests out of range or a flag is stuck,
            /// and a surface at rest would then never draw a wakeup. An
            /// offset the view writes itself (`isSyncing`) does not count.
            var systemScrollMovedRecently: Bool {
                systemScroll.driver != nil && CACurrentMediaTime() - systemScroll.lastDidScroll < 0.1
            }

            /// `countingRecentScroll`: a `scrollViewDidScroll` in the last
            /// 50 ms counts as motion — whatever else moves the scroll view
            /// without reporting deceleration. Not counted right after a
            /// deceleration or an alignment ends, when the engine has to be
            /// synced. `countingOutOfRange`: an offset out of range counts
            /// as motion. Not counted by the settle after a touch-down,
            /// which has to bring such an offset back.
            func systemScrollBusy(countingRecentScroll: Bool, countingOutOfRange: Bool = true) -> Bool {
                guard let driver = systemScroll.driver else { return false }
                if driver.isTracking || driver.isDragging || systemScrollInMotion || momentumScroll.panIsActive {
                    return true
                }
                if countingRecentScroll, CACurrentMediaTime() - systemScroll.lastDidScroll < 0.05 {
                    return true
                }
                guard countingOutOfRange else { return false }
                return TerminalScrollOffsetMapping.isOutOfRange(
                    offset: driver.contentOffset.y,
                    maxOffset: max(0, driver.contentSize.height - driver.bounds.height),
                    unit: contentOffsetUnit,
                )
            }

            var systemScrollIsOutOfRange: Bool {
                guard let driver = systemScroll.driver else { return false }
                return TerminalScrollOffsetMapping.isOutOfRange(
                    offset: driver.contentOffset.y,
                    maxOffset: max(0, driver.contentSize.height - driver.bounds.height),
                    unit: contentOffsetUnit,
                )
            }

            /// UIKit rounds a content offset to this many points: one over
            /// the screen's scale, which is not its native scale on every
            /// display (3 against 2.807 on one), so an offset in pixels can
            /// be off by a fraction of one.
            var contentOffsetUnit: CGFloat {
                #if !os(visionOS)
                    if let screen = window?.screen {
                        return 1 / screen.scale
                    }
                #endif
                let scale = traitCollection.displayScale
                return scale > 0 ? 1 / scale : 0.5
            }

            func installSystemScrollDriver() {
                guard systemScroll.driver == nil else { return }
                let driver = TerminalScrollDriverView(frame: bounds)
                driver.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                driver.backgroundColor = .clear
                driver.showsVerticalScrollIndicator = false
                driver.showsHorizontalScrollIndicator = false
                driver.contentInsetAdjustmentBehavior = .never
                driver.alwaysBounceVertical = false
                driver.alwaysBounceHorizontal = false
                driver.decelerationRate = .normal
                // A tap on the status bar scrolls the host's own scroll
                // view to the top; with two candidates UIKit scrolls
                // neither.
                driver.scrollsToTop = false
                let delegate = TerminalScrollDriverDelegate(view: self)
                driver.delegate = delegate
                // Not content: nothing for VoiceOver or focus to find.
                driver.isAccessibilityElement = false
                driver.accessibilityElementsHidden = true
                driver.panGestureRecognizer.maximumNumberOfTouches = 1
                driver.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                driver.shouldBeginPan = { [weak self] in self?.systemPanWouldBegin ?? false }
                insertSubview(driver, at: 0)
                addGestureRecognizer(driver.panGestureRecognizer)
                systemScroll.driver = driver
                systemScroll.delegate = delegate

                let fill = CALayer()
                fill.isHidden = true
                fill.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
                layer.insertSublayer(fill, at: 0)
                systemScroll.overscrollFill = fill
            }

            /// The mapping between the content offset and the engine's
            /// position, with that position as the engine has it now.
            func systemScrollMapping() -> (TerminalScrollOffsetMapping, TerminalSmoothScrollPosition)? {
                guard let driver = systemScroll.driver, let position = surface?.smoothScrollPosition() else {
                    return nil
                }
                let scale = resolvedDisplayScale()
                let mapping = TerminalScrollOffsetMapping(
                    scale: scale,
                    cellHeight: position.cellHeight,
                    engineMax: position.maxPixels,
                    viewMax: max(0, driver.contentSize.height - driver.bounds.height) * scale,
                    shift: systemScroll.shiftPixels,
                )
                return (mapping, position)
            }
        }
    #endif
#endif
