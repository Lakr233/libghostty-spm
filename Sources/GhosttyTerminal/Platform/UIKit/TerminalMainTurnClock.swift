//
//  TerminalMainTurnClock.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import Foundation
    import QuartzCore

    /// When the main run loop last woke.
    ///
    /// The system scroll waits in `scrollViewDidScroll` for the engine to
    /// hand over the frame that holds the step (`systemScrollWaitForFrame`),
    /// and how long it may wait has to be counted from where the turn
    /// began, not from where the wait did: the turn a finger comes down in
    /// spends several milliseconds delivering the touch first, and a whole
    /// budget on top of that misses the frame's commit. One run loop
    /// observer keeps the time of each wake. While the loop never sleeps
    /// between turns the time kept is an earlier one, which only makes the
    /// budget tighter.
    @MainActor
    enum TerminalMainTurnClock {
        private nonisolated(unsafe) static var wokeAt: CFTimeInterval = 0
        private static var installed = false

        static func install() {
            guard !installed else { return }
            installed = true
            wokeAt = CACurrentMediaTime()
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, 0) { _, _ in
                wokeAt = CACurrentMediaTime()
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        /// When this turn of the run loop began (`CACurrentMediaTime()`).
        static var turnStart: CFTimeInterval {
            wokeAt
        }
    }
#endif
