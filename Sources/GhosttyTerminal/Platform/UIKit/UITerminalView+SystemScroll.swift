//
//  UITerminalView+SystemScroll.swift
//  libghostty-spm
//

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    import GhosttyKit
    import UIKit

    /// System-scrolling state; behavior lives in +SystemScroll,
    /// +SystemScrollSync, +SystemScrollAlign and +SystemScrollDelegate.
    ///
    /// One finger over scrollback is the system's scroll: a `UIScrollView`
    /// that is never seen, whose pan recognizer is attached to the terminal
    /// view. It tracks the finger, decelerates, bounces at the ends and
    /// picks up a moving scroll under a new touch, as every other scroll
    /// view does; its content offset is turned into whole-pixel deltas for
    /// the surface. The view's own pan keeps what a scroll view has no use
    /// for (see `systemPanWouldBegin`).
    struct SystemScrollState {
        var driver: TerminalScrollDriverView?
        /// The content offset is being written from the engine's position:
        /// `scrollViewDidScroll` must not send it back.
        var isSyncing = false
        /// UIKit is decelerating or bouncing after a lift: from
        /// `didEndDragging(willDecelerate: true)` to `didEndDecelerating`.
        /// Kept beside `isDecelerating` so it does not rest on that flag
        /// alone.
        var isUIKitMoving = false
        /// When `scrollViewDidScroll` last ran: the fallback for
        /// `isUIKitMoving` when no end callback comes.
        var lastDidScroll: CFTimeInterval = 0
        /// The alignment to a whole row, a display link writing the content
        /// offset frame by frame. Not `setContentOffset(_:animated:)`: that
        /// animation cannot be cancelled once it runs — setting the same
        /// offset again unanimated does not stop it — so under a finger
        /// that drags again it and the finger each write the offset every
        /// frame, and the picture jumps between the two.
        var alignLink: CADisplayLink?
        var alignFrom: CGFloat = 0
        var alignTo: CGFloat = 0
        var alignStart: CFTimeInterval = 0
        /// The end a screenful has been sent past, so the engine clamps
        /// there: -1 top, 1 bottom, 0 neither.
        var clampedEdge = 0
        /// Pixels the engine's position is ahead of the scroll view's:
        /// engine position = content offset (in pixels) + shift.
        ///
        /// Zero at rest. Output that arrives while the viewport follows the
        /// bottom under a finger or a bounce moves the engine down with the
        /// active area and lengthens the scrollback. The content size and
        /// offset cannot follow then without fighting UIKit's tracking, so
        /// the scroll view's bottom goes on standing for the engine's, the
        /// difference is kept here, and both are brought to the engine in
        /// one step once the scroll rests.
        var shiftPixels = 0
        /// Invalidates a pending resync (`systemScrollResyncSoon`).
        var resyncToken = 0
    }

    extension UITerminalView {
        /// There is scrollback for the scroll view to scroll, and no
        /// program is tracking the mouse.
        var systemScrollIsActive: Bool {
            guard systemScroll.driver != nil,
                  surface?.isMouseCaptured != true,
                  let bar = core.bridge.scrollbar, bar.total > bar.len else { return false }
            return true
        }

        /// A one-finger drag starting now is the scroll view's: the above,
        /// and no selection for the finger to extend. Two fingers, a drag
        /// with a selection, a program tracking the mouse and a screen with
        /// nothing to scroll back to stay with the view's own pan.
        var systemPanWouldBegin: Bool {
            systemScrollIsActive && touchSelection.range == nil
        }

        /// UIKit is decelerating or bouncing, or the alignment is running.
        var systemScrollInMotion: Bool {
            guard let driver = systemScroll.driver else { return false }
            return driver.isDecelerating || systemScroll.isUIKitMoving || systemScroll.alignLink != nil
        }

        /// Something is moving the scroll view: a finger down or dragging,
        /// deceleration, the alignment, or an offset still out of range (a
        /// bounce not done). While it is, nothing here writes the content
        /// offset or starts an alignment: two writers show as the picture
        /// jumping back and forth.
        var systemScrollIsBusy: Bool {
            systemScrollBusy(countingRecentScroll: true)
        }

        /// `countingRecentScroll`: a `scrollViewDidScroll` in the last 50 ms
        /// counts as motion — whatever else moves the scroll view without
        /// reporting deceleration. Not counted right after a deceleration
        /// or an alignment ends, when the engine has to be synced.
        /// `countingOutOfRange`: an offset out of range counts as motion.
        /// Not counted by the settle after a touch-down, which has to bring
        /// such an offset back.
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

        /// UIKit rounds a content offset to this many points: one over the
        /// screen's scale, which is not its native scale on every display
        /// (3 against 2.807 on one), so an offset in pixels can be off by a
        /// fraction of one.
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
            driver.delegate = self
            // Not content: nothing for VoiceOver or focus to find.
            driver.isAccessibilityElement = false
            driver.accessibilityElementsHidden = true
            driver.panGestureRecognizer.maximumNumberOfTouches = 1
            driver.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            driver.shouldBeginPan = { [weak self] in self?.systemPanWouldBegin ?? false }
            insertSubview(driver, at: 0)
            addGestureRecognizer(driver.panGestureRecognizer)
            systemScroll.driver = driver
        }

        func systemScrollMapping() -> TerminalScrollOffsetMapping? {
            guard let driver = systemScroll.driver, let extent = scrollExtent() else { return nil }
            let scale = resolvedDisplayScale()
            return TerminalScrollOffsetMapping(
                scale: scale,
                cellHeight: extent.cellHeight,
                screenRows: extent.screenRows,
                engineMax: extent.maxPixels,
                viewMax: max(0, driver.contentSize.height - driver.bounds.height) * scale,
                shift: systemScroll.shiftPixels,
            )
        }
    }
#endif
