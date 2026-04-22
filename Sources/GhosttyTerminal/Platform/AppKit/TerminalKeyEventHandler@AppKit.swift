//
//  TerminalKeyEventHandler@AppKit.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    @MainActor
    final class TerminalKeyEventHandler {
        private weak var view: AppTerminalView?
        var inputMethodHandler: TerminalTextInputHandler?

        init(view: AppTerminalView) {
            self.view = view
            inputMethodHandler = TerminalTextInputHandler(view: view)
        }

        func handleKeyDown(with event: NSEvent) {
            guard let view, let surface = view.surface else { return }

            if handleDirectInputIfNeeded(event) {
                return
            }

            let action: ghostty_input_action_e = event.isARepeat
                ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

            guard !event.modifierFlags.contains(.command) else {
                sendKeyEvent(for: event, action: action, to: surface, includeText: false)
                return
            }

            inputMethodHandler?.startCollectingText()
            view.interpretKeyEvents([event])

            if inputMethodHandler?.consumeHandledTextCommand() == true {
                return
            }

            if let collected = inputMethodHandler?.finishCollectingText() {
                var input = event.buildKeyInput(action: action)
                for text in collected {
                    text.withCString { ptr in
                        input.text = ptr
                        surface.sendKeyEvent(input)
                    }
                }
                return
            }

            guard inputMethodHandler?.hasMarkedText != true else { return }
            sendKeyEvent(for: event, action: action, to: surface, includeText: true)
        }

        func handleTextCommand(_ selector: Selector) {
            inputMethodHandler?.handleCommand(selector)
        }

        func handleKeyUp(with event: NSEvent) {
            guard let view, let surface = view.surface else { return }
            if shouldBypassGhosttyForDirectInput(event) {
                return
            }
            var input = event.buildKeyInput(action: GHOSTTY_ACTION_RELEASE)
            input.text = nil
            surface.sendKeyEvent(input)
        }

        func handleFlagsChanged(with event: NSEvent) {
            guard let view, let surface = view.surface else { return }

            let action: ghostty_input_action_e = isModifierPress(event)
                ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE

            var input = event.buildKeyInput(action: action)
            input.text = nil
            surface.sendKeyEvent(input)
        }

        private func isModifierPress(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags
            switch event.keyCode {
            case 56, 60: return flags.contains(.shift)
            case 58, 61: return flags.contains(.option)
            case 59, 62: return flags.contains(.control)
            case 55, 54: return flags.contains(.command)
            case 57: return flags.contains(.capsLock)
            default: return false
            }
        }

        private func sendKeyEvent(
            for event: NSEvent,
            action: ghostty_input_action_e,
            to surface: TerminalSurface,
            includeText: Bool
        ) {
            var input = event.buildKeyInput(action: action)
            guard includeText,
                  let chars = event.filteredCharacters,
                  !chars.isEmpty
            else {
                surface.sendKeyEvent(input)
                return
            }

            chars.withCString { ptr in
                input.text = ptr
                surface.sendKeyEvent(input)
            }
        }

        private func handleDirectInputIfNeeded(_ event: NSEvent) -> Bool {
            guard let view else { return false }
            // During IME composition, AppKit needs to keep ownership of editing
            // commands so marked text can shrink, cancel, and move correctly.
            guard inputMethodHandler?.hasMarkedText != true else { return false }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                return false
            }
            let delivery = TerminalHardwareKeyRouter.routeAppKit(
                keyCode: event.keyCode,
                backend: view.configuration.backend
            )
            guard case let .data(sequence) = delivery else { return false }
            guard case let .inMemory(session) = view.configuration.backend else { return false }

            session.sendInput(sequence)
            return true
        }

        private func shouldBypassGhosttyForDirectInput(_ event: NSEvent) -> Bool {
            guard let view else { return false }
            return TerminalHardwareKeyRouter.routeAppKit(
                keyCode: event.keyCode,
                backend: view.configuration.backend
            ).isDirectInput
        }
    }

    // MARK: - NSEvent Terminal Input Helpers

    extension NSEvent {
        func buildKeyInput(action: ghostty_input_action_e) -> ghostty_input_key_s {
            var input = ghostty_input_key_s()
            input.action = action
            // Ghostty expects the native platform keycode, which it maps to
            // its internal Key enum via src/input/keycodes.zig. On macOS
            // that's the AppKit virtual keycode from NSEvent.keyCode.
            input.keycode = UInt32(keyCode)
            input.composing = false
            input.text = nil

            let mods = TerminalInputModifiers(from: modifierFlags)
            input.mods = mods.ghosttyMods

            // Consumed modifiers: modifiers the key binding system should
            // treat as already handled by text generation. We pass through
            // all modifiers except control and command, which should remain
            // available for keybind matching.
            var consumedFlags = modifierFlags
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
            guard let characters else { return nil }
            guard characters.count == 1,
                  let scalar = characters.unicodeScalars.first
            else {
                return characters
            }

            // macOS encodes function keys as Private Use Area scalars —
            // these have no printable representation.
            if TerminalInputText.isPrivateUseFunctionKey(scalar) {
                return nil
            }

            // When the control modifier produces a raw control character,
            // re-derive printable text without the control modifier so
            // Ghostty can map the physical key correctly.
            if scalar.isASCIIControl {
                var flags = modifierFlags
                flags.remove(.control)
                return self.characters(byApplyingModifiers: flags)
            }

            return characters
        }
    }

    extension UnicodeScalar {
        var isASCIIControl: Bool {
            value < 0x20
        }
    }
#endif
