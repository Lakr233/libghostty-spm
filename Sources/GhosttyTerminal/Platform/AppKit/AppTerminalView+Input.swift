//
//  AppTerminalView+Input.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    public extension AppTerminalView {
        override func keyDown(with event: NSEvent) {
            inputHandler?.handleKeyDown(with: event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.type == .keyDown else { return false }
            guard window?.firstResponder === self else { return false }
            guard let surface else { return false }

            if keyIsBinding(event, on: surface) {
                keyDown(with: event)
                return true
            }

            let equivalent: String
            switch event.charactersIgnoringModifiers {
            case "\r":
                guard event.modifierFlags.contains(.control) else {
                    return false
                }
                equivalent = "\r"

            case "/":
                guard event.modifierFlags.contains(.control),
                      event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else {
                    return false
                }
                equivalent = "_"

            default:
                if event.timestamp == 0 {
                    return false
                }

                if !event.modifierFlags.contains(.command),
                   !event.modifierFlags.contains(.control) {
                    lastPerformKeyEvent = nil
                    return false
                }

                if let lastPerformKeyEvent,
                   lastPerformKeyEvent == event.timestamp {
                    self.lastPerformKeyEvent = nil
                    equivalent = event.characters ?? ""
                    break
                }

                lastPerformKeyEvent = event.timestamp
                return false
            }

            guard let translatedEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: event.locationInWindow,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: equivalent,
                charactersIgnoringModifiers: equivalent,
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) else {
                return false
            }

            keyDown(with: translatedEvent)
            return true
        }

        override func keyUp(with event: NSEvent) {
            inputHandler?.handleKeyUp(with: event)
        }

        override func flagsChanged(with event: NSEvent) {
            inputHandler?.handleFlagsChanged(with: event)
        }

        override func doCommand(by selector: Selector) {
            if let lastPerformKeyEvent,
               let current = NSApp.currentEvent,
               lastPerformKeyEvent == current.timestamp
            {
                NSApp.sendEvent(current)
            }
        }

        @IBAction func copy(_ sender: Any?) {
            _ = surface?.performBindingAction("copy_to_clipboard")
        }

        @IBAction func paste(_ sender: Any?) {
            _ = surface?.performBindingAction("paste_from_clipboard")
        }

        @IBAction override func selectAll(_ sender: Any?) {
            _ = surface?.performBindingAction("select_all")
        }

        internal func mousePoint(from event: NSEvent) -> (x: CGFloat, y: CGFloat) {
            let point = convert(event.locationInWindow, from: nil)
            return (point.x, bounds.height - point.y)
        }

        override func mouseDown(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_LEFT,
                mods: mods.ghosttyMods
            )
        }

        override func mouseUp(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_LEFT,
                mods: mods.ghosttyMods
            )
        }

        override func rightMouseDown(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_RIGHT,
                mods: mods.ghosttyMods
            )
        }

        override func rightMouseUp(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_RIGHT,
                mods: mods.ghosttyMods
            )
        }

        override func otherMouseDown(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_MIDDLE,
                mods: mods.ghosttyMods
            )
        }

        override func otherMouseUp(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_MIDDLE,
                mods: mods.ghosttyMods
            )
        }

        override func mouseMoved(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
        }

        override func mouseDragged(with event: NSEvent) {
            mouseMoved(with: event)
        }

        override func rightMouseDragged(with event: NSEvent) {
            mouseMoved(with: event)
        }

        override func otherMouseDragged(with event: NSEvent) {
            mouseMoved(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            let scrollMods = TerminalScrollModifiers(
                precision: event.hasPreciseScrollingDeltas,
                momentum: TerminalScrollModifiers.momentumFrom(phase: event.momentumPhase)
            )
            surface?.sendMouseScroll(
                x: event.scrollingDeltaX,
                y: event.scrollingDeltaY,
                mods: scrollMods.rawValue
            )
        }

        private func keyIsBinding(
            _ event: NSEvent,
            on surface: TerminalSurface
        ) -> Bool {
            guard let rawSurface = surface.rawValue else {
                return false
            }

            var keyEvent = event.buildKeyInput(action: GHOSTTY_ACTION_PRESS)
            var bindingFlags = ghostty_binding_flags_e(rawValue: 0)
            let text = event.characters ?? ""
            return text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key_is_binding(rawSurface, keyEvent, &bindingFlags)
            }
        }
    }
#endif
