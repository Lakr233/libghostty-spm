#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    @testable import GhosttyTerminal
    import Testing

    /// What a key press reaches the program as, through the AppKit view: the
    /// keys Claude Code reads (Shift+Enter, Ctrl+J, Option as Meta) and the
    /// Polish Pro letters the right Option types, with the legacy encoder and
    /// under the kitty keyboard protocol Claude Code turns on.
    @Suite("AppTerminalViewKeyInput", .serialized)
    @MainActor
    struct AppTerminalViewKeyInputTests {
        static let kittyOn = "\u{1B}[>5u"
        static let kittyOff = "\u{1B}[<u"

        /// Polish Pro's Option letters: (key, keycode, lowercase, uppercase).
        static let polish: [(Character, UInt16, String, String)] = [
            ("a", 0, "ą", "Ą"), ("e", 14, "ę", "Ę"), ("s", 1, "ś", "Ś"),
            ("l", 37, "ł", "Ł"), ("z", 6, "ż", "Ż"), ("x", 7, "ź", "Ź"),
            ("c", 8, "ć", "Ć"), ("n", 45, "ń", "Ń"), ("o", 31, "ó", "Ó"),
        ]

        @Test
        func `the right-hand modifier keys set their side bits`() {
            let right = TerminalInputModifiers(from: NSEvent.ModifierFlags(
                rawValue: NSEvent.ModifierFlags([.shift, .control, .option, .command]).rawValue
                    | UInt(NX_DEVICERSHIFTKEYMASK | NX_DEVICERCTLKEYMASK | NX_DEVICERALTKEYMASK | NX_DEVICERCMDKEYMASK),
            ))
            #expect(right == [.shift, .ctrl, .alt, .super_, .shiftRight, .ctrlRight, .altRight, .superRight])

            let left = TerminalInputModifiers(from: Key.leftOption)
            #expect(left == [.alt])
        }

        @Test
        func `Shift+Enter reaches the program as a key Claude Code reads as a newline`() async {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig(view: ScriptedInputView(frame: NSRect(x: 0, y: 0, width: 800, height: 500)))
            defer { rig.tearDown() }

            rig.press(.returnKey)
            #expect(await rig.take() == Data("\r".utf8))
            rig.press(Key.returnKey.with(Key.leftShift))
            // xterm's modifyOtherKeys form; Claude Code 2.1.296 inserts a
            // newline for it, as it does for the kitty form below.
            #expect(await rig.take().visible == "\\e[27;2;13~")

            rig.receive(Self.kittyOn)
            rig.press(Key.returnKey.with(Key.leftShift))
            #expect(await rig.take().visible == "\\e[13;2u")
            rig.press(.returnKey)
            #expect(await rig.take() == Data("\r".utf8))
            rig.receive(Self.kittyOff)
            rig.press(Key.returnKey.with(Key.leftShift))
            #expect(await rig.take().visible == "\\e[27;2;13~")
        }

        @Test
        func `Ctrl+J and Option+Enter are newlines too`() async {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig(view: ScriptedInputView(frame: NSRect(x: 0, y: 0, width: 800, height: 500)))
            defer { rig.tearDown() }

            let ctrlJ = Key(code: 38, characters: "\n", ignoringModifiers: "j", flags: Key.leftControl)
            rig.press(ctrlJ)
            #expect(await rig.take() == Data("\n".utf8))
            rig.press(Key.returnKey.with(Key.leftOption))
            #expect(await rig.take().visible == "\\e\\x0d")

            rig.receive(Self.kittyOn)
            rig.press(ctrlJ)
            #expect(await rig.take().visible == "\\e[106;5u")
            rig.press(Key.returnKey.with(Key.leftOption))
            #expect(await rig.take().visible == "\\e[13;3u")
        }

        @Test
        func `the left Option is Alt and the right one types Polish letters`() async {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig(view: ScriptedInputView(frame: NSRect(x: 0, y: 0, width: 800, height: 500)))
            defer { rig.tearDown() }

            for kitty in [false, true] {
                rig.receive(kitty ? Self.kittyOn : Self.kittyOff)
                for (letter, code, lower, upper) in Self.polish {
                    let key = Key.letter(letter, code: code)
                    rig.press(key.with(Key.rightOption, characters: lower))
                    #expect(await rig.take() == Data(lower.utf8), "right Option+\(letter) kitty=\(kitty)")
                    rig.press(key.with(
                        NSEvent.ModifierFlags(rawValue: Key.rightOption.rawValue | Key.leftShift.rawValue),
                        characters: upper,
                    ))
                    #expect(await rig.take() == Data(upper.utf8), "right Option+Shift+\(letter) kitty=\(kitty)")

                    // The layout's Option character is what the event
                    // carries; Alt sends the plain letter with ESC instead.
                    rig.press(key.with(Key.leftOption, characters: lower))
                    let alt = await rig.take()
                    if kitty {
                        let codepoint = letter.unicodeScalars.first!.value
                        #expect(alt.visible == "\\e[\(codepoint);3u", "left Option+\(letter)")
                    } else {
                        #expect(alt.visible == "\\e\(letter)", "left Option+\(letter)")
                    }
                }
            }
        }

        @Test
        func `without option-as-alt both Options type the layout's letters`() async {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig(
                view: ScriptedInputView(frame: NSRect(x: 0, y: 0, width: 800, height: 500)),
                optionAsAlt: "false",
            )
            defer { rig.tearDown() }

            for flags in [Key.leftOption, Key.rightOption] {
                rig.press(Key.letter("a", code: 0).with(flags, characters: "ą"))
                #expect(await rig.take() == Data("ą".utf8))
            }
        }
    }
#endif
