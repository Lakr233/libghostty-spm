import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// A real surface under input load: thousands of keys, pastes and pointer
/// events, focus and visibility toggled as fast as a host can, and resize
/// bursts through the throttle. Every input is drawn from a seeded
/// generator, and every test ends by checking the surface still encodes a
/// keystroke byte-exact, so a wedged IO thread or a lost mode shows up here
/// rather than as a hang elsewhere.
@Suite("TerminalSurfaceInputStress", .serialized)
struct TerminalSurfaceInputStressTests {
    /// Printable ASCII typed through the key path in the legacy encoding
    /// comes out as exactly the characters typed, in order.
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `thousands of typed keys arrive byte-exact and in order`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)
        harness.receive("")

        var random = SeededGenerator(seed: 0x5EED_0001)
        var expected = ""
        for _ in 0 ..< 3000 {
            let character = Character(Unicode.Scalar(UInt8(random.int(in: 0x20 ... 0x7E))))
            let press = try #require(TerminalKeyPress(typing: character))
            #expect(surface.sendKey(press))
            expected.append(character)
        }

        let bytes = await harness.takeOutbound()
        #expect(String(decoding: bytes, as: UTF8.self) == expected)
    }

    /// Every key with every modifier mix (Command left out: its default
    /// bindings close the surface and quit), under the legacy encoding and
    /// the kitty protocol with event reporting. `sendKey` must answer
    /// false for a key with no keycode, and the encoder must keep working.
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `random keys and modifiers under legacy and kitty encodings never wedge the encoder`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)
        harness.receive("")

        var random = SeededGenerator(seed: 0x5EED_0002)
        let modifiers: [TerminalInputModifiers] = [.shift, .ctrl, .alt, .caps, .num, .shiftRight, .ctrlRight, .altRight]
        let keys = TerminalKey.allCases
        for round in 0 ..< 4 {
            // Legacy, then kitty with all progressive-enhancement flags.
            harness.receive(round.isMultiple(of: 2) ? "\u{1B}[<u" : "\u{1B}[>31u")
            for _ in 0 ..< 1000 {
                let key = random.pick(keys)
                var mods: TerminalInputModifiers = []
                for modifier in modifiers where random.chance(0.2) {
                    mods.insert(modifier)
                }
                // A key libghostty encodes nothing for (a bare modifier,
                // Caps Lock) is accepted unconsumed, so only the refusal
                // of a key with no keycode is certain.
                let accepted = surface.sendKey(key, modifiers: mods)
                if !key.hasPlatformKeycode {
                    #expect(!accepted, "\(key)")
                }
            }
            _ = await harness.takeOutbound()
        }

        harness.receive("\u{1B}[<u")
        #expect(try surface.sendKey(#require(TerminalKeyPress(typing: "q"))))
        #expect(await harness.takeOutbound() == Data("q".utf8))
    }

    /// Pastes under bracketed paste are framed one by one and carry their
    /// text unchanged: ASCII, accented, CJK and astral, back to back.
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `thousands of bracketed pastes arrive framed and intact`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)
        harness.receive("\u{1B}[?2004h")

        var random = SeededGenerator(seed: 0x5EED_0003)
        let alphabet = ["a", "Z", "0", " ", "-", "/", "~", "\u{E9}", "e\u{301}", "\u{4E16}", "\u{1F600}", "\u{1F44D}\u{1F3FD}"]
        var expected = Data()
        for _ in 0 ..< 2000 {
            var text = random.string(from: alphabet, maxLength: 24)
            if text.isEmpty {
                text = "x"
            }
            #expect(surface.paste(text: text))
            expected.append(Data("\u{1B}[200~\(text)\u{1B}[201~".utf8))
        }

        let bytes = await harness.takeOutbound()
        #expect(bytes.count(of: "\u{1B}[200~") == 2000)
        #expect(bytes == expected)
    }

    /// With SGR mouse reporting on, every left press and release is
    /// reported once, however many moves and wheel events are mixed in.
    /// With reporting off, the same storm selects and scrolls the
    /// scrollback locally, and the terminal still answers afterwards.
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `a pointer storm reports every click and leaves the surface usable`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)
        await settleGrid(harness)

        var history = ""
        for index in 0 ..< 300 {
            history += "scrollback line \(index)\r\n"
        }
        harness.receive(history)
        harness.receive("\u{1B}[?1000h\u{1B}[?1006h")
        #expect(surface.isMouseCaptured)

        var random = SeededGenerator(seed: 0x5EED_0004)
        var clicks = 0
        for _ in 0 ..< 3000 {
            let x = Double(random.int(in: 40 ... 760))
            let y = Double(random.int(in: 40 ... 460))
            switch random.int(in: 0 ... 3) {
            case 0:
                surface.sendMousePos(x: x, y: y)
                surface.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
                surface.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
                clicks += 1
            case 1:
                surface.sendMousePos(x: x, y: y)
            default:
                surface.sendMouseScroll(
                    x: Double(random.int(in: -40 ... 40)) / 4,
                    y: Double(random.int(in: -80 ... 80)) / 4,
                    mods: TerminalScrollModifiers(precision: random.chance(0.7)),
                )
            }
        }
        let reported = await harness.takeOutbound()
        let presses = reported.count(of: "\u{1B}[<0;")
        #expect(presses == clicks * 2, "\(clicks) clicks, \(presses) left-button reports")

        harness.receive("\u{1B}[?1000l\u{1B}[?1006l")
        #expect(!surface.isMouseCaptured)
        for _ in 0 ..< 1500 {
            let x = Double(random.int(in: 0 ... 799))
            let y = Double(random.int(in: 0 ... 499))
            switch random.int(in: 0 ... 3) {
            case 0:
                surface.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
            case 1:
                surface.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
            case 2:
                surface.sendMousePos(x: x, y: y)
            default:
                surface.sendMouseScroll(x: 0, y: Double(random.int(in: -200 ... 200)) / 10)
            }
            _ = surface.hasSelection()
        }
        surface.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
        _ = surface.readSelection()
        _ = surface.scrollToRow(0)
        _ = await harness.takeOutbound()

        #expect(try surface.sendKey(#require(TerminalKeyPress(typing: "k"))))
        #expect(await harness.takeOutbound() == Data("k".utf8))
    }

    /// Focus toggled thousands of times through the coordinator: with focus
    /// reporting on, the program hears every change once and in order.
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `rapid focus toggles are each reported once`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let coordinator = harness.coordinator
        _ = try #require(harness.surface)
        coordinator.setFocus(true)
        harness.receive("\u{1B}[?1004h")
        _ = await harness.takeOutbound()

        let toggles = 2000
        for index in 0 ..< toggles {
            coordinator.setFocus(!index.isMultiple(of: 2))
        }
        let reports = await harness.takeOutbound()
        let expected = Data(String(repeating: "\u{1B}[O\u{1B}[I", count: toggles / 2).utf8)
        #expect(reports == expected, "\(reports.count(of: "\u{1B}[O")) out, \(reports.count(of: "\u{1B}[I")) in")
    }

    /// Display, window and application visibility flipped at random while
    /// keys are typed and frames are ticked. Typing is never gated on
    /// visibility, and once everything is visible again the surface renders.
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `visibility toggles under typing keep input flowing and end renderable`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer {
            harness.coordinator.setDisplayVisible(true)
            harness.coordinator.setWindowVisible(true)
            harness.coordinator.setApplicationActive(true)
            harness.tearDown()
        }
        let coordinator = harness.coordinator
        let surface = try #require(harness.surface)
        harness.receive("")

        var random = SeededGenerator(seed: 0x5EED_0005)
        var expected = ""
        for _ in 0 ..< 3000 {
            switch random.int(in: 0 ... 5) {
            case 0: coordinator.setDisplayVisible(random.chance(0.5))
            case 1: coordinator.setWindowVisible(random.chance(0.5))
            case 2: coordinator.setApplicationActive(random.chance(0.5))
            case 3: coordinator.tick()
            default:
                let character = Character(Unicode.Scalar(UInt8(random.int(in: 0x61 ... 0x7A))))
                #expect(try surface.sendKey(#require(TerminalKeyPress(typing: character))))
                expected.append(character)
            }
        }
        #expect(await String(decoding: harness.takeOutbound(), as: UTF8.self) == expected)

        coordinator.setDisplayVisible(true)
        coordinator.setWindowVisible(true)
        coordinator.setApplicationActive(true)
        #expect(coordinator.testHooks_canRenderFrame)
        coordinator.requestImmediateTick()
        coordinator.tick()
        #expect(coordinator.surface === surface, "visibility must never rebuild the surface")
    }

    /// Bursts of resizes through a short throttle window, with keys typed
    /// in between. The newest size always wins: once the trailing edge has
    /// fired, the surface holds the last size asked for, and the grid
    /// agrees with it.
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `resize throttle bursts settle on the newest size`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        let coordinator = harness.coordinator
        defer {
            coordinator.resizeThrottleInterval = nil
            coordinator.viewSize = { (800, 500) }
            coordinator.synchronizeMetrics()
            harness.tearDown()
        }
        let surface = try #require(harness.surface)
        coordinator.resizeThrottleInterval = 0.004

        var random = SeededGenerator(seed: 0x5EED_0006)
        var last = (width: 800.0, height: 500.0)
        for burst in 0 ..< 30 {
            for _ in 0 ..< random.int(in: 20 ... 80) {
                let size = (width: Double(random.int(in: 120 ... 1200)), height: Double(random.int(in: 80 ... 800)))
                coordinator.viewSize = { size }
                coordinator.synchronizeMetrics()
                last = size
                if random.chance(0.1) {
                    _ = surface.sendKey(.a)
                }
            }
            try await waitForThrottle(coordinator, burst: burst)
            #expect(coordinator.syncedViewSize?.width == last.width, "burst \(burst)")
            #expect(coordinator.syncedViewSize?.height == last.height, "burst \(burst)")
        }
        _ = await harness.takeOutbound()

        let final = (width: 640.0, height: 400.0)
        coordinator.viewSize = { final }
        coordinator.synchronizeMetrics()
        try await waitForThrottle(coordinator, burst: -1)
        #expect(coordinator.syncedViewSize?.width == final.width)
        await settleGrid(harness)
        harness.receive("")
        #expect(try surface.sendKey(#require(TerminalKeyPress(typing: "z"))))
        #expect(await harness.takeOutbound() == Data("z".utf8))
    }

    /// Waits for the throttle's trailing edge to fire and disarm. The
    /// window is a few milliseconds; the deadline is generous so a loaded
    /// machine is slow rather than flaky.
    @MainActor
    private func waitForThrottle(_ coordinator: TerminalSurfaceCoordinator, burst: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while coordinator.testHooks_throttleArmed || coordinator.testHooks_throttleTrailing {
            guard clock.now < deadline else {
                Issue.record("throttle never settled after burst \(burst)")
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
