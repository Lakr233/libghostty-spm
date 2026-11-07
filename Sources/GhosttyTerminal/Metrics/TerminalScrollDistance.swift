//
//  TerminalScrollDistance.swift
//  libghostty-spm
//

import CoreGraphics

/// Ghostty reads a precision scroll delta as device pixels and divides it
/// by the cell height in pixels, with no content scale applied. A delta in
/// view points therefore has to be scaled to pixels, or the content moves
/// at a different speed from the finger or wheel on every display scale
/// but one.
enum TerminalScrollDistance {
    static func scrollPixels(for delta: CGPoint, displayScale: CGFloat) -> CGPoint {
        CGPoint(x: delta.x * displayScale, y: delta.y * displayScale)
    }
}
