#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    @MainActor
    final class InputHandler {
        private weak var view: AppKitTerminalView?
        private(set) var inputMethodHandler: InputMethodHandler?

        init(view: AppKitTerminalView) {
            self.view = view
            inputMethodHandler = InputMethodHandler(view: view)
        }

        func handleKeyDown(with event: NSEvent) {
            guard let view, let surface = view.surface else { return }

            let action: ghostty_input_action_e = event.isARepeat
                ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

            inputMethodHandler?.startCollectingText()
            view.interpretKeyEvents([event])

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

            if inputMethodHandler?.hasMarkedText == true {
                return
            }

            var input = event.buildKeyInput(action: action)

            if let chars = event.filteredCharacters, !chars.isEmpty {
                chars.withCString { ptr in
                    input.text = ptr
                    surface.sendKeyEvent(input)
                }
            } else {
                surface.sendKeyEvent(input)
            }
        }

        func handleKeyUp(with event: NSEvent) {
            guard let view, let surface = view.surface else { return }
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
    }

    // MARK: - NSEvent Terminal Input Helpers

    extension NSEvent {
        func buildKeyInput(action: ghostty_input_action_e) -> ghostty_input_key_s {
            var input = ghostty_input_key_s()
            input.action = action
            input.keycode = UInt32(keyCode)
            input.composing = false
            input.text = nil

            let mods = InputModifiers(from: modifierFlags)
            input.mods = mods.ghosttyMods

            // Consumed modifiers: modifiers the key binding system should
            // treat as already handled by text generation. We pass through
            // all modifiers except control and command, which should remain
            // available for keybind matching.
            var consumedFlags = modifierFlags
            consumedFlags.remove(.control)
            consumedFlags.remove(.command)
            input.consumed_mods = InputModifiers(from: consumedFlags).ghosttyMods

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
            if scalar.isPUAFunctionKey {
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
        var isPUAFunctionKey: Bool {
            value >= 0xF700 && value <= 0xF8FF
        }

        var isASCIIControl: Bool {
            value < 0x20
        }
    }
#endif
