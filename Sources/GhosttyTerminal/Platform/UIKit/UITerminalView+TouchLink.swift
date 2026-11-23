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
            return hoveringLink(at: point, mods: .super_, on: surface) { $0.found }
        }

        /// A left click at `point` with `mods`. With Command alone it opens
        /// the link there, which Ghostty reports as `GHOSTTY_ACTION_OPEN_URL`.
        func sendCommandClick(at point: CGPoint, mods: TerminalInputModifiers, on surface: TerminalSurface) {
            hoveringLink(at: point, mods: mods, on: surface) { _ in
                surface.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, modifiers: mods)
                surface.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, modifiers: mods)
            }
        }

        /// Command-clicks the http or https link at `point`, and says whether
        /// there was one.
        func openWebLink(at point: CGPoint, on surface: TerminalSurface) -> Bool {
            hoveringLink(at: point, mods: .super_, on: surface) { link in
                guard let url = link.url,
                      url.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil
                else { return false }
                surface.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, modifiers: .super_)
                surface.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, modifiers: .super_)
                return true
            }
        }

        /// Ghostty looks for a link only when the pointer reaches another
        /// cell (`link_point`), and its apprt drops a move of under a pixel,
        /// so the pointer comes in from off the view and leaves again.
        private func hoveringLink<Result>(
            at point: CGPoint,
            mods: TerminalInputModifiers,
            on surface: TerminalSurface,
            _ body: (TerminalLinkProbe) -> Result,
        ) -> Result {
            let sent = surfacePoint(point)
            surface.sendMousePos(x: -1, y: -1, mods: GHOSTTY_MODS_NONE)
            core.bridge.linkProbe = TerminalLinkProbe()
            surface.sendMousePos(x: Double(sent.x), y: Double(sent.y), modifiers: mods)
            let result = body(core.bridge.linkProbe!)
            surface.sendMousePos(x: -1, y: -1, mods: GHOSTTY_MODS_NONE)
            core.bridge.linkProbe = nil
            return result
        }
    }
#endif
