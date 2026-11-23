//
//  UITerminalView+TouchLink.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    extension UITerminalView {
        func touchLinkExists(at point: CGPoint) -> Bool {
            guard let surface, !surface.isMouseCaptured else { return false }
            return hoveringLink(at: point, mods: .super_, on: surface) {}
        }

        /// A left click at `point` with `mods`. With Command alone it opens
        /// the link there, which Ghostty reports as `GHOSTTY_ACTION_OPEN_URL`.
        func sendCommandClick(at point: CGPoint, mods: TerminalInputModifiers, on surface: TerminalSurface) {
            hoveringLink(at: point, mods: mods, on: surface) {
                surface.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, modifiers: mods)
                surface.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, modifiers: mods)
            }
        }

        /// Ghostty looks for a link only when the pointer reaches another
        /// cell (`link_point`), and its apprt drops a move of under a pixel,
        /// so the pointer comes in from off the view and leaves again.
        @discardableResult
        private func hoveringLink(
            at point: CGPoint,
            mods: TerminalInputModifiers,
            on surface: TerminalSurface,
            _ body: () -> Void,
        ) -> Bool {
            let sent = surfacePoint(point)
            surface.sendMousePos(x: -1, y: -1, mods: GHOSTTY_MODS_NONE)
            core.bridge.linkProbe = false
            surface.sendMousePos(x: Double(sent.x), y: Double(sent.y), modifiers: mods)
            let found = core.bridge.linkProbe == true
            body()
            surface.sendMousePos(x: -1, y: -1, mods: GHOSTTY_MODS_NONE)
            core.bridge.linkProbe = nil
            return found
        }
    }
#endif
