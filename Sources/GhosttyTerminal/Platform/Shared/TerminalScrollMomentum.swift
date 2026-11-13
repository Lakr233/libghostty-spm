//
//  TerminalScrollMomentum.swift
//  libghostty-spm
//

import CoreGraphics
import Foundation

/// The glide after a finger lifts off a scroll, for a view that has to
/// produce it itself: a pan recognizer reports the velocity at the lift and
/// nothing after it. Velocity and distance are in view points, y in the
/// direction the caller scrolls.
struct TerminalScrollMomentum {
    /// Below this speed on both axes (points per second) there is no glide.
    static let minimumSpeed: CGFloat = 50
    /// What is left of the velocity after 1/60 s.
    static let decayPerFrame: Double = 0.92
    /// A stalled run loop must not turn into one long jump.
    static let longestStep: TimeInterval = 0.1

    private(set) var velocity: CGPoint

    /// Nil when the lift was too slow to glide.
    init?(velocity: CGPoint) {
        guard Self.isMoving(velocity) else { return nil }
        self.velocity = velocity
    }

    /// The distance covered in the next `interval` seconds, nil once the
    /// glide has run out. The decay is scaled to the interval, so a flick
    /// travels the same distance whatever the tick rate.
    mutating func advance(by interval: TimeInterval) -> CGPoint? {
        let step = min(max(0, interval), Self.longestStep)
        let decay = CGFloat(pow(Self.decayPerFrame, step * 60))
        velocity.x *= decay
        velocity.y *= decay
        guard Self.isMoving(velocity) else { return nil }
        return CGPoint(x: velocity.x * step, y: velocity.y * step)
    }

    private static func isMoving(_ velocity: CGPoint) -> Bool {
        abs(velocity.x) >= minimumSpeed || abs(velocity.y) >= minimumSpeed
    }
}
