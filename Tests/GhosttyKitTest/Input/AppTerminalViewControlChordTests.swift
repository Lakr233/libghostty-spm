#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    import GhosttyKit
    @testable import GhosttyTerminal
    import Testing

    /// Control chords that Cocoa's key bindings turn into editing commands:
    /// `StandardKeyBinding.dict` maps Ctrl+Shift+A to
    /// `moveToBeginningOfParagraphAndModifySelection:` and Ctrl+' to
    /// `insertSingleQuoteIgnoringSubstitution:`. A terminal has no paragraph
    /// to select, so the chord must still reach the program, built the way
    /// Ghostty's own view sends it.
    ///
    /// These tests use the real `interpretKeyEvents` and the system's key
    /// bindings, with key events built from the current keyboard layout.
    @Suite("AppTerminalViewControlChord", .serialized)
    @MainActor
    struct AppTerminalViewControlChordTests {
        static let kittyOn = "\u{1B}[>5u"
        static let kittyOff = "\u{1B}[<u"
        static let modifyOtherKeysOn = "\u{1B}[>4;2m"
        static let modifyOtherKeysOff = "\u{1B}[>4;0m"

        @Test
        func `Control chords Cocoa binds to a command reach the program`() async {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }

            let control = Key.leftControl
            let controlShift = NSEvent.ModifierFlags(rawValue: Key.leftControl.rawValue | Key.leftShift.rawValue)
            let cases: [(name: String, key: Key, legacy: String)] = [
                ("Ctrl+Shift+A", .typed(code: 0, flags: controlShift), "\\e[97;6u"),
                ("Ctrl+Shift+B", .typed(code: 11, flags: controlShift), "\\e[98;6u"),
                ("Ctrl+Shift+E", .typed(code: 14, flags: controlShift), "\\e[101;6u"),
                ("Ctrl+Shift+F", .typed(code: 3, flags: controlShift), "\\e[102;6u"),
                ("Ctrl+Shift+N", .typed(code: 45, flags: controlShift), "\\e[110;6u"),
                ("Ctrl+Shift+P", .typed(code: 35, flags: controlShift), "\\e[112;6u"),
                ("Ctrl+Shift+V", .typed(code: 9, flags: controlShift), "\\e[118;6u"),
                ("Ctrl+'", .typed(code: 39, flags: control), "\\e[39;5u"),
                // Control's layer of the layout ignores Shift here, so the
                // event carries ' and Ghostty reports the Shift it saw.
                ("Ctrl+Shift+'", .typed(code: 39, flags: controlShift), "\\e[39;6u"),
                // Bound too, and already right: the encoder derives the C0
                // byte from the key when only Control is held.
                ("Ctrl+A", .typed(code: 0, flags: control), "\\x01"),
                ("Ctrl+H", .typed(code: 4, flags: control), "\\x08"),
                ("Ctrl+/", .typed(code: 44, flags: control), "\\x1f"),
            ]
            for chord in cases {
                rig.press(chord.key)
                #expect(await rig.take().visible == chord.legacy, "\(chord.name)")
            }

            // xterm's modifyOtherKeys, which encodes the chord from its text.
            rig.receive(Self.modifyOtherKeysOn)
            rig.press(.typed(code: 0, flags: controlShift))
            #expect(await rig.take().visible == "\\e[27;6;65~")
            rig.receive(Self.modifyOtherKeysOff)

            // The kitty flags here ask for alternate keys: the shifted A is
            // reported too, which takes the text.
            rig.receive(Self.kittyOn)
            rig.press(.typed(code: 0, flags: controlShift))
            #expect(await rig.take().visible == "\\e[97:65;6u")
            rig.receive(Self.kittyOff)
        }

        /// Ctrl+Q is Cocoa's quoted-keystroke binding: left to
        /// `interpretKeyEvents`, it swallowed the next key and inserted it
        /// literally, so a program saw `\x11xx` for Ctrl+Q, x, and nothing
        /// for a second Ctrl+Q.
        @Test
        func `Ctrl+Q reaches the program and leaves the next key alone`() async {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }
            let control = Key.leftControl
            let controlOption = NSEvent.ModifierFlags(rawValue: Key.leftControl.rawValue | Key.leftOption.rawValue)

            for key in [
                Key.typed(code: 12, flags: control), .typed(code: 7, flags: []),
                .typed(code: 12, flags: control), .typed(code: 12, flags: control),
                .typed(code: 33, flags: control), .typed(code: 0, flags: control),
            ] {
                rig.press(key)
            }
            // Ctrl+Q, x, Ctrl+Q, Ctrl+Q, Ctrl+[, Ctrl+A. Ghostty sends
            // Ctrl+[ as CSI u, not ESC, on purpose (fixterms).
            let sequence = await rig.take().visible
            #expect(sequence == "\\x11x\\x11\\x11\\e[91;5u\\x01", "\(sequence)")

            // Option as Alt leaves Ctrl+Q underneath, and that is the binding too.
            rig.press(.typed(code: 12, flags: controlOption))
            rig.press(.typed(code: 7, flags: []))
            let alt = await rig.take().visible
            #expect(alt == "\\e\\x11x", "\(alt)")
        }

        @Test
        func `the quoted-keystroke binding is read in Cocoa's key binding syntax`() {
            let control = NSEvent.ModifierFlags.control
            #expect(TerminalKeyEventHandler.keyBinding("^q", matches: "q", modifierFlags: control))
            #expect(!TerminalKeyEventHandler.keyBinding("^q", matches: "Q", modifierFlags: [control, .shift]))
            #expect(!TerminalKeyEventHandler.keyBinding("^q", matches: "q", modifierFlags: [control, .option]))
            #expect(!TerminalKeyEventHandler.keyBinding("^q", matches: "q", modifierFlags: []))
            #expect(TerminalKeyEventHandler.keyBinding("^Q", matches: "Q", modifierFlags: [control, .shift]))
            #expect(TerminalKeyEventHandler.keyBinding("^$q", matches: "Q", modifierFlags: [control, .shift]))
            #expect(TerminalKeyEventHandler.keyBinding("~@x", matches: "x", modifierFlags: [.option, .command]))
            #expect(!TerminalKeyEventHandler.keyBinding("", matches: "q", modifierFlags: control))
            #expect(!TerminalKeyEventHandler.keyBinding("^#1", matches: "1", modifierFlags: control))
            // The flags compare without their device bits.
            #expect(TerminalKeyEventHandler.keyBinding("^q", matches: "q", modifierFlags: Key.leftControl))
        }

        /// Every US key under every mix of Shift, Control and Option (Alt,
        /// with the default `macos-option-as-alt = left`), pressed through the
        /// window, against what Ghostty's own macOS view sends for the same
        /// event. In the legacy encoding, under modifyOtherKeys and under the
        /// kitty protocol: whatever Cocoa's bindings make of a key, the
        /// program must see what Ghostty would send it.
        @Test(.enabled("the keys are built from the US layout") { await MainActor.run { Self.currentLayoutIsUS() } })
        func `every chord reaches the program as Ghostty's own view sends it`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let view = RoutingRecorderView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
            let rig = AppKitInputRig(view: view)
            defer { rig.tearDown() }
            let surface = try #require(rig.view.surface)

            let modes: [(name: String, on: String, off: String)] = [
                ("legacy", "", ""),
                ("modifyOtherKeys", Self.modifyOtherKeysOn, Self.modifyOtherKeysOff),
                ("kitty", Self.kittyOn, Self.kittyOff),
            ]
            var mismatches: [String] = []
            var windowTook: [String] = []
            for mode in modes {
                rig.receive(mode.on)
                for key in Self.typingKeys + Self.commandKeys {
                    let code = UInt16(TerminalHardwareKeyRouter.appKitKeyCode(for: key.ghosttyKey))
                    for (flags, modifiers) in Self.modifierSets {
                        let chord = Key.typed(code: code, flags: flags)
                        view.route = []
                        rig.press(chord)
                        let route = view.route
                        let pressed = await rig.take()
                        Self.sendAsGhosttysView(chord.event(window: rig.window), to: surface)
                        let expected = await rig.take()
                        if pressed != expected, !route.contains("keyDown"),
                           Self.windowMayTake(key, modifiers)
                        {
                            windowTook.append("\(mode.name) \(key) mods=\(modifiers.rawValue) route \(route)")
                        } else if pressed != expected {
                            mismatches.append(
                                "\(mode.name) \(key) mods=\(modifiers.rawValue): view \(pressed.visible) ghostty \(expected.visible) route \(route)",
                            )
                        }
                    }
                }
                rig.receive(mode.off)
            }
            #expect(mismatches.isEmpty, "\(mismatches.count) chords differ:\n\(mismatches.joined(separator: "\n"))")
            // On the macOS 26 runner the window keeps Ctrl+Escape and
            // Ctrl+Option+Tab: the view declines them in
            // `performKeyEquivalent`, as Ghostty's does, and `keyDown` never
            // runs. On macOS 27 they arrive. That routing sits above this
            // view and is untouched here; whether a key window in a running
            // app on macOS 26 loses them too is not known.
            withKnownIssue("the macOS 26 window keeps Ctrl+Escape and Ctrl+Option+Tab", isIntermittent: true) {
                #expect(windowTook.isEmpty, "\(windowTook.joined(separator: "\n"))")
            }
        }

        static func windowMayTake(_ key: TerminalKey, _ modifiers: TerminalInputModifiers) -> Bool {
            switch key {
            case .escape: modifiers.contains(.ctrl)
            case .tab: modifiers.isSuperset(of: [.ctrl, .alt])
            default: false
            }
        }

        /// The reference: `SurfaceView_AppKit.keyDown` at the pinned Ghostty,
        /// for a key no input method is composing. It translates the
        /// modifiers (`ghostty_surface_key_translation_mods`, here for
        /// option-as-alt), lets `interpretKeyEvents` run, and sends the
        /// translation event's `ghosttyCharacters` cut by `keyEventText`,
        /// whatever the key bindings made of the key: its `doCommand(by:)`
        /// does nothing during a keyDown. The press and release around it
        /// are the same `ghostty_input_key_s` the view builds.
        static func sendAsGhosttysView(_ event: NSEvent, to surface: TerminalSurface) {
            guard let raw = surface.rawValue else { return }
            // Its `performKeyEquivalent` turns Ctrl+/ (and the keypad's /)
            // into Ctrl+_ before the key reaches `keyDown`.
            var event = event
            if event.charactersIgnoringModifiers == "/",
               event.modifierFlags.contains(.control),
               event.modifierFlags.isDisjoint(with: [.shift, .command, .option]),
               let underscore = NSEvent.keyEvent(
                   with: .keyDown, location: .zero, modifierFlags: event.modifierFlags,
                   timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                   characters: "_", charactersIgnoringModifiers: "_", isARepeat: false, keyCode: event.keyCode,
               )
            {
                event = underscore
            }
            let translated = ghostty_surface_key_translation_mods(
                raw,
                TerminalInputModifiers(from: event.modifierFlags).ghosttyMods,
            ).rawValue
            var translationFlags = event.modifierFlags
            for (flag, mod) in [
                (NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT), (.control, GHOSTTY_MODS_CTRL),
                (.option, GHOSTTY_MODS_ALT), (.command, GHOSTTY_MODS_SUPER),
            ] {
                if translated & mod.rawValue != 0 {
                    translationFlags.insert(flag)
                } else {
                    translationFlags.remove(flag)
                }
            }

            // The translation event is the event itself when translation
            // changed nothing, and otherwise one with the characters the
            // translated modifiers type. Then `NSEvent.ghosttyCharacters`: a
            // lone C0 byte becomes the characters without Control, a function
            // key's private-use scalar becomes nothing.
            var text = translationFlags == event.modifierFlags
                ? event.characters
                : event.characters(byApplyingModifiers: translationFlags)
            if let scalar = text?.unicodeScalars.first, text?.unicodeScalars.count == 1 {
                if scalar.value < 0x20 {
                    text = event.characters(byApplyingModifiers: translationFlags.subtracting(.control))
                } else if (0xF700 ... 0xF8FF).contains(scalar.value) {
                    text = nil
                }
            }
            // `String.keyEventText`: no text that starts with C0 or DEL.
            if let first = text?.unicodeScalars.first, first.value < 0x20 || first.value == 0x7F {
                text = nil
            }

            var input = event.buildKeyInput(action: GHOSTTY_ACTION_PRESS, translationModifiers: translationFlags)
            if let text, !text.isEmpty {
                text.withCString { pointer in
                    input.text = pointer
                    _ = surface.sendKeyEvent(input)
                }
            } else {
                _ = surface.sendKeyEvent(input)
            }
            var release = event.buildKeyInput(action: GHOSTTY_ACTION_RELEASE)
            release.text = nil
            _ = surface.sendKeyEvent(release)
        }

        /// The view under test, noting how AppKit routed each press, for
        /// the failure message: a chord that never reached `keyDown` is a
        /// routing question, not an encoding one.
        final class RoutingRecorderView: AppTerminalView {
            var route: [String] = []

            override func performKeyEquivalent(with event: NSEvent) -> Bool {
                let handled = super.performKeyEquivalent(with: event)
                route.append("performKeyEquivalent=\(handled)")
                return handled
            }

            override func keyDown(with event: NSEvent) {
                route.append("keyDown")
                super.keyDown(with: event)
            }

            override func doCommand(by selector: Selector) {
                route.append("doCommand(\(selector))")
                super.doCommand(by: selector)
            }
        }

        static let typingKeys: [TerminalKey] = TerminalKey.allCases.filter {
            $0.usLayoutCharacters != nil && $0.hasPlatformKeycode
        }

        /// Keys AppKit always turns into commands (`insertTab:`,
        /// `insertNewline:`, `cancelOperation:`, `moveUp:`, …): their text is
        /// a C0 byte or a private-use scalar, and none of it may reach the
        /// encoder.
        static let commandKeys: [TerminalKey] = [
            .tab, .enter, .escape, .backspace, .delete,
            .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
            .home, .end, .pageUp, .pageDown, .f1, .f5, .f12,
        ]

        static let modifierSets: [(NSEvent.ModifierFlags, TerminalInputModifiers)] = {
            let parts: [(NSEvent.ModifierFlags, TerminalInputModifiers)] = [
                (Key.leftShift, .shift), (Key.leftControl, .ctrl), (Key.leftOption, .alt),
            ]
            return (0 ..< 8).map { mask in
                parts.enumerated().reduce(into: (NSEvent.ModifierFlags(), TerminalInputModifiers())) { result, part in
                    guard mask & (1 << part.offset) != 0 else { return }
                    result.0.formUnion(part.element.0)
                    result.1.formUnion(part.element.1)
                }
            }
        }()

        /// The sweep compares against the US table, so it runs only where the
        /// current layout types what that table says.
        static func currentLayoutIsUS() -> Bool {
            typingKeys.allSatisfy { key in
                guard let characters = key.usLayoutCharacters else { return false }
                let code = UInt16(TerminalHardwareKeyRouter.appKitKeyCode(for: key.ghosttyKey))
                let plain = Key.typed(code: code, flags: [])
                let shifted = Key.typed(code: code, flags: Key.leftShift)
                return plain.characters == String(characters.unshifted)
                    && shifted.characters == String(characters.shifted ?? characters.unshifted)
            }
        }
    }

    extension Key {
        /// A key as the current layout types it under `flags`: AppKit puts
        /// these characters in a real event, and leaves Shift alone in
        /// `charactersIgnoringModifiers`.
        static func typed(code: UInt16, flags: NSEvent.ModifierFlags) -> Key {
            let seed = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code,
            )!
            return Key(
                code: code,
                characters: seed.characters(byApplyingModifiers: flags) ?? "",
                ignoringModifiers: seed.characters(byApplyingModifiers: flags.intersection(.shift)) ?? "",
                flags: flags,
            )
        }
    }
#endif
