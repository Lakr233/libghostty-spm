//
//  TerminalPinchFontZoom.swift
//  libghostty-spm
//

import CoreGraphics

/// A pinch read as font-size steps: one step per `scaleStep` of scale, kept
/// inside the gesture's own 4…64 range (Ghostty's is 1…255). Every platform
/// that pinches shares it, so a finger on an iPad, on a Mac's touch display
/// under Catalyst and under AppKit all zoom at the same rate.
struct TerminalPinchFontZoom {
    static let minFontSize: Float = 4
    static let maxFontSize: Float = 64
    static let scaleStep: CGFloat = 0.1

    /// The scale the steps taken so far add up to.
    private(set) var lastScale: CGFloat = 1

    mutating func begin(scale: CGFloat) {
        lastScale = scale
    }

    mutating func end() {
        lastScale = 1
    }

    /// The whole steps the pinch has moved since the last call: positive to
    /// grow, negative to shrink. The part of a step left over stays for the
    /// next call.
    mutating func takeSteps(at scale: CGFloat) -> Int {
        let steps = Int((scale - lastScale) / Self.scaleStep)
        lastScale += CGFloat(steps) * Self.scaleStep
        return steps
    }

    /// The binding action for one step from `fontSize`, nil at the limit.
    static func bindingAction(growing: Bool, from fontSize: Float) -> String? {
        if growing {
            return fontSize < maxFontSize ? "increase_font_size:1" : nil
        }
        return fontSize > minFontSize ? "decrease_font_size:1" : nil
    }
}
