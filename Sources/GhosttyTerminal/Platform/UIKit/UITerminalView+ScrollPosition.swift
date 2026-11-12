//
//  UITerminalView+ScrollPosition.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    /// The copy of the viewport position (`MomentumScrollState.position`)
    /// that the finger, the momentum, the wheel and system scrolling all
    /// advance; see `TerminalSmoothScrollPosition`.
    extension UITerminalView {
        /// A scrollbar report older than this against the last send may
        /// still describe the viewport before it.
        static let scrollReportLag: TimeInterval = 0.1

        func scrollExtent() -> TerminalSmoothScrollPosition.Extent? {
            guard let metrics = surface?.size() else { return nil }
            return TerminalSmoothScrollPosition.Extent(
                cellHeightPixels: metrics.cellHeightPixels,
                rows: metrics.rows,
                scrollbar: core.bridge.scrollbar,
            )
        }

        /// Brings the copy up to date with the engine before it is used
        /// (`TerminalSmoothScrollPosition.sync`).
        ///
        /// `adoptingBar: false` refreshes the extent and the bottom only and
        /// leaves the row to the copy. System scrolling passes it from
        /// `scrollViewDidScroll` and when aligning: there the content offset
        /// and the copy are a pair, brought to the engine together and only
        /// at rest (`systemScrollSyncFromEngine`). Changing the copy's row
        /// alone mid-scroll makes the next `scrollViewDidScroll` send the
        /// difference to the engine as if the finger had travelled it.
        @discardableResult
        func syncScrollModel(adoptingBar: Bool = true) -> TerminalSmoothScrollPosition.Extent? {
            guard let extent = scrollExtent() else { return nil }
            momentumScroll.position.sync(
                with: core.bridge.scrollbar,
                in: extent,
                trustingReport: adoptingBar && scrollbarReflectsLastSend(),
            )
            return extent
        }

        /// Whether the scrollbar in hand describes the viewport after the
        /// last delta sent.
        ///
        /// Time since the send is not enough. The report sits in Ghostty's
        /// mailbox until a main-thread tick reads it; after the main thread
        /// stalls for longer than the lag (a slow layout, a snapshot) the
        /// one in hand is from before the stall, and a copy corrected by it
        /// is a row off, with every later delta off by as much. So one more
        /// thing must hold: the report was read well after the send, when
        /// the renderer had long drawn that step; or no tick is waiting, so
        /// everything the engine posted has been read. Every controller
        /// shares one gate, so with another surface printing the second
        /// often fails, and the next report passes the first.
        private func scrollbarReflectsLastSend() -> Bool {
            let sent = momentumScroll.lastSend
            guard CACurrentMediaTime() - sent > Self.scrollReportLag else { return false }
            if core.bridge.scrollbarStamp - sent > Self.scrollReportLag { return true }
            return core.controller?.wakeupGate.isPending != true
        }

        /// Records a delta about to be sent: `pixels` toward the scrollback,
        /// negative toward the active area.
        func applyToScrollModel(_ pixels: Int, _ extent: TerminalSmoothScrollPosition.Extent) {
            guard pixels != 0 else { return }
            momentumScroll.position.scroll(by: pixels, in: extent)
            momentumScroll.lastSend = CACurrentMediaTime()
        }
    }
#endif
