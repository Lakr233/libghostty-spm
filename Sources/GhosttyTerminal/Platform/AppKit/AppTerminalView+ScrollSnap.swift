//
//  AppTerminalView+ScrollSnap.swift
//  libghostty-spm
//

#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    import GhosttyKit

    /// Snapping a trackpad scroll to a whole row when it ends; the timer and
    /// its progress live in `SmoothScrollState` (+SmoothScroll).
    extension AppTerminalView {
        static let smoothScrollSnapDuration: TimeInterval = 0.18

        func cancelScrollSettle() {
            smoothScroll.settleToken += 1
            smoothScroll.snapTimer?.invalidate()
            smoothScroll.snapTimer = nil
        }

        func settleScrollSoon(after delay: TimeInterval) {
            smoothScroll.settleToken += 1
            let token = smoothScroll.settleToken
            guard delay > 0 else {
                snapScrollToRow()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, token == smoothScroll.settleToken else { return }
                snapScrollToRow()
            }
        }

        /// Scrolls the part of a row left over to a whole row — the one
        /// the viewport was going toward, or the nearer one when it had
        /// stopped (`SmoothScrollState.snapFollowsTravel`) — in whole
        /// pixels, eased out over `smoothScrollSnapDuration`.
        func snapScrollToRow() {
            smoothScroll.snapTimer?.invalidate()
            smoothScroll.snapTimer = nil
            guard !isMouseCaptured, let extent = smoothScrollExtent(), extent.maxRow > 0 else { return }
            syncSmoothScrollModel(extent)
            guard smoothScroll.position.fraction != 0 else { return }
            smoothScroll.snapTotal = smoothScroll.position.pixelsToRow(
                following: smoothScroll.snapFollowsTravel ? smoothScroll.lastDelta : 0,
                cellHeight: extent.cellHeight,
            )
            smoothScroll.snapSent = 0
            smoothScroll.snapStart = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.snapScrollTick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            smoothScroll.snapTimer = timer
        }

        private func snapScrollTick() {
            guard let extent = smoothScrollExtent() else {
                cancelScrollSettle()
                return
            }
            let total = smoothScroll.snapTotal
            let progress = min(1, (CACurrentMediaTime() - smoothScroll.snapStart) / Self.smoothScrollSnapDuration)
            let target = progress >= 1 ? total : Int((Double(total) * (1 - pow(1 - progress, 3))).rounded())
            let delta = target - smoothScroll.snapSent
            if delta != 0 {
                smoothScroll.snapSent = target
                applyToSmoothScrollModel(delta, extent)
                surface?.sendMouseScroll(
                    x: 0,
                    y: Double(delta),
                    mods: TerminalScrollModifiers(precision: true).rawValue,
                )
            }
            if progress >= 1 {
                smoothScroll.snapTimer?.invalidate()
                smoothScroll.snapTimer = nil
            }
        }
    }
#endif
