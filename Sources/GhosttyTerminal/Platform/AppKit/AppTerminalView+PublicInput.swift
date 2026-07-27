//
//  AppTerminalView+PublicInput.swift
//  libghostty-spm
//
//  Public wrappers around `TerminalSurface` write paths so hosts can
//  inject bytes into the pty without reaching for internal API.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    extension AppTerminalView {
        /// Send raw UTF-8 text directly to the underlying pty (bypassing
        /// key translation). Use this for synthetic input like `\x1b[Z`
        /// (Shift+Tab / CSI Z) or multi-line paste-style injections.
        /// No-op when the surface has not been created yet.
        public func sendText(_ text: String) {
            surface?.sendText(text)
        }

        /// Invoke a named Ghostty binding action (e.g. "copy_to_clipboard",
        /// "clear_screen"). Returns true when the action dispatched.
        @discardableResult
        public func performBindingAction(_ action: String) -> Bool {
            surface?.performBindingAction(action) ?? false
        }

        /// Resolve Ghostty's link target at a view-local point without
        /// sending a mouse button event.
        ///
        /// The embedded C API has no direct link query. Its existing hover
        /// action does expose the resolved regex/OSC 8 target, so this performs
        /// a modifier-aware pointer probe and captures that callback. Shift is
        /// included only while a child TUI owns the mouse; Ghostty strips it
        /// when escaping capture, leaving the Command modifier expected by its
        /// link matcher.
        public func linkTarget(at point: CGPoint) -> String? {
            guard bounds.contains(point), let surface else { return nil }

            let x = point.x
            let y = bounds.height - point.y
            let mouseCaptured = surface.isMouseCaptured
            var probeModifiers: TerminalInputModifiers = [.super_]
            if mouseCaptured {
                probeModifiers.insert(.shift)
            }

            // libghostty's embedded adapter intentionally drops same-position
            // pointer events even when only modifiers changed. An outside
            // point makes the target event observable without a button press.
            core.bridge.hoveredLink = nil
            surface.sendMousePos(
                x: -1,
                y: -1,
                mods: probeModifiers.ghosttyMods
            )
            surface.sendMousePos(
                x: x,
                y: y,
                mods: probeModifiers.ghosttyMods
            )
            let target = core.bridge.hoveredLink

            // Restore the effective modifier/hover state. Shift bypasses TUI
            // mouse capture and is stripped by Ghostty, so this reset doesn't
            // synthesize a click or selection in either ownership mode.
            let restoreModifiers: TerminalInputModifiers =
                mouseCaptured ? [.shift] : []
            surface.sendMousePos(
                x: -1,
                y: -1,
                mods: restoreModifiers.ghosttyMods
            )
            surface.sendMousePos(
                x: x,
                y: y,
                mods: restoreModifiers.ghosttyMods
            )

            return target
        }

        /// Jump the viewport by a number of shell prompts.
        ///
        /// Negative offsets move toward older prompts and positive offsets move
        /// toward newer prompts. Prompt navigation requires shell integration.
        @discardableResult
        public func jumpToPrompt(by offset: Int16) -> Bool {
            surface?.jumpToPrompt(by: offset) ?? false
        }

        /// Reveal an absolute scrollback row, where zero is the first row.
        @discardableResult
        public func scrollToRow(_ row: UInt) -> Bool {
            surface?.scrollToRow(row) ?? false
        }
    }
#endif
