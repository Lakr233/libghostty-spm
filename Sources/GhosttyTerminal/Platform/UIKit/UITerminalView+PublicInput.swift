//
//  UITerminalView+PublicInput.swift
//  libghostty-spm
//
//  Public wrappers around TerminalSurface input and navigation actions.
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    extension UITerminalView {
        /// Make this view the first responder, reporting whether keyboard
        /// focus was actually acquired. Fails (returns false) while the view
        /// is not in a window; ``TerminalViewState/requestFocus()`` retries
        /// then on window attach.
        @discardableResult
        public func acquireProgrammaticFocus() -> Bool {
            guard window != nil else { return false }
            if isFirstResponder { return true }
            return becomeFirstResponder()
        }

        /// Paste text into the terminal. This is the text path: a program
        /// that enabled bracketed paste receives it framed as a paste, so a
        /// `\r` in it is a pasted character, not Enter. Keystrokes go
        /// through ``sendKey(_:)``. False with no surface yet.
        @discardableResult
        public func paste(text: String) -> Bool {
            surface?.sendText(text) ?? false
        }

        /// Presses and releases a key, as if typed on a hardware keyboard —
        /// see ``TerminalSurface/sendKey(_:)``. An open IME composition is
        /// committed first, and armed sticky Ctrl/Alt/Cmd apply to the key
        /// and are spent by it, exactly as for a tap on the bundled
        /// accessory bar. False with no surface yet.
        @discardableResult
        public func sendKey(_ press: TerminalKeyPress) -> Bool {
            guard let surface else { return false }
            if inputHandler.hasMarkedText {
                inputHandler.unmarkText()
            }
            var press = press
            #if !targetEnvironment(macCatalyst)
                press.modifiers.formUnion(stickyModifiers.consumeForNextKey())
            #endif
            return surface.sendKey(press)
        }

        /// ``sendKey(_:)`` for a key and its modifiers: `sendKey(.enter)`,
        /// `sendKey(.c, modifiers: .ctrl)`.
        @discardableResult
        public func sendKey(_ key: TerminalKey, modifiers: TerminalInputModifiers = []) -> Bool {
            sendKey(TerminalKeyPress(key, modifiers: modifiers))
        }

        /// Invoke a named Ghostty binding action (e.g. "copy_to_clipboard",
        /// "clear_screen"). Returns true when the action dispatched.
        @discardableResult
        public func performBindingAction(_ action: String) -> Bool {
            surface?.performBindingAction(action) ?? false
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

        /// Whether the application currently owns the mouse.
        public var isMouseCaptured: Bool {
            surface?.isMouseCaptured ?? false
        }

        /// View points. Ghostty applies content scale internally.
        public func sendMousePos(
            x: Double,
            y: Double,
            modifiers: TerminalInputModifiers = []
        ) {
            surface?.sendMousePos(x: x, y: y, modifiers: modifiers)
        }

        @discardableResult
        public func sendMouseButton(
            state: ghostty_input_mouse_state_e,
            button: ghostty_input_mouse_button_e,
            modifiers: TerminalInputModifiers = []
        ) -> Bool {
            surface?.sendMouseButton(
                state: state,
                button: button,
                modifiers: modifiers
            ) ?? false
        }

        public func sendMouseScroll(
            x: Double,
            y: Double,
            mods: TerminalScrollModifiers = TerminalScrollModifiers(precision: true)
        ) {
            surface?.sendMouseScroll(x: x, y: y, mods: mods)
        }
    }
#endif
