//
//  TerminalSmoothScrollSettler.swift
//  libghostty-spm
//

import Foundation
import QuartzCore

/// Brings a viewport left between rows back to a whole row.
///
/// With smooth scrolling (Patches/ghostty/0022) a precision scroll can leave
/// the viewport part of a row past a row. Ghostty's hit testing and this
/// package's selection grid count in whole rows, so clicks, hover, links and
/// selection would land a row off: once the scrolling stops, the part of a
/// row left over is scrolled away, eased out over `snapDuration`.
///
/// Every precision scroll reaches it (`TerminalSurface.onPrecisionScroll`):
/// the trackpad, a Magic Mouse, a wheel on iPad or Mac Catalyst, a finger,
/// a glide, a host calling `sendMouseScroll`. A scroll with no gesture
/// around it — a wheel, an event with no phase, a host's call — is settled
/// once none has come for `idleDelay`. A view that knows a gesture is under
/// way holds the settler (`hold`), so nothing moves under a resting finger,
/// and releases it when the gesture and its glide are done.
///
/// The position comes from the engine each frame, so a scroll multiplier,
/// output arriving meanwhile or a resize cannot put it off: the snap aims at
/// a row in the scrollback and stops if the viewport moves away from it.
@MainActor
final class TerminalSmoothScrollSettler {
    /// How long precision scrolls must pause before an unheld viewport is
    /// brought to a row.
    static let idleDelay: TimeInterval = 0.12
    /// A hold that was never released (a gesture whose end got lost) still
    /// gives way after this long without a scroll.
    static let heldIdleDelay: TimeInterval = 1.0
    static let snapDuration: TimeInterval = 0.18
    static let snapInterval: TimeInterval = 1.0 / 120
    /// Once less than this is left of the eased curve, the snap takes the
    /// rest in one step. The engine keeps its fraction in a `Float`: eased
    /// up to within a millionth of a pixel of the next row, it rounded to
    /// a whole row and was dropped, and the viewport fell back a row.
    static let snapFinishPixels: Double = 0.01

    private let surface: () -> TerminalSurface?

    /// A gesture or a glide is moving the viewport.
    private(set) var isHeld = false
    /// The last precision scroll, positive toward the scrollback: which way
    /// the viewport was going, and how fast, when the scrolling stopped.
    private(set) var lastTravel: Double = 0
    private var settleToken = 0

    private(set) var snapTimer: Timer?
    /// The row the snap lands on, and the scroll it set out to make.
    private var snapRow = 0
    private var snapTotal: Double = 0
    private var snapStart: CFTimeInterval = 0

    init(surface: @escaping () -> TerminalSurface?) {
        self.surface = surface
    }

    var isSnapping: Bool {
        snapTimer != nil
    }

    /// A precision scroll went to the surface.
    func didScroll(up pixels: Double) {
        lastTravel = pixels
        cancelSnap()
        schedule(after: isHeld ? Self.heldIdleDelay : Self.idleDelay, followingTravel: !isHeld)
    }

    /// A gesture is moving the viewport: nothing settles until `release`.
    func hold() {
        isHeld = true
        settleToken += 1
        cancelSnap()
    }

    /// The gesture and its glide are over. `followingTravel`: on the way
    /// the viewport was going (it was still moving), or to the nearer row
    /// (it had been brought to a stop where it is).
    func release(after delay: TimeInterval = 0, followingTravel: Bool) {
        isHeld = false
        schedule(after: delay, followingTravel: followingTravel)
    }

    /// Stops a pending or running snap where it is.
    func cancel() {
        settleToken += 1
        cancelSnap()
    }

    /// To the nearer row at once: what comes next hit-tests in whole rows
    /// (a selection, a menu) or takes the view away.
    func settleNow() {
        cancel()
        isHeld = false
        guard let surface = surface(), let position = surface.smoothScrollPosition(),
              position.isAvailable, position.fraction != 0 else { return }
        surface.smoothScroll(byPixels: position.pixelsToNearestRow)
    }

    private func schedule(after delay: TimeInterval, followingTravel: Bool) {
        settleToken += 1
        let token = settleToken
        guard delay > 0 else {
            startSnap(followingTravel: followingTravel)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, token == self.settleToken else { return }
                self.isHeld = false
                self.startSnap(followingTravel: followingTravel)
            }
        }
    }

    private func startSnap(followingTravel: Bool) {
        cancelSnap()
        guard let position = surface()?.smoothScrollPosition(), position.isAvailable else { return }
        let total = position.pixelsToRow(following: followingTravel ? lastTravel : 0)
        guard total != 0 else { return }
        snapTotal = total
        // Back up to the row it is in, or down to the next one.
        snapRow = position.row + (total > 0 ? 0 : 1)
        snapStart = CACurrentMediaTime()
        TerminalDebugLog.log(.input, "smooth scroll snap \(String(format: "%.2f", total)) px")
        // The timer holds the settler weakly and stops itself once the
        // settler (and the view that owns it) is gone.
        let timer = Timer(timeInterval: Self.snapInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.snapTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        snapTimer = timer
    }

    /// One frame: whatever is still to go beyond the eased remainder. The
    /// last frame sends exactly what separates the viewport from the row.
    private func snapTick() {
        guard let surface = surface(), let position = surface.smoothScrollPosition(),
              position.isAvailable
        else {
            cancelSnap()
            return
        }
        let remaining = position.pixels(to: snapRow * position.cellHeight)
        guard remaining != 0 else {
            cancelSnap()
            return
        }
        // Moved by something else — output, a keybinding, a resize: the
        // row aimed at is no longer the one to land on.
        if abs(remaining) > abs(snapTotal) + 0.5 || remaining * snapTotal < 0 {
            cancelSnap()
            return
        }
        let progress = min(1, (CACurrentMediaTime() - snapStart) / Self.snapDuration)
        let wanted = snapTotal * pow(1 - progress, 3)
        let finishing = progress >= 1 || abs(wanted) < Self.snapFinishPixels
        let step = finishing ? remaining : remaining - wanted
        // Ahead of the curve, it waits for it rather than step back: a step
        // back across the row puts the engine just under a whole row
        // behind it, which it drops.
        if step * remaining > 0 {
            surface.smoothScroll(byPixels: step)
        }
        if finishing {
            cancelSnap()
        }
    }

    private func cancelSnap() {
        snapTimer?.invalidate()
        snapTimer = nil
    }
}
