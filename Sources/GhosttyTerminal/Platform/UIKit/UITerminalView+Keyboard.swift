//
//  UITerminalView+Keyboard.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    /// Hardware-keyboard routing state; behavior lives in +Keyboard.
    struct HardwareKeyboardState {
        /// A press the key path already delivered, telling the UITextInput
        /// echo to stay silent.
        var keyHandled = false
        /// Signatures of keys already delivered this runloop turn by one of
        /// the two paths that can carry a key we register as a `UIKeyCommand`
        /// (the Ctrl combos, Escape). One physical press can reach us twice —
        /// `pressesBegan` and the matching command — and which arrives (or
        /// both) varies by iPadOS version; whichever runs first claims the
        /// press here.
        var recentKeyCommandDeliveries: Set<String> = []
        /// Keys loaned to the input method this runloop turn. The text input
        /// system claims them through any UITextInput mutation; whatever is
        /// still here when the turn ends is replayed to the surface.
        var pendingInputMethodKeys: [DeferredInputMethodKey] = []
        var inputMethodFlushScheduled = false
        /// Learned once per process — not per view, or every new tab would
        /// re-calibrate: the text input system ignored a loaned key
        /// outright, so deferred presses must be forwarded to `super` — the
        /// route that feeds them to the input method on the iPadOS versions
        /// that do not process hardware keys on their own.
        @MainActor static var inputMethodNeedsPressForwarding = false
        /// Set on the first claim: the input method demonstrably hears our
        /// keys. From then on an unclaimed forwarded key is never replayed
        /// raw — the input method's responses arrive asynchronously (they
        /// round-trip the keyboard daemon), and replaying a key it is still
        /// composing types it twice.
        @MainActor static var inputMethodProvenResponsive = false
        /// Presses currently loaned to the input method; their release must
        /// not reach the surface (a replay sends its own synthetic pair).
        var pressesLoanedToInputMethod: Set<UIPress> = []
        /// Presses whose began was forwarded to `super`; their ended must
        /// complete there too.
        var pressesForwardedToInputMethod: Set<UIPress> = []
    }

    /// Software-keyboard visibility and tap-to-toggle state; behavior in
    /// +Keyboard (observers) and +Interaction (touch handling).
    struct SoftwareKeyboardState {
        var isVisible = false
        /// The active direct-touch sequence can still resolve to a clean
        /// tap. Armed on the first finger down; disarmed by a second
        /// finger, by movement past the slop, by any recognized gesture
        /// (scroll pan, pinch, long press), or by the press running long.
        /// Only a sequence still armed at touch end toggles the keyboard —
        /// a drag, zoom, or hold must never count as the tap.
        var tapCandidateArmed = false
        var tapCandidateStart: CGPoint = .zero
        var tapCandidateTimestamp: TimeInterval = 0
    }

    /// A hardware key loaned to the input method, kept ready to replay:
    /// everything the direct path would have put on the key event.
    struct DeferredInputMethodKey {
        let action: ghostty_input_action_e
        let keycode: UInt32
        let mods: ghostty_input_mods_e
        let consumedMods: ghostty_input_mods_e
        let unshiftedCodepoint: UInt32
        let text: String?
        /// The physical press, held for the turn so a calibration flush can
        /// still hand it to `super` instead of leaking raw text.
        weak var press: UIPress?
        /// The press has been given to `super` (at press time or by a
        /// calibration flush); the next unclaimed flush replays it raw
        /// rather than retrying forever.
        var forwardAttempted: Bool
    }

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

        /// Escape, which the text input system also handles itself: for a
        /// `UITextInput` first responder UIKit's system behaviour for a
        /// hardware Escape is to end editing — the view resigns, the keyboard
        /// (and the accessory bar over it) drops — and that runs before
        /// `pressesBegan` ever sees the key. A terminal cannot give Escape
        /// away, so it is claimed the same way as the Ctrl combos, under
        /// every modifier set a program might bind (Cmd-Escape stays with
        /// the system).
        ///
        /// Catalyst needs this just the same. It has no software keyboard to
        /// drop, but the end-editing behaviour is the text input system's,
        /// not the keyboard's: an unclaimed Escape resigns the view there
        /// too, the press never reaches `pressesBegan`, and every key after
        /// it goes nowhere until the next click.
        private static let escapeKeyCommands: [UIKeyCommand] = {
            let modifierSets: [UIKeyModifierFlags] = [
                [], .shift, .control, .alternate,
                [.shift, .control], [.shift, .alternate], [.control, .alternate],
                [.shift, .control, .alternate],
            ]
            return modifierSets.map { flags in
                let command = UIKeyCommand(
                    input: UIKeyCommand.inputEscape,
                    modifierFlags: flags,
                    action: #selector(handleEscapeKeyCommand(_:))
                )
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }()

        // Catalyst included: its text-input system also swallows Ctrl+letter
        // before `pressesBegan` (the Control press itself arrives, the letter
        // never does), and the key command is the only route left. The
        // per-runloop claim below dedupes against a press on systems that
        // deliver both.
        //
        // UIKit asks for this list on every key event, so it can change with
        // the view's state: while a composition is on screen every key is the
        // input method's (Escape cancels it — see `TerminalIMEComposition`),
        // and the Escape commands step aside so the press takes the deferral
        // path in `pressesBegan` as it always did.
        override open var keyCommands: [UIKeyCommand]? {
            var commands = super.keyCommands ?? []
            commands.append(contentsOf: Self.controlKeyCommands)
            if !inputHandler.hasMarkedText {
                commands.append(contentsOf: Self.escapeKeyCommands)
            }
            return commands
        }

        @objc private func handleControlKeyCommand(_ command: UIKeyCommand) {
            guard let input = command.input, input.count == 1,
                  let character = input.first,
                  let press = TerminalKeyPress(
                      typing: character,
                      modifiers: TerminalInputModifiers(from: command.modifierFlags)
                  )
            else { return }
            guard claimKeyCommandDelivery(
                input: input,
                modifierFlags: command.modifierFlags
            ) else { return }
            TerminalDebugLog.log(
                .input,
                "uikit key command input=\(TerminalDebugLog.describe(input)) mods=0x\(String(command.modifierFlags.rawValue, radix: 16))"
            )
            // A chord, not typing: it closes an open composition the way a
            // hardware press would, and takes the shared key path.
            if inputHandler.hasMarkedText {
                inputHandler.unmarkText()
            }
            _ = surface?.sendKey(press)
        }

        /// The Escape command's action: the key goes to the surface as a
        /// press, exactly as `pressesBegan` would have sent it, and the view
        /// stays first responder. The command is not offered while text is
        /// marked (see `keyCommands`), so no composition is open here.
        @objc private func handleEscapeKeyCommand(_ command: UIKeyCommand) {
            guard claimKeyCommandDelivery(
                input: UIKeyCommand.inputEscape,
                modifierFlags: command.modifierFlags
            ) else { return }
            TerminalDebugLog.log(
                .input,
                "uikit key command input=escape mods=0x\(String(command.modifierFlags.rawValue, radix: 16))"
            )
            _ = surface?.sendKey(TerminalKeyPress(
                .escape,
                modifiers: TerminalInputModifiers(from: command.modifierFlags)
            ))
        }

        /// Whether this path gets to deliver a key that is also registered
        /// as a `UIKeyCommand` (a Ctrl combo, Escape). Whichever of
        /// `pressesBegan` / the key command runs first wins the press; the
        /// entry expires at the end of the runloop turn, before the key can
        /// physically repeat.
        func claimKeyCommandDelivery(
            input: String,
            modifierFlags: UIKeyModifierFlags
        ) -> Bool {
            let relevant = modifierFlags.intersection(
                [.control, .shift, .alternate, .command]
            )
            let signature = "\(input.lowercased())|\(relevant.rawValue)"
            guard !hardwareKeyboard.recentKeyCommandDeliveries.contains(signature) else {
                TerminalDebugLog.log(
                    .input,
                    "uikit key delivery deduped signature=\(signature)"
                )
                return false
            }
            hardwareKeyboard.recentKeyCommandDeliveries.insert(signature)
            DispatchQueue.main.async { [weak self] in
                self?.hardwareKeyboard.recentKeyCommandDeliveries.remove(signature)
            }
            return true
        }

        override open func pressesBegan(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            #if targetEnvironment(macCatalyst)
                for press in presses {
                    guard let key = press.key else { continue }
                    handleKeyPress(key, action: GHOSTTY_ACTION_PRESS)
                }
            #else
                var forwardedToInputMethod: Set<UIPress> = []
                for press in presses {
                    guard let key = press.key else { continue }
                    if shouldDeferKeyToInputMethod(key) {
                        TerminalDebugLog.log(
                            .input,
                            "uikit key deferred to input method code=\(key.keyCode.rawValue) marked=\(inputHandler.hasMarkedText) lang=\(textInputMode?.primaryLanguage ?? "nil") forwarding=\(HardwareKeyboardState.inputMethodNeedsPressForwarding)"
                        )
                        deferKeyToInputMethod(key, press: press, action: GHOSTTY_ACTION_PRESS)
                        hardwareKeyboard.pressesLoanedToInputMethod.insert(press)
                        if HardwareKeyboardState.inputMethodNeedsPressForwarding {
                            hardwareKeyboard.pressesForwardedToInputMethod.insert(press)
                            forwardedToInputMethod.insert(press)
                        }
                        continue
                    }
                    handleKeyPress(key, action: GHOSTTY_ACTION_PRESS)
                }
                // `super` is how UIKit feeds an unhandled press to the text
                // input system on the iPadOS versions that do not process
                // hardware keys before presses dispatch.
                if !forwardedToInputMethod.isEmpty {
                    super.pressesBegan(forwardedToInputMethod, with: event)
                }
            #endif
        }

        override open func pressesEnded(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            #if targetEnvironment(macCatalyst)
                for press in presses {
                    guard let key = press.key else { continue }
                    handleKeyPress(key, action: GHOSTTY_ACTION_RELEASE)
                }
                hardwareKeyboard.keyHandled = false
            #else
                var forwardedToInputMethod: Set<UIPress> = []
                for press in presses {
                    if hardwareKeyboard.pressesLoanedToInputMethod.remove(press) != nil {
                        // The surface never saw this press (a replayed key
                        // carries its own synthetic release), so it gets no
                        // release either — but a began that went to `super`
                        // must complete there.
                        if hardwareKeyboard.pressesForwardedToInputMethod.remove(press) != nil {
                            forwardedToInputMethod.insert(press)
                        }
                        continue
                    }
                    guard let key = press.key else { continue }
                    handleKeyPress(key, action: GHOSTTY_ACTION_RELEASE)
                }
                hardwareKeyboard.keyHandled = false
                if !forwardedToInputMethod.isEmpty {
                    super.pressesEnded(forwardedToInputMethod, with: event)
                }
            #endif
        }

        override open func pressesCancelled(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            hardwareKeyboard.keyHandled = false
            #if !targetEnvironment(macCatalyst)
                for press in presses {
                    hardwareKeyboard.pressesLoanedToInputMethod.remove(press)
                    hardwareKeyboard.pressesForwardedToInputMethod.remove(press)
                }
            #endif
            super.pressesCancelled(presses, with: event)
        }

        #if !targetEnvironment(macCatalyst)
            /// Whether this press belongs to the input method rather than the
            /// terminal — see `TerminalIMEComposition` for the rules.
            private func shouldDeferKeyToInputMethod(_ key: UIKey) -> Bool {
                let flags = filteredModifierFlags(for: key)
                guard flags.isDisjoint(with: [.control, .command]) else { return false }
                return TerminalIMEComposition.shouldDeferKey(
                    characters: key.characters,
                    hasMarkedText: inputHandler.hasMarkedText,
                    inputModeUsesComposition: TerminalIMEComposition
                        .languageUsesComposition(textInputMode?.primaryLanguage)
                )
            }
        #endif

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
                hardwareKeyboard.keyHandled = true
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

            // The key command fallback may have sent this very key already
            // (see `controlKeyCommands` and `escapeKeyCommands`); on systems
            // that deliver both, the first claim wins and this press stays
            // silent.
            if action == GHOSTTY_ACTION_PRESS,
               let input = keyCommandInput(for: key, filteredModifierFlags: filteredModifierFlags),
               !claimKeyCommandDelivery(
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

        /// The `UIKeyCommand.input` this press would arrive under, if it is
        /// one of the keys `keyCommands` registers — the shared signature
        /// both paths claim with. Nil for every other key.
        private func keyCommandInput(
            for key: UIKey,
            filteredModifierFlags: UIKeyModifierFlags
        ) -> String? {
            if key.keyCode == .keyboardEscape,
               !filteredModifierFlags.contains(.command)
            {
                return UIKeyCommand.inputEscape
            }
            guard filteredModifierFlags.contains(.control) else { return nil }
            return TerminalInputText.filteredFunctionKeyText(key.charactersIgnoringModifiers)
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
                    fontZoom.currentFontSize = min(fontZoom.currentFontSize + 1, Self.maxFontSize)
                case .decrease:
                    fontZoom.currentFontSize = max(fontZoom.currentFontSize - 1, Self.minFontSize)
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

    #if !targetEnvironment(macCatalyst)
        extension UITerminalView {
            func deferKeyToInputMethod(
                _ key: UIKey,
                press: UIPress?,
                action: ghostty_input_action_e
            ) {
                let mods = TerminalInputModifiers(from: filteredModifierFlags(for: key))
                var consumedFlags = key.modifierFlags
                consumedFlags.remove(.control)
                consumedFlags.remove(.command)

                let unshifted = TerminalInputText.filteredFunctionKeyText(
                    key.charactersIgnoringModifiers
                )?.unicodeScalars.first?.value ?? 0

                hardwareKeyboard.pendingInputMethodKeys.append(DeferredInputMethodKey(
                    action: action,
                    keycode: TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(
                        usage: UInt16(key.keyCode.rawValue)
                    ),
                    mods: mods.ghosttyMods,
                    consumedMods: TerminalInputModifiers(from: consumedFlags).ghosttyMods,
                    unshiftedCodepoint: unshifted,
                    text: TerminalInputText.filteredFunctionKeyText(key.characters),
                    press: press,
                    // Forwarded at press time whenever calibration already
                    // happened; only then may an unclaimed flush replay raw.
                    forwardAttempted: HardwareKeyboardState.inputMethodNeedsPressForwarding
                ))
                scheduleInputMethodKeyFlush()
            }

            /// The text input system spoke — every loaned key was heard.
            /// Called from each UITextInput mutation entry point.
            func claimPendingInputMethodKeys() {
                guard !hardwareKeyboard.pendingInputMethodKeys.isEmpty else { return }
                HardwareKeyboardState.inputMethodProvenResponsive = true
                TerminalDebugLog.log(
                    .input,
                    "input method claimed \(hardwareKeyboard.pendingInputMethodKeys.count) deferred key(s)"
                )
                hardwareKeyboard.pendingInputMethodKeys.removeAll()
            }

            private func scheduleInputMethodKeyFlush(after delay: TimeInterval = 0) {
                guard !hardwareKeyboard.inputMethodFlushScheduled else { return }
                hardwareKeyboard.inputMethodFlushScheduled = true
                let flush: @MainActor @Sendable () -> Void = { [weak self] in
                    guard let self else { return }
                    hardwareKeyboard.inputMethodFlushScheduled = false
                    replayUnclaimedInputMethodKeys()
                }
                if delay > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: flush)
                } else {
                    DispatchQueue.main.async(execute: flush)
                }
            }

            private func replayUnclaimedInputMethodKeys() {
                guard !hardwareKeyboard.pendingInputMethodKeys.isEmpty else { return }
                let keys = hardwareKeyboard.pendingInputMethodKeys
                hardwareKeyboard.pendingInputMethodKeys.removeAll()

                // The system never handed these presses to the input method
                // on its own — calibrate to forwarding, and give these very
                // presses to `super` right now: the input method can still
                // compose them, so nothing leaks into the shell. Only keys
                // whose forward has already been tried fall through to the
                // raw replay below.
                let retriable = keys.filter { !$0.forwardAttempted }
                if !retriable.isEmpty {
                    if !HardwareKeyboardState.inputMethodNeedsPressForwarding {
                        HardwareKeyboardState.inputMethodNeedsPressForwarding = true
                        TerminalDebugLog.log(
                            .input,
                            "text input system ignored the loan; forwarding deferred presses to super from now on"
                        )
                    }
                    hardwareKeyboard.pendingInputMethodKeys = keys.map { key in
                        var retried = key
                        retried.forwardAttempted = true
                        return retried
                    }
                    for key in retriable {
                        guard let press = key.press else { continue }
                        if hardwareKeyboard.pressesLoanedToInputMethod.contains(press) {
                            // Still held down: its ended will complete at
                            // `super` through the forwarded set.
                            hardwareKeyboard.pressesForwardedToInputMethod.insert(press)
                            super.pressesBegan([press], with: nil)
                        } else {
                            // Already released — hand `super` the whole
                            // pair so the input method sees a full press.
                            super.pressesBegan([press], with: nil)
                            super.pressesEnded([press], with: nil)
                        }
                    }
                    // The claim decides their fate — and it round-trips the
                    // keyboard daemon, so give it real time instead of one
                    // runloop turn. Costs a one-time delay on the process's
                    // first key when no input method is listening at all.
                    scheduleInputMethodKeyFlush(after: 0.25)
                    return
                }

                // A responsive input method never gets keys replayed behind
                // its back: its claims arrive asynchronously (a key we
                // replay now may be mid-composition and would type twice),
                // and a key it consumes without any mutation — candidate
                // paging — is its to consume. The same goes for a visibly
                // live composition even before the first claim.
                guard !HardwareKeyboardState.inputMethodProvenResponsive,
                      !inputHandler.hasMarkedText
                else {
                    TerminalDebugLog.log(
                        .input,
                        "dropping \(keys.count) unclaimed key(s): input method owns them (proven=\(HardwareKeyboardState.inputMethodProvenResponsive) marked=\(inputHandler.hasMarkedText))"
                    )
                    return
                }

                guard let surface else { return }
                TerminalDebugLog.log(
                    .input,
                    "input method left \(keys.count) key(s) unclaimed, replaying"
                )
                for key in keys {
                    var keyEvent = ghostty_input_key_s()
                    keyEvent.action = key.action
                    keyEvent.mods = key.mods
                    keyEvent.keycode = key.keycode
                    keyEvent.consumed_mods = key.consumedMods
                    keyEvent.unshifted_codepoint = key.unshiftedCodepoint
                    keyEvent.composing = false
                    if let text = key.text, !text.isEmpty {
                        text.withCString { ptr in
                            keyEvent.text = ptr
                            _ = surface.sendKeyEvent(keyEvent)
                        }
                    } else {
                        _ = surface.sendKeyEvent(keyEvent)
                    }
                    // The matching release: pressesEnded skips loaned
                    // presses, so the pair completes here.
                    var release = keyEvent
                    release.action = GHOSTTY_ACTION_RELEASE
                    release.text = nil
                    _ = surface.sendKeyEvent(release)
                }
            }
        }
    #endif
#endif
