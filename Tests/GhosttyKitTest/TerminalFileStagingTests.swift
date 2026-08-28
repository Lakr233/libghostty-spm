import Foundation
@testable import GhosttyTerminal
import Testing
import UniformTypeIdentifiers

struct TerminalFileStagingTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-staging-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func `file names keep what the provider brought and fill in the rest`() {
        #expect(TerminalFileStaging.fileName(suggested: "Report.pdf", type: .pdf) == ("Report", "pdf"))
        #expect(TerminalFileStaging.fileName(suggested: "photo", type: .jpeg) == ("photo", "jpeg"))
        #expect(TerminalFileStaging.fileName(suggested: nil, type: .png) == ("image", "png"))
        #expect(TerminalFileStaging.fileName(suggested: "", type: .pdf) == ("file", "pdf"))
    }

    @Test
    func `only images and documents count as files`() {
        #expect(TerminalFileStaging.fileType(among: [UTType.fileURL.identifier, UTType.png.identifier]) == .png)
        #expect(TerminalFileStaging.fileType(among: [UTType.pdf.identifier]) == .pdf)
        #expect(TerminalFileStaging.fileType(among: [UTType.utf8PlainText.identifier]) == nil)
        #expect(TerminalFileStaging.fileType(among: [UTType.url.identifier, UTType.fileURL.identifier]) == nil)
        #expect(TerminalFileStaging.fileType(among: [UTType.folder.identifier, UTType.fileURL.identifier]) == nil)
    }

    @Test
    func `unique urls add a counter only on collision and never a separator`() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = TerminalFileStaging.uniqueURL(name: "a/b\nc", extension: "txt", in: directory)
        #expect(first.lastPathComponent.hasPrefix("a_b_c-"))
        #expect(first.pathExtension == "txt")
        try Data().write(to: first)
        let second = TerminalFileStaging.uniqueURL(name: "a/b\nc", extension: "txt", in: directory)
        #expect(second != first)
        #expect(second.lastPathComponent.hasSuffix("-1.txt"))
    }

    @Test
    func `stored files are world readable`() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = try #require(TerminalFileStaging.store(name: "note", extension: "txt", in: directory) {
            try Data("hi".utf8).write(to: $0)
        })
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect(attributes[.posixPermissions] as? Int == 0o644)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "hi")
    }

    @Test
    func `preparing the directory sweeps only stale files`() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stale = directory.appendingPathComponent("old.txt")
        let fresh = directory.appendingPathComponent("new.txt")
        try Data().write(to: stale)
        try Data().write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * 60 * 60)],
            ofItemAtPath: stale.path
        )
        #expect(TerminalFileStaging.prepareDirectory(directory, staleAge: 60 * 60))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test
    @MainActor
    func `remove all deletes the directory and tolerates its absence`() throws {
        let directory = try makeDirectory()
        let previous = TerminalFileStaging.directory
        defer { TerminalFileStaging.directory = previous }
        TerminalFileStaging.directory = directory
        try Data().write(to: directory.appendingPathComponent("a.png"))
        TerminalFileStaging.removeAllFiles()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        TerminalFileStaging.removeAllFiles()
    }

    @Test
    @MainActor
    func `staging copies a provider's file and returns its escaped path`() async throws {
        let directory = try makeDirectory()
        let previous = TerminalFileStaging.directory
        defer {
            TerminalFileStaging.directory = previous
            try? FileManager.default.removeItem(at: directory)
        }
        TerminalFileStaging.directory = directory.appendingPathComponent("staged dir", isDirectory: true)

        let source = directory.appendingPathComponent("My File.txt")
        try Data("dropped".utf8).write(to: source)
        let provider = try #require(NSItemProvider(contentsOf: source))

        let result = await withCheckedContinuation { continuation in
            TerminalFileStaging.stage([TerminalFileStaging.Item(provider: provider, type: .plainText)]) { paths in
                continuation.resume(returning: paths)
            }
        }
        let escaped = try #require(result)
        let path = escaped.replacingOccurrences(of: "\\ ", with: " ")
        #expect(escaped.contains("staged\\ dir/"))
        #expect(path.hasSuffix(".txt"))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "dropped")
    }
}
