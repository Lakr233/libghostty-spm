//
//  TerminalKeyEventHandler@AppKit.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//  Reference:
//  - ghostty-org/ghostty
//  - macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift
//  Translation modifiers, interpretKeyEvents dispatch, and text emission are
//  kept close to Ghostty's native AppKit implementation to reduce long-term
//  drift from upstream keyboard/IME semantics.
//

#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    import GhosttyKit

    @MainActor
    final class TerminalKeyEventHandler {
        private weak var view: AppTerminalView?
        var inputMethodHandler: TerminalTextInputHandler?
        private var interpretedCommandSelector: Selector?

        init(view: AppTerminalView) {
            self.view = view
            inputMethodHandler = TerminalTextInputHandler(view: view)
        }

        /// Whether a key that `interpretKeyEvents` answered with a command
        /// (`doCommand(by:)`) still carries the event's text to Ghostty.
        ///
        /// It does, as in Ghostty's own view, which sends the text whatever
        /// the key bindings made of the key. A terminal has no text to edit,
        /// so the command means nothing here, and the encoder needs the text
        /// for any chord it cannot rebuild from the key alone: Cocoa binds
        /// Ctrl+Shift+A to `moveToBeginningOfParagraphAndModifySelection:`
        /// and Ctrl+' to `insertSingleQuoteIgnoringSubstitution:`, and
        /// without the text both reached the program as nothing; under
        /// modifyOtherKeys Ctrl+A went out as 0x01, not `CSI 27;5;97~`.
        /// `keyEventText` still drops text that starts with a C0 or DEL
        /// byte, so Tab, Return, Escape and Backspace arrive as the key
        /// alone, and a function key's private-use scalar never gets this
        /// far.
        ///
        /// With Command held the chord stays without text: the host's to
        /// claim, not the program's.
        nonisolated static func interpretedCommandKeepsText(modifierFlags: NSEvent.ModifierFlags) -> Bool {
            !modifierFlags.contains(.command)
        }

        private static func isQuotedKeystroke(_ event: NSEvent) -> Bool {
            let binding = UserDefaults.standard.string(forKey: "NSQuotedKeystrokeBinding") ?? "^q"
            return keyBinding(
                binding,
                matches: event.charactersIgnoringModifiers,
                modifierFlags: event.modifierFlags,
            )
        }

        /// Whether a key in Cocoa's key binding syntax (`^` Control, `~`
        /// Option, `$` Shift, `@` Command, then the character; an uppercase
        /// letter implies Shift) names this key. `characters` is the event's
        /// `charactersIgnoringModifiers`, which keeps Shift. An empty
        /// binding, or one this does not read (a keypad `#`, an escaped
        /// character), matches nothing.
        nonisolated static func keyBinding(
            _ binding: String,
            matches characters: String?,
            modifierFlags: NSEvent.ModifierFlags,
        ) -> Bool {
            let prefixes: [Character: NSEvent.ModifierFlags] = [
                "^": .control, "~": .option, "$": .shift, "@": .command,
            ]
            var required: NSEvent.ModifierFlags = []
            var rest = Substring(binding)
            while rest.count > 1, let first = rest.first, let flag = prefixes[first] {
                required.insert(flag)
                rest.removeFirst()
            }
            guard rest.count == 1, let key = rest.first,
                  let characters, characters.count == 1, let typed = characters.first
            else { return false }
            if key.isUppercase {
                required.insert(.shift)
            }
            let held = modifierFlags.intersection([.control, .option, .shift, .command])
            return held == required && typed.lowercased() == key.lowercased()
        }

        func handleKeyDown(with event: NSEvent) {
            guard let view, let surface = view.surface else { return }

            let action: ghostty_input_action_e = event.isARepeat
                ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
            let translationEvent = translatedEvent(for: event, on: surface)
            let markedTextBefore = inputMethodHandler?.hasMarkedText == true
            interpretedCommandSelector = nil

            // Cocoa's quoted-keystroke binding (`NSQuotedKeystrokeBinding`,
            // Ctrl+Q unless the user moved it) makes `interpretKeyEvents`
            // swallow the next key and insert it literally: a Ctrl+[ after a
            // tmux prefix of Ctrl+Q went nowhere (Ghostty discussion 5067),
            // and in this package's tests Ctrl+Q then x reached the program
            // as `\x11xx`. Programs read Ctrl+Q themselves (XON, a tmux
            // prefix, vim's visual block), so the key binding system never
            // sees it. A composition keeps the key: it is the input method's
            // then.
            if !markedTextBefore, Self.isQuotedKeystroke(translationEvent) {
                sendKeyEvent(
                    for: event,
                    translationEvent: translationEvent,
                    action: action,
                    to: surface,
                    includeText: true,
                )
                return
            }

            inputMethodHandler?.startCollectingText()
            let keyboardIdBefore = markedTextBefore ? nil : KeyboardLayout.id
            view.keyEcho.lastPerformKeyEvent = nil
            view.interpretKeyEvents([translationEvent])
            if !markedTextBefore, keyboardIdBefore != KeyboardLayout.id {
                _ = inputMethodHandler?.finishCollectingText()
                return
            }
            inputMethodHandler?.syncPreedit(clearIfNeeded: markedTextBefore)

            if let collected = inputMethodHandler?.finishCollectingText() {
                var input = event.buildKeyInput(
                    action: action,
                    translationModifiers: translationEvent.modifierFlags,
                )
                for text in collected {
                    text.withCString { ptr in
                        input.text = ptr
                        surface.sendKeyEvent(input)
                    }
                }
                return
            }

            let includeText = interpretedCommandSelector == nil
                || Self.interpretedCommandKeepsText(modifierFlags: event.modifierFlags)
            interpretedCommandSelector = nil
            sendKeyEvent(
                for: event,
                translationEvent: translationEvent,
                action: action,
                to: surface,
                includeText: includeText,
                composing: inputMethodHandler?.hasMarkedText == true || markedTextBefore,
            )
        }

        func handleKeyUp(with event: NSEvent) {
            guard let view, let surface = view.surface else { return }
            var input = event.buildKeyInput(action: GHOSTTY_ACTION_RELEASE)
            input.text = nil
            surface.sendKeyEvent(input)
        }

        func handleFlagsChanged(with event: NSEvent) {
            guard let surface = view?.surface else { return }
            guard inputMethodHandler?.hasMarkedText != true else { return }

            let mod: UInt32
            switch event.keyCode {
            case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
            case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
            case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
            case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
            case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
            default: return
            }

            let mods = TerminalInputModifiers(from: event.modifierFlags).ghosttyMods

            var action = GHOSTTY_ACTION_RELEASE
            if mods.rawValue & mod != 0 {
                let sidePressed: Bool = switch event.keyCode {
                case 0x3C:
                    event.modifierFlags.rawValue
                        & UInt(NX_DEVICERSHIFTKEYMASK) != 0
                case 0x3E:
                    event.modifierFlags.rawValue
                        & UInt(NX_DEVICERCTLKEYMASK) != 0
                case 0x3D:
                    event.modifierFlags.rawValue
                        & UInt(NX_DEVICERALTKEYMASK) != 0
                case 0x36:
                    event.modifierFlags.rawValue
                        & UInt(NX_DEVICERCMDKEYMASK) != 0
                default:
                    true
                }

                if sidePressed {
                    action = GHOSTTY_ACTION_PRESS
                }
            }

            var input = event.buildKeyInput(action: action)
            input.text = nil
            surface.sendKeyEvent(input)
        }

        private func sendKeyEvent(
            for event: NSEvent,
            translationEvent: NSEvent,
            action: ghostty_input_action_e,
            to surface: TerminalSurface,
            includeText: Bool,
            composing: Bool = false,
        ) {
            var input = event.buildKeyInput(
                action: action,
                translationModifiers: translationEvent.modifierFlags,
            )
            input.composing = composing
            guard includeText,
                  let chars = TerminalInputText.keyEventText(translationEvent.filteredCharacters)
            else {
                surface.sendKeyEvent(input)
                return
            }

            chars.withCString { ptr in
                input.text = ptr
                surface.sendKeyEvent(input)
            }
        }

        private func translatedEvent(
            for event: NSEvent,
            on surface: TerminalSurface,
        ) -> NSEvent {
            guard let rawSurface = surface.rawValue else {
                return event
            }

            let translatedMods = eventModifierFlags(
                from: ghostty_surface_key_translation_mods(
                    rawSurface,
                    TerminalInputModifiers(from: event.modifierFlags).ghosttyMods,
                ),
            )

            var finalModifiers = event.modifierFlags
            for flag in [
                NSEvent.ModifierFlags.shift,
                .control,
                .option,
                .command,
            ] {
                if translatedMods.contains(flag) {
                    finalModifiers.insert(flag)
                } else {
                    finalModifiers.remove(flag)
                }
            }

            guard finalModifiers != event.modifierFlags else {
                return event
            }

            return NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: finalModifiers,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: finalModifiers) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode,
            ) ?? event
        }

        private func eventModifierFlags(from mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
            var flags = NSEvent.ModifierFlags()
            if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 {
                flags.insert(.shift)
            }
            if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 {
                flags.insert(.control)
            }
            if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 {
                flags.insert(.option)
            }
            if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 {
                flags.insert(.command)
            }
            return flags
        }

        func recordInterpretedCommand(_ selector: Selector) {
            interpretedCommandSelector = selector
        }
    }

    // MARK: - NSEvent Terminal Input Helpers

    extension NSEvent {
        func buildKeyInput(
            action: ghostty_input_action_e,
            translationModifiers: NSEvent.ModifierFlags? = nil,
        ) -> ghostty_input_key_s {
            var input = ghostty_input_key_s()
            input.action = action
            input.keycode = UInt32(keyCode)
            input.composing = false
            input.text = nil

            input.mods = TerminalInputModifiers(from: modifierFlags).ghosttyMods

            // Consumed modifiers: modifiers the key binding system should
            // treat as already handled by text generation. We pass through
            // all modifiers except control and command, which should remain
            // available for keybind matching.
            var consumedFlags = translationModifiers ?? modifierFlags
            consumedFlags.remove(.control)
            consumedFlags.remove(.command)
            input.consumed_mods = TerminalInputModifiers(from: consumedFlags).ghosttyMods

            if type == .keyDown || type == .keyUp,
               let chars = characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first
            {
                input.unshifted_codepoint = codepoint.value
            }

            return input
        }

        var filteredCharacters: String? {
            guard let filtered = TerminalInputText.filteredFunctionKeyText(characters) else {
                return nil
            }
            guard filtered.count == 1,
                  let scalar = filtered.unicodeScalars.first
            else {
                return filtered
            }

            // macOS encodes function keys as Private Use Area scalars —
            // these have no printable representation.
            // When the control modifier produces a raw control character,
            // re-derive printable text without the control modifier so
            // Ghostty can map the physical key correctly.
            if scalar.isASCIIControl {
                var flags = modifierFlags
                flags.remove(.control)
                return TerminalInputText.filteredFunctionKeyText(
                    characters(byApplyingModifiers: flags),
                )
            }

            return filtered
        }
    }

    extension UnicodeScalar {
        var isASCIIControl: Bool {
            value < 0x20
        }
    }
#endif
