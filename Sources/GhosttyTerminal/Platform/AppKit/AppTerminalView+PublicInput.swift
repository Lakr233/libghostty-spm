//
//  AppTerminalView+PublicInput.swift
//  libghostty-spm
//
//  Public wrappers around `TerminalSurface` write paths so hosts can
//  inject bytes into the pty without reaching for internal API.
//

#if !canImport(UIKit) && canImport(AppKit)
    import AppKit

    extension AppTerminalView {
        /// Make this view the window's first responder, reporting whether
        /// keyboard focus was actually acquired. Fails (returns false) while
        /// the view is not in a window; ``TerminalViewState/requestFocus()``
        /// retries then on window attach.
        @discardableResult
        public func acquireProgrammaticFocus() -> Bool {
            guard let window else { return false }
            if window.firstResponder === self { return true }
            return window.makeFirstResponder(self)
        }

        /// Paste text into the terminal. This is the text path: a program
        /// that enabled bracketed paste receives it framed as a paste, so
        /// escape sequences and a `\r` in it are pasted characters, not
        /// keys. Keystrokes — Shift+Tab, Enter, Ctrl+C — go through
        /// ``sendKey(_:)``. False when the surface has not been created yet.
        @discardableResult
        public func paste(text: String) -> Bool {
            surface?.sendText(text) ?? false
        }

        /// The old name of ``paste(text:)``. It never bypassed key
        /// translation — the text path is a paste, and an escape sequence
        /// sent through it is pasted, not pressed.
        @available(*, deprecated, renamed: "paste(text:)", message: "The text path is a paste; press keys with sendKey(_:).")
        public func sendText(_ text: String) {
            paste(text: text)
        }

        /// Presses and releases a key, as if typed on a hardware keyboard —
        /// see ``TerminalSurface/sendKey(_:)``. An open IME composition is
        /// committed first, as it would be ahead of a hardware key. False
        /// with no surface yet.
        @discardableResult
        public func sendKey(_ press: TerminalKeyPress) -> Bool {
            guard let surface else { return false }
            if hasMarkedText() {
                unmarkText()
            }
            return surface.sendKey(press)
        }

        /// ``sendKey(_:)`` for a key and its modifiers: `sendKey(.enter)`,
        /// `sendKey(.tab, modifiers: .shift)`.
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
    }
#endif
