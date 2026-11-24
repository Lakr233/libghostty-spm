//
//  TerminalTouchResampler.swift
//  libghostty-spm
//

import CoreGraphics
import Foundation

/// Where a finger is at each display refresh, from the positions a gesture
/// recognizer reported at times of its own.
///
/// UIKit hands touches over once a refresh; AppKit's recognizers report a
/// finger on a touch display whenever its events arrive. Scrolled straight
/// from those, a refresh with no report shows the picture standing still
/// and the next one shows two steps: every other frame at 60 reports a
/// second on a 120 Hz display, one frame in six at 100, a few in a hundred
/// at 119 or 125, and all of them when reports arrive two at a time.
///
/// So the view scrolls once a refresh, to where the finger was `latency`
/// before it: between two reports when one arrived since, otherwise on from
/// the last one at the finger's speed, for no longer than the reports are
/// apart. Positions are whatever the caller adds up — here the pan's
/// translation since it began, in view points.
struct TerminalTouchResampler {
    /// How far behind the refresh the finger is read. A report from the
    /// last few milliseconds is then one to read between, not past.
    static let latency: TimeInterval = 0.005
    /// The longest a position is carried on past the last report.
    static let longestPrediction: TimeInterval = 0.017
    /// Reports further apart than this say nothing about the finger's
    /// speed: it rested in between.
    static let longestGap: TimeInterval = 0.05
    /// Reports closer than this arrived together. Their times are when
    /// they were handed over, not when the finger was there, so only the
    /// last of them is a position at that time.
    static let shortestGap: TimeInterval = 0.001

    private var samples: [(time: TimeInterval, position: CGPoint)] = []
    private var handedOut: CGPoint = .zero

    /// Forgets the gesture before: positions start from zero again.
    mutating func begin() {
        samples.removeAll(keepingCapacity: true)
        handedOut = .zero
    }

    mutating func add(_ position: CGPoint, at time: TimeInterval) {
        if let last = samples.last, time - last.time < Self.shortestGap {
            samples[samples.count - 1].position = position
            return
        }
        samples.append((time, position))
        if samples.count > 8 {
            samples.removeFirst()
        }
    }

    /// How far back the finger's speed at the lift is taken from: three
    /// refreshes of a 120 Hz display.
    static let velocityWindow: TimeInterval = 0.025

    /// The finger's velocity at `time`, points per second: how far it came
    /// in the `velocityWindow` before it, a finger that has sent nothing
    /// since its last report having stayed where that left it. Nil with
    /// too little to tell from: reports that span less than half the
    /// window — one of them, or a gesture handed over all at once.
    ///
    /// What a glide sets off at, instead of `NSPanGestureRecognizer`'s own
    /// `velocity(in:)`. On a touch display that one is a running average,
    /// a fifth of each report's speed added to four fifths of what it was,
    /// and it stops where the reports stop: a finger that slowed to a
    /// standstill and lifted was still reported at several times the
    /// speed of its last two reports (nine recordings from a MacBook Pro's
    /// touch display: 1.7 to 15 times, eight of them over the speed a
    /// glide needs), and the text that had come to rest under it set off
    /// again.
    func velocity(at time: TimeInterval) -> CGPoint? {
        guard let last = samples.last, let first = samples.first,
              last.time - first.time >= Self.velocityWindow / 2 else { return nil }
        let from = time - Self.velocityWindow
        var start = first.position
        if from >= last.time {
            start = last.position
        } else if from > first.time {
            for index in 1 ..< samples.count where samples[index].time >= from {
                let before = samples[index - 1], after = samples[index]
                let part = CGFloat((from - before.time) / (after.time - before.time))
                start = CGPoint(
                    x: before.position.x + (after.position.x - before.position.x) * part,
                    y: before.position.y + (after.position.y - before.position.y) * part,
                )
                break
            }
        }
        // Reports that span less than the window say how fast over what
        // they span.
        let span = CGFloat(min(Self.velocityWindow, time - first.time))
        guard span > 0 else { return nil }
        return CGPoint(x: (last.position.x - start.x) / span, y: (last.position.y - start.y) / span)
    }

    /// Where the finger was `latency` before `refresh`. Nil before the
    /// first report.
    func position(at refresh: TimeInterval) -> CGPoint? {
        guard let last = samples.last else { return nil }
        let time = refresh - Self.latency
        if time <= last.time {
            for index in stride(from: samples.count - 1, to: 0, by: -1) {
                let from = samples[index - 1], to = samples[index]
                guard time >= from.time else { continue }
                let part = CGFloat((time - from.time) / (to.time - from.time))
                return CGPoint(
                    x: from.position.x + (to.position.x - from.position.x) * part,
                    y: from.position.y + (to.position.y - from.position.y) * part,
                )
            }
            return samples[0].position
        }
        guard samples.count >= 2 else { return last.position }
        let previous = samples[samples.count - 2]
        let gap = last.time - previous.time
        guard gap >= Self.shortestGap, gap <= Self.longestGap else { return last.position }
        let ahead = CGFloat(min(time - last.time, gap, Self.longestPrediction) / gap)
        return CGPoint(
            x: last.position.x + (last.position.x - previous.position.x) * ahead,
            y: last.position.y + (last.position.y - previous.position.y) * ahead,
        )
    }

    /// The scroll to make at this refresh: from what was handed out so far
    /// to where the finger is now, in whole steps of `grid` when one is
    /// given. A touch display reports whole pixels, and so does this: a
    /// position between two reports is not on one. Never against the way
    /// the finger last moved — a position carried on past a finger that
    /// slowed down waits for it instead of going back.
    mutating func advance(to refresh: TimeInterval, grid: CGFloat = 0) -> CGPoint {
        guard var position = position(at: refresh), let last = samples.last else { return .zero }
        if grid > 0 {
            position.x = (position.x / grid).rounded() * grid
            position.y = (position.y / grid).rounded() * grid
        }
        let before = samples.count >= 2 ? samples[samples.count - 2].position : .zero
        var step = CGPoint(x: position.x - handedOut.x, y: position.y - handedOut.y)
        if step.x * (last.position.x - before.x) < 0 { step.x = 0 }
        if step.y * (last.position.y - before.y) < 0 { step.y = 0 }
        handedOut.x += step.x
        handedOut.y += step.y
        return step
    }

    /// The scroll that brings what was handed out to the last report
    /// exactly: the lift, or a report with no refresh to wait for.
    mutating func finish() -> CGPoint {
        guard let last = samples.last else { return .zero }
        let step = CGPoint(x: last.position.x - handedOut.x, y: last.position.y - handedOut.y)
        handedOut = last.position
        return step
    }
}
