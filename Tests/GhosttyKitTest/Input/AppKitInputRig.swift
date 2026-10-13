#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    import Foundation
    @testable import GhosttyTerminal
    import Testing

    /// An `AppTerminalView` in a window that is never ordered in, fed by an
    /// in-memory session whose outbound bytes the test reads: key events go
    /// in through the window as AppKit would route them, and what the shell
    /// would have received comes out.
    ///
    /// Take a ``GhosttySurfaceHarness`` turn first: one ghostty app at a time.
    @MainActor
    final class AppKitInputRig {
        let outbound = LockedBytes()
        let session: InMemoryTerminalSession
        let view: AppTerminalView
        let window: NSWindow

        init(
            view: AppTerminalView = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500)),
            optionAsAlt: String? = "left",
        ) {
            let outbound = outbound
            session = InMemoryTerminalSession(write: { outbound.append($0) }, resize: { _ in })
            self.view = view
            view.controller = TerminalController {
                if let optionAsAlt { $0.withCustom("macos-option-as-alt", optionAsAlt) }
            }
            view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
            window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            window.makeFirstResponder(view)
        }

        func tearDown() {
            window.contentView = nil
        }

        /// Program output, parsed before this returns.
        func receive(_ text: String) {
            session.receive(Data(text.utf8))
            session.waitForPendingOutput()
        }

        /// One key press as AppKit routes it: key equivalents first, then
        /// `keyDown` on the first responder. `NSApp.currentEvent` is the
        /// event meanwhile, as in a real press: `insertText` drops text that
        /// arrives outside one, the guard Ghostty's own macOS view has.
        /// Posting the event and taking it back with `nextEvent` would set
        /// it too, but stops the test process's async main run loop.
        func press(_ key: Key) {
            let event = key.event(window: window)
            NSApp.setValue(event, forKey: "currentEvent")
            defer { NSApp.setValue(nil, forKey: "currentEvent") }
            if !window.performKeyEquivalent(with: event) {
                window.sendEvent(event)
            }
        }

        /// Everything sent since the last take: a device-attributes query
        /// goes in after it, and the bytes before its reply are the answer.
        func take() async -> Data {
            session.receive(Data("\u{1B}[c".utf8))
            session.waitForPendingOutput()
            let marker = Data("\u{1B}[?62;22".utf8)
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline {
                let bytes = outbound.bytes
                if let reply = bytes.range(of: marker) {
                    outbound.removeAll()
                    return Data(bytes[..<reply.lowerBound])
                }
                await Task.yield()
            }
            Issue.record("device attributes reply never arrived")
            return outbound.bytes
        }
    }

    /// A hardware key: its virtual keycode, what it types, and its modifiers
    /// with the device bits that say which side is held.
    struct Key {
        var code: UInt16
        var characters: String
        var ignoringModifiers: String
        var flags: NSEvent.ModifierFlags = []

        static let leftShift = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICELSHIFTKEYMASK))
        static let leftOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | UInt(NX_DEVICELALTKEYMASK))
        static let rightOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | UInt(NX_DEVICERALTKEYMASK))
        static let leftControl = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.control.rawValue | UInt(NX_DEVICELCTLKEYMASK))
        static let leftCommand = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | UInt(NX_DEVICELCMDKEYMASK))

        static let returnKey = Key(code: 36, characters: "\r", ignoringModifiers: "\r")

        func with(_ flags: NSEvent.ModifierFlags, characters: String? = nil) -> Key {
            var key = self
            key.flags = flags
            if let characters { key.characters = characters }
            return key
        }

        static func letter(_ letter: Character, code: UInt16) -> Key {
            Key(code: code, characters: String(letter), ignoringModifiers: String(letter))
        }

        func event(window: NSWindow) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: ignoringModifiers, isARepeat: false, keyCode: code,
            )!
        }
    }

    /// An input method the test scripts, in place of the user's input source:
    /// the rig never depends on, or changes, what the Mac is set to type.
    /// Without a script a key does what AppKit's key bindings do on a plain
    /// layout: printable characters are inserted, anything else becomes a
    /// command (Return is `insertNewline:`).
    final class ScriptedInputView: AppTerminalView {
        var script: ((NSEvent, ScriptedInputView) -> Void)?

        override func interpretKeyEvents(_ events: [NSEvent]) {
            for event in events {
                if let script {
                    script(event, self)
                } else {
                    insertPlainly(event)
                }
            }
        }

        func insertPlainly(_ event: NSEvent) {
            let characters = event.characters ?? ""
            if let scalar = characters.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F, !(0xF700 ... 0xF8FF).contains(scalar.value) {
                insertText(characters, replacementRange: NSRange(location: NSNotFound, length: 0))
            } else if characters == "\r" {
                doCommand(by: #selector(NSResponder.insertNewline(_:)))
            } else {
                doCommand(by: Selector(("noop:")))
            }
        }

        func mark(_ text: String) {
            setMarkedText(
                text,
                selectedRange: NSRange(location: (text as NSString).length, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0),
            )
        }

        func commit(_ text: String) {
            insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    extension Data {
        /// Escapes and non-ASCII bytes spelled out, for failure messages.
        var visible: String {
            map { byte -> String in
                switch byte {
                case 0x1B: "\\e"
                case 0x20 ..< 0x7F: String(UnicodeScalar(byte))
                default: String(format: "\\x%02x", byte)
                }
            }.joined()
        }
    }
#endif
