import AppKit
import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

// Every key goes through `ghostty_surface_key` on every backend — the
// in-memory backend forwards the core encoder's output to the host, so no
// raw-byte side channel exists. These tests pin the platform keycode
// mappings that feed the key events.
struct TerminalHardwareKeyRouterTests {
    @Test
    func `maps UI kit usages to ghostty keys`() {
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forUIKitUsage: 0x28) == GHOSTTY_KEY_ENTER)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forUIKitUsage: 0x29) == GHOSTTY_KEY_ESCAPE)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forUIKitUsage: 0x2A) == GHOSTTY_KEY_BACKSPACE)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forUIKitUsage: 0x2B) == GHOSTTY_KEY_TAB)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forUIKitUsage: 0x50) == GHOSTTY_KEY_ARROW_LEFT)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forUIKitUsage: 0x52) == GHOSTTY_KEY_ARROW_UP)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forUIKitUsage: 0x04) == GHOSTTY_KEY_A)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forUIKitUsage: 0xFF) == GHOSTTY_KEY_UNIDENTIFIED)
    }

    @Test
    func `maps app kit key codes to ghostty keys`() {
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forAppKitKeyCode: 0x7B) == GHOSTTY_KEY_ARROW_LEFT)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forAppKitKeyCode: 0x75) == GHOSTTY_KEY_DELETE)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forAppKitKeyCode: 0x30) == GHOSTTY_KEY_TAB)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forAppKitKeyCode: 0x00) == GHOSTTY_KEY_A)
    }

    @Test
    func `maps app kit higher function and volume key codes to ghostty keys`() {
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forAppKitKeyCode: 0x40) == GHOSTTY_KEY_F17)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forAppKitKeyCode: 0x5A) == GHOSTTY_KEY_F20)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forAppKitKeyCode: 0x48) == GHOSTTY_KEY_AUDIO_VOLUME_UP)
        #expect(TerminalHardwareKeyRouter.ghosttyKey(forAppKitKeyCode: 0x4A) == GHOSTTY_KEY_AUDIO_VOLUME_MUTE)
    }

    @Test
    func `app kit interpreted commands are replayed as key events`() {
        #expect(
            TerminalKeyEventHandler.shouldReplayInterpretedCommand(
                #selector(NSResponder.insertTab(_:))
            )
        )
        #expect(
            TerminalKeyEventHandler.shouldReplayInterpretedCommand(
                NSSelectorFromString("insertBacktab:")
            )
        )
        #expect(
            TerminalKeyEventHandler.shouldReplayInterpretedCommand(
                #selector(NSResponder.moveUp(_:))
            )
        )
    }

    /// Quote HID 0x34 must translate to AppKit keycode 0x27, not fall
    /// through to `0` (which is AppKit's keycode for the `A` key) nor to
    /// `GHOSTTY_KEY_QUOTE.rawValue` (which happens to equal AppKit's
    /// keycode for Tab — the original bug).
    @Test
    func `app kit key code for UI kit translates quote to mac keycode`() {
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x34) == 0x27
        )
    }

    @Test
    func `app kit key code for UI kit translates common keys`() {
        // Letter A: HID 0x04 → AppKit 0x00
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x04) == 0x00
        )
        // Tab: HID 0x2B → AppKit 0x30
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x2B) == 0x30
        )
        // Enter: HID 0x28 → AppKit 0x24
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x28) == 0x24
        )
        // ArrowUp: HID 0x52 → AppKit 0x7E
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x52) == 0x7E
        )
    }

    @Test
    func `app kit key code for ghostty keys translates common keys`() {
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_A) == 0x00
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_TAB) == 0x30
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_ESCAPE) == 0x35
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_ARROW_LEFT) == 0x7B
        )
    }

    @Test
    func `app kit key code for ghostty keys translates higher function and volume keys`() {
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_F17) == 0x40
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_F18) == 0x4F
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_F19) == 0x50
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_F20) == 0x5A
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_AUDIO_VOLUME_UP) == 0x48
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_AUDIO_VOLUME_DOWN) == 0x49
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_AUDIO_VOLUME_MUTE) == 0x4A
        )
    }

    @Test
    func `app kit key code for ghostty keys returns sentinel for keys absent from mac`() {
        let sentinel = TerminalHardwareKeyRouter.unidentifiedAppKitKeyCode
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_CONTEXT_MENU) == sentinel
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_INSERT) == sentinel
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_CUT) == sentinel
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_INTL_BACKSLASH) == sentinel
        )
    }

    /// HID usages that have no AppKit counterpart must not collapse to `0`
    /// (AppKit's keycode for `A`). They must return the sentinel so
    /// libghostty's native-keycode lookup resolves them to `.unidentified`.
    @Test
    func `app kit key code for UI kit returns sentinel for keys absent from mac`() {
        let sentinel = TerminalHardwareKeyRouter.unidentifiedAppKitKeyCode
        // CUT, COPY, PASTE, CONTEXT_MENU, INSERT, PRINT_SCREEN, SCROLL_LOCK,
        // PAUSE and the higher function keys past F20 are in uiKitMap but
        // have no AppKit virtual keycode.
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x7B) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x7C) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x7D) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x65) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x49) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x46) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x47) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x48) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x70) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x71) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x72) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x73) == sentinel)
    }

    @Test
    func `app kit key code for UI kit translates divergent and higher function keys`() {
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x53) == 0x47
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x6C) == 0x40
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x6D) == 0x4F
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x6E) == 0x50
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x6F) == 0x5A
        )
    }

    @Test
    func `app kit key code for UI kit translates volume keys`() {
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x7F) == 0x4A
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x80) == 0x48
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x81) == 0x49
        )
    }

    /// The pinned Ghostty keycode table resolves the international backslash
    /// HID usage (`0x64`) to AppKit's ISO section keycode (`0x0A`).
    @Test
    func `app kit key code for UI kit translates intl backslash key`() {
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x64) == 0x0A
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x32)
                == TerminalHardwareKeyRouter.unidentifiedAppKitKeyCode
        )
    }

    @Test
    func `app kit key code for UI kit returns sentinel for unknown HID`() {
        // HID usages not in uiKitMap at all.
        let sentinel = TerminalHardwareKeyRouter.unidentifiedAppKitKeyCode
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0xFFFE) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x0001) == sentinel)
    }
}

@MainActor
struct TerminalSemanticReturnIntegrationTests {
    @Test
    func `semantic return uses kitty key encoding while bracketed paste is active`() async {
        let outbound = KeyRouterLockedValues<Data>()
        let session = InMemoryTerminalSession(
            write: { outbound.append($0) },
            resize: { _ in }
        )
        let platformView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        platformView.wantsLayer = true

        let coordinator = TerminalSurfaceCoordinator()
        coordinator.isAttached = { true }
        coordinator.scaleFactor = { 1 }
        coordinator.viewSize = { (800, 500) }
        coordinator.platformSetup = { config in
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform = ghostty_platform_u(
                macos: ghostty_platform_macos_s(
                    nsview: Unmanaged.passUnretained(platformView).toOpaque()
                )
            )
        }
        coordinator.configuration = TerminalSurfaceOptions(
            backend: .inMemory(session)
        )
        coordinator.controller = TerminalController()
        defer { coordinator.freeSurface() }

        #expect(session.currentSurface != nil)
        // Kitty keeps Enter in legacy form unless report-all (bit 8) is
        // active, so combine it with disambiguate (bit 1).
        session.receive(Data("\u{1B}[?2004h\u{1B}[>9u".utf8))
        session.waitForPendingOutput()
        outbound.removeAll()

        var enter = ghostty_input_key_s()
        enter.action = GHOSTTY_ACTION_PRESS
        enter.keycode = TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x28)
        #expect(coordinator.surface?.sendKeyEvent(enter) == true)

        session.receive(Data("\u{1B}[c".utf8))
        session.waitForPendingOutput()
        #expect(await waitForKeyRouterDeviceAttributes(in: outbound))

        let bytes = outbound.values.reduce(into: Data()) { $0.append($1) }
        #expect(bytes.nonOverlappingCount(of: Data("\u{1B}[13u".utf8)) == 1)
        #expect(!bytes.contains(0x0A))
        #expect(!bytes.contains(0x0D))
    }
}

private final class KeyRouterLockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

private func waitForKeyRouterDeviceAttributes(
    in outbound: KeyRouterLockedValues<Data>
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    let prefix = Data("\u{1B}[?62;22".utf8)
    while clock.now < deadline {
        let bytes = outbound.values.reduce(into: Data()) { $0.append($1) }
        if bytes.range(of: prefix) != nil {
            return true
        }
        await Task.yield()
    }
    return false
}

private extension Data {
    func nonOverlappingCount(of needle: Data) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = startIndex
        while searchStart < endIndex,
              let range = range(of: needle, in: searchStart ..< endIndex)
        {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}
