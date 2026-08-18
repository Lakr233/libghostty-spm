//
//  UITerminalView+Keyboard.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    extension UITerminalView {
        /// Ctrl combos the text input system would otherwise interpret
        /// itself: as a `UITextInput` first responder, the view hands
        /// hardware keys to UIKit's text machinery, which consumes most
        /// Ctrl+letter chords (its emacs-style bindings) before
        /// `pressesBegan` ever fires. Registering them as key commands with
        /// priority over system behavior is the only reliable claim — the
        /// same route Blink and SwiftTerm take.
        private static let controlKeyCommandInputs: [String] = {
            var inputs = (UInt8(ascii: "a") ... UInt8(ascii: "z")).map {
                String(UnicodeScalar($0))
            }
            inputs += (UInt8(ascii: "0") ... UInt8(ascii: "9")).map {
                String(UnicodeScalar($0))
            }
            inputs += [" ", "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`"]
            return inputs
        }()

        private static let controlKeyCommands: [UIKeyCommand] =
            controlKeyCommandInputs.map { input in
                let command = UIKeyCommand(
                    input: input,
                    modifierFlags: .control,
                    action: #selector(handleControlKeyCommand(_:))
                )
                command.wantsPriorityOverSystemBehavior = true
                return command
            }

        override open var keyCommands: [UIKeyCommand]? {
            #if targetEnvironment(macCatalyst)
                return super.keyCommands
            #else
                var commands = super.keyCommands ?? []
                commands.append(contentsOf: Self.controlKeyCommands)
                return commands
            #endif
        }

        @objc private func handleControlKeyCommand(_ command: UIKeyCommand) {
            #if !targetEnvironment(macCatalyst)
                guard let input = command.input, !input.isEmpty else { return }
                guard claimControlKeyDelivery(
                    input: input,
                    modifierFlags: command.modifierFlags
                ) else { return }
                TerminalDebugLog.log(
                    .input,
                    "uikit key command input=\(TerminalDebugLog.describe(input)) mods=0x\(String(command.modifierFlags.rawValue, radix: 16))"
                )
                _ = sendModifiedTextKey(
                    input,
                    modifiers: TerminalInputModifiers(from: command.modifierFlags)
                )
            #endif
        }

        /// Whether this path gets to deliver the combo. Whichever of
        /// `pressesBegan` / the key command runs first wins the press; the
        /// entry expires at the end of the runloop turn, before the key can
        /// physically repeat.
        func claimControlKeyDelivery(
            input: String,
            modifierFlags: UIKeyModifierFlags
        ) -> Bool {
            let relevant = modifierFlags.intersection(
                [.control, .shift, .alternate, .command]
            )
            let signature = "\(input.lowercased())|\(relevant.rawValue)"
            guard !recentControlKeyDeliveries.contains(signature) else {
                TerminalDebugLog.log(
                    .input,
                    "uikit key delivery deduped signature=\(signature)"
                )
                return false
            }
            recentControlKeyDeliveries.insert(signature)
            DispatchQueue.main.async { [weak self] in
                self?.recentControlKeyDeliveries.remove(signature)
            }
            return true
        }

        override open func pressesBegan(
            _ presses: Set<UIPress>,
            with _: UIPressesEvent?
        ) {
            for press in presses {
                guard let key = press.key else { continue }
                handleKeyPress(key, action: GHOSTTY_ACTION_PRESS)
            }
        }

        override open func pressesEnded(
            _ presses: Set<UIPress>,
            with _: UIPressesEvent?
        ) {
            for press in presses {
                guard let key = press.key else { continue }
                handleKeyPress(key, action: GHOSTTY_ACTION_RELEASE)
            }
            hardwareKeyHandled = false
        }

        override open func pressesCancelled(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            hardwareKeyHandled = false
            super.pressesCancelled(presses, with: event)
        }

        func handleKeyPress(
            _ key: UIKey,
            action: ghostty_input_action_e
        ) {
            guard let surface else {
                TerminalDebugLog.log(.input, "uikit key ignored: missing surface")
                return
            }

            let filteredModifierFlags = filteredModifierFlags(for: key)
            let isCommandModified = filteredModifierFlags.contains(.command)
            let mods = TerminalInputModifiers(from: filteredModifierFlags)
            let keyboardZoomDirection = commandZoomDirection(
                for: key,
                action: action,
                filteredModifierFlags: filteredModifierFlags
            )

            if action == GHOSTTY_ACTION_PRESS,
               shouldSuppressUIKeyInput(for: key, isCommandModified: isCommandModified)
            {
                hardwareKeyHandled = true
            }

            TerminalDebugLog.log(
                .input,
                "uikit key action=\(TerminalDebugLog.describe(action)) code=\(key.keyCode.rawValue) chars=\(TerminalDebugLog.describe(key.characters)) ignoring=\(TerminalDebugLog.describe(key.charactersIgnoringModifiers)) mods=0x\(String(filteredModifierFlags.rawValue, radix: 16)) marked=\(inputHandler.hasMarkedText)"
            )

            var keyEvent = ghostty_input_key_s()
            keyEvent.action = action
            keyEvent.mods = mods.ghosttyMods
            // Ghostty expects a platform-native keycode, which it resolves
            // to its internal Key enum via src/input/keycodes.zig. On iOS
            // that table uses macOS virtual keycodes (native_idx = 4), so
            // translate the documented HID usage value from UIKey into the
            // corresponding AppKit keycode here.
            keyEvent.keycode = TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(
                usage: UInt16(key.keyCode.rawValue)
            )
            keyEvent.composing = inputHandler.hasMarkedText

            var consumedFlags = filteredModifierFlags
            consumedFlags.remove(.control)
            consumedFlags.remove(.command)
            keyEvent.consumed_mods = TerminalInputModifiers(from: consumedFlags).ghosttyMods

            guard action == GHOSTTY_ACTION_PRESS || action == GHOSTTY_ACTION_REPEAT else {
                _ = surface.sendKeyEvent(keyEvent)
                return
            }

            let filteredIgnoringModifiers = TerminalInputText.filteredFunctionKeyText(
                key.charactersIgnoringModifiers
            )

            if let codepoint = filteredIgnoringModifiers?.unicodeScalars.first {
                keyEvent.unshifted_codepoint = codepoint.value
            }

            // The key command fallback may have sent this very combo already
            // (see `controlKeyCommands`); on systems that deliver both, the
            // first claim wins and this press stays silent.
            if action == GHOSTTY_ACTION_PRESS,
               filteredModifierFlags.contains(.control),
               let input = filteredIgnoringModifiers,
               !claimControlKeyDelivery(
                   input: input,
                   modifierFlags: filteredModifierFlags
               )
            {
                return
            }

            guard !isCommandModified else {
                _ = surface.sendKeyEvent(keyEvent)
                if let keyboardZoomDirection {
                    scheduleViewportRefreshAfterKeyboardZoom(keyboardZoomDirection)
                }
                return
            }

            var derivedText = TerminalInputText.filteredFunctionKeyText(key.characters)

            // Ctrl+letter arrives with `characters` already collapsed to the
            // raw control byte, which the core's key encoder does not accept
            // as a key. AppKit re-derives the printable text without control
            // (NSEvent.filteredCharacters); UIKey cannot re-apply modifier
            // sets, so the unmodified character stands in.
            if filteredModifierFlags.contains(.control),
               let scalars = derivedText?.unicodeScalars,
               scalars.count == 1,
               let scalar = scalars.first,
               scalar.value < 0x20
            {
                derivedText = filteredIgnoringModifiers
            }

            guard let text = derivedText, !text.isEmpty else {
                _ = surface.sendKeyEvent(keyEvent)
                return
            }

            text.withCString { ptr in
                keyEvent.text = ptr
                _ = surface.sendKeyEvent(keyEvent)
            }
        }

        func shouldSuppressUIKeyInput(
            for key: UIKey,
            isCommandModified: Bool
        ) -> Bool {
            guard !isCommandModified else { return false }
            // Ctrl combos travel the key path above — the text system's
            // rendition is a bare control byte with the modifier context
            // stripped (`sendTypedText` zeroes mods), which double-fires the
            // combo at best and loses the ctrl semantics at worst. Alt stays
            // on the text path: option+letter legitimately types the
            // composed character.
            guard key.modifierFlags.intersection([.alternate]).isEmpty else {
                return false
            }
            guard !key.characters.isEmpty else {
                return key.keyCode == .keyboardDeleteOrBackspace
            }
            return true
        }

        private func filteredModifierFlags(for key: UIKey) -> UIKeyModifierFlags {
            var flags = key.modifierFlags
            let isFunctionKey =
                TerminalInputText.filteredFunctionKeyText(key.characters) == nil ||
                TerminalInputText.filteredFunctionKeyText(key.charactersIgnoringModifiers) == nil
            if isFunctionKey {
                flags.remove(.numericPad)
            }
            return flags
        }

        private func commandZoomDirection(
            for key: UIKey,
            action: ghostty_input_action_e,
            filteredModifierFlags: UIKeyModifierFlags
        ) -> KeyboardZoomDirection? {
            guard action == GHOSTTY_ACTION_PRESS || action == GHOSTTY_ACTION_REPEAT else {
                return nil
            }
            guard filteredModifierFlags.contains(.command) else { return nil }

            let candidates = [
                key.characters,
                key.charactersIgnoringModifiers,
            ]
            if candidates.contains(where: { $0 == "+" || $0 == "=" }) {
                return .increase
            }
            if candidates.contains(where: { $0 == "-" || $0 == "_" }) {
                return .decrease
            }
            return nil
        }

        private func scheduleViewportRefreshAfterKeyboardZoom(
            _ direction: KeyboardZoomDirection
        ) {
            TerminalDebugLog.log(
                .actions,
                "keyboard zoom shortcut direction=\(direction.rawValue)"
            )
            #if !targetEnvironment(macCatalyst)
                switch direction {
                case .increase:
                    currentFontSize = min(currentFontSize + 1, Self.maxFontSize)
                case .decrease:
                    currentFontSize = max(currentFontSize - 1, Self.minFontSize)
                }
            #endif

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                core.synchronizeMetrics()
                refreshTextInputGeometry(
                    reason: "keyboard-zoom-\(direction.rawValue)"
                )
            }
        }

        private enum KeyboardZoomDirection: String {
            case increase
            case decrease
        }
    }
#endif
