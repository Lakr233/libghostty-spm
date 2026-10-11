#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    @testable import GhosttyTerminal
    import Testing
    import UniformTypeIdentifiers

    /// Drops onto the AppKit view: files as shell-escaped paths, images with
    /// no file staged first, links and text as text — all one paste. The
    /// drag pasteboards are the tests' own.
    @Suite("AppTerminalViewDrop", .serialized)
    @MainActor
    struct AppTerminalViewDropTests {
        static let start = "\u{1B}[200~", end = "\u{1B}[201~"

        @Test
        func `dropped files paste as escaped paths in one bracketed paste`() async {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }
            rig.receive("\u{1B}[?2004h")
            let drag = FakeDrag()
            defer { drag.release() }
            drag.pasteboard.writeObjects([
                URL(fileURLWithPath: "/tmp/drop test/it's (1).png") as NSURL,
                URL(fileURLWithPath: "/tmp/plain.txt") as NSURL,
            ])

            #expect(rig.view.draggingEntered(drag) == .copy)
            #expect(rig.view.performDragOperation(drag))
            let bytes = await rig.take()
            #expect(String(decoding: bytes, as: UTF8.self)
                == Self.start + #"/tmp/drop\ test/it\'s\ \(1\).png /tmp/plain.txt"# + Self.end)
        }

        @Test
        func `a host can refuse files and still take text`() async {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }
            rig.view.acceptsFileDrops = false

            let files = FakeDrag()
            defer { files.release() }
            files.pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/plain.txt") as NSURL])
            #expect(rig.view.draggingEntered(files) == [])
            #expect(!rig.view.performDragOperation(files))
            #expect(await rig.take().isEmpty)

            // A browser image: its picture can't land, its address can.
            let image = FakeDrag()
            defer { image.release() }
            image.pasteboard.declareTypes([.png, .URL, .string], owner: nil)
            image.pasteboard.setData(Self.png, forType: .png)
            image.pasteboard.setString("https://example.com/cat.png", forType: .URL)
            image.pasteboard.setString("https://example.com/cat.png", forType: .string)
            #expect(rig.view.draggingEntered(image) == .copy)
            #expect(rig.view.performDragOperation(image))
            #expect(await rig.take() == Data("https://example.com/cat.png".utf8))
        }

        @Test
        func `image data is staged and pastes as the staged file's path`() async throws {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ghostty-drop-test-\(UUID().uuidString)", isDirectory: true)
            let saved = TerminalFileStaging.directory
            TerminalFileStaging.directory = directory
            defer {
                TerminalFileStaging.directory = saved
                try? FileManager.default.removeItem(at: directory)
            }

            for (type, expected) in [(NSPasteboard.PasteboardType.png, Self.png), (.tiff, nil)] {
                let drag = FakeDrag()
                defer { drag.release() }
                let data = type == .tiff ? NSBitmapImageRep(data: Self.png)!.tiffRepresentation! : Self.png
                drag.pasteboard.declareTypes([type], owner: nil)
                drag.pasteboard.setData(data, forType: type)

                #expect(rig.view.draggingEntered(drag) == .copy)
                #expect(rig.view.performDragOperation(drag))
                var pasted = Data()
                for _ in 0 ..< 50 where pasted.isEmpty {
                    try await Task.sleep(for: .milliseconds(20))
                    pasted = await rig.take()
                }
                let path = String(decoding: pasted, as: UTF8.self)
                #expect(path.hasPrefix(directory.path) && path.hasSuffix(".png"), "\(type.rawValue) pasted \(path)")
                let staged = try Data(contentsOf: URL(fileURLWithPath: path))
                #expect(staged.starts(with: [0x89, 0x50, 0x4E, 0x47]), "not a PNG")
                if let expected { #expect(staged == expected) }
            }
        }

        @Test
        func `links and text drop as text`() async {
            let harness = await GhosttySurfaceHarness.make()
            defer { harness.tearDown() }
            let rig = AppKitInputRig()
            defer { rig.tearDown() }

            let link = FakeDrag()
            defer { link.release() }
            link.pasteboard.writeObjects([URL(string: "https://pod.codes/a b")! as NSURL])
            #expect(rig.view.performDragOperation(link))
            #expect(await rig.take() == Data("https://pod.codes/a%20b".utf8))

            let text = FakeDrag()
            defer { text.release() }
            text.pasteboard.declareTypes([.string], owner: nil)
            text.pasteboard.setString("git status", forType: .string)
            #expect(rig.view.draggingEntered(text) == .copy)
            #expect(rig.view.performDragOperation(text))
            #expect(await rig.take() == Data("git status".utf8))

            let empty = FakeDrag()
            defer { empty.release() }
            #expect(rig.view.draggingEntered(empty) == [])
        }

        /// A 1×1 PNG.
        static let png: Data = {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
            )!
            return rep.representation(using: .png, properties: [:])!
        }()
    }

    /// A drag that carries a pasteboard of its own.
    @MainActor
    final class FakeDrag: NSObject, NSDraggingInfo {
        let pasteboard = NSPasteboard(name: .init("ghostty-drop-test-\(UUID().uuidString)"))

        override init() {
            super.init()
            pasteboard.clearContents()
        }

        func release() {
            pasteboard.releaseGlobally()
        }

        var draggingPasteboard: NSPasteboard { pasteboard }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }

        func slideDraggedImage(to _: NSPoint) {}
        func enumerateDraggingItems(
            options _: NSDraggingItemEnumerationOptions = [],
            for _: NSView?,
            classes _: [AnyClass],
            searchOptions _: [NSPasteboard.ReadingOptionKey: Any] = [:],
            using _: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void,
        ) {}
        func resetSpringLoading() {}
    }
#endif
