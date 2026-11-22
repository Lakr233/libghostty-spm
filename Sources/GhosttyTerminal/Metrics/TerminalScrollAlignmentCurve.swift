//
//  TerminalScrollAlignmentCurve.swift
//  libghostty-spm
//

import CoreGraphics
import Foundation

/// How an alignment to a whole row runs: a cubic that sets off at the speed
/// the scroll had (zero from rest) and arrives at rest, so the speed does
/// not jump where the alignment takes over.
///
/// The cubic ease-out `1 - (1 - p)^3` starts at three times its average
/// speed: aligning from a finger held still, or from a glide a touch had
/// stopped, the picture leapt to its fastest in the first frame. With a
/// `startSlope` (starting speed over average speed) of 0 this curve is
/// smoothstep; with 3 it is that ease-out, the fastest start that does not
/// overshoot the row, so a faster scroll shortens the duration instead.
struct TerminalScrollAlignmentCurve: Equatable {
    var duration: TimeInterval
    var startSlope: CGFloat

    /// The shortest an alignment that keeps a fast start may take.
    static let shortestDuration: TimeInterval = 0.1

    /// `distance` to the row and `velocity` of the scroll, in the same unit
    /// (per second); a velocity away from the row counts as rest. `longest`
    /// is the duration from rest.
    init(distance: CGFloat, velocity: CGFloat, longest: TimeInterval) {
        let speed = distance == 0 ? 0 : max(0, velocity * (distance < 0 ? -1 : 1))
        guard speed > 0 else {
            duration = longest
            startSlope = 0
            return
        }
        let span = abs(distance)
        // The duration whose ease-out starts at exactly this speed.
        duration = min(longest, max(Self.shortestDuration, Double(3 * span / speed)))
        startSlope = min(3, speed * CGFloat(duration) / span)
    }

    /// How far along its way the alignment is (0…1) at `progress` (0…1 of
    /// its duration): the cubic Hermite from 0 at `startSlope` to 1 at rest.
    func value(at progress: CGFloat) -> CGFloat {
        let u = min(max(0, progress), 1)
        let u2 = u * u
        let u3 = u2 * u
        return (u3 - 2 * u2 + u) * startSlope + (3 * u2 - 2 * u3)
    }
}
