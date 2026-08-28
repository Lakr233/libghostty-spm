//
//  TerminalPasteboardContent.swift
//  libghostty-spm
//
//  Reference:
//  - ghostty-org/ghostty
//  - macos/Sources/Helpers/NSPasteboard+Extension.swift
//    (`getOpinionatedStringContents`: file URLs paste as escaped paths,
//    everything else as its string)
//

import Foundation
import UniformTypeIdentifiers

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// What a paste hands the terminal, read off the general pasteboard the way
/// Ghostty's macOS app reads it: files as shell-escaped paths, text as-is.
///
/// Two readers, deliberately kept apart:
///
/// - ``text(from:)`` is what ghostty's `read_clipboard` callback uses. It
///   serves the paste binding *and* a program's OSC 52 read, so it has no
///   side effects and never touches the disk.
/// - ``files(from:completion:)`` (UIKit) is for a host-driven paste when the
///   pasteboard holds raw image or document data with no path at all — a
///   screenshot, a photo, a file copied out of Files. That data is written to
///   a file first so the paste lands as a path a program can open; a program
///   asking for "the clipboard" must never trigger that write.
public enum TerminalPasteboardContent {
    #if canImport(UIKit)
        /// Where pasted data with no path of its own is written. Defaults to
        /// a `ghostty-paste` folder in the app's temporary directory; a host
        /// whose shell cannot read the app container points it somewhere both
        /// can reach.
        @MainActor
        public static var fileDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-paste", isDirectory: true)

        /// Pasted files older than this are removed whenever a new one is
        /// written; the clipboard forgets them long before that.
        static let staleFileAge: TimeInterval = 24 * 60 * 60

        /// Whether a paste would deliver anything; the edit menu asks this
        /// on every validation, so it stays on cheap pasteboard queries.
        static func hasContent(_ pasteboard: UIPasteboard = .general) -> Bool {
            if pasteboard.hasStrings || pasteboard.hasImages { return true }
            if pasteboard.contains(pasteboardTypes: [UTType.fileURL.identifier]) { return true }
            return fileType(among: pasteboard.types) != nil
        }

        /// The pasteboard as text: its string, else its file URLs as
        /// shell-escaped paths, else `nil`. No side effects.
        static func text(from pasteboard: UIPasteboard = .general) -> String? {
            if pasteboard.hasStrings, let string = pasteboard.string, !string.isEmpty {
                return string
            }
            guard pasteboard.hasURLs,
                  let paths = pasteboard.urls?.filter(\.isFileURL).map(\.path),
                  !paths.isEmpty
            else { return nil }
            TerminalDebugLog.log(.input, "paste resolved \(paths.count) file url(s)")
            return paths.map(TerminalShellEscape.escape).joined(separator: " ")
        }

        /// Image or document data on the pasteboard, written under
        /// ``fileDirectory`` and returned as space-joined shell-escaped
        /// paths, or `nil` when there is none. Completes on the main queue;
        /// the copying happens on a background queue.
        @MainActor
        static func files(
            from pasteboard: UIPasteboard = .general,
            completion: @escaping @MainActor (String?) -> Void
        ) {
            let directory = fileDirectory
            let providers = pasteboard.itemProviders.compactMap { provider in
                fileType(among: provider.registeredTypeIdentifiers).map { (provider, $0) }
            }
            guard !providers.isEmpty else {
                // A pasteboard that advertises an image without offering it
                // through an item provider: take the encoded bytes when it
                // has them, decode through `UIImage` only as a last resort.
                guard pasteboard.hasImages else {
                    completion(nil)
                    return
                }
                let encoded = [UTType.png, .jpeg, .heic].lazy
                    .compactMap { type in
                        pasteboard.data(forPasteboardType: type.identifier).map { (data: $0, type: type) }
                    }
                    .first
                let image = encoded == nil ? pasteboard.image : nil
                DispatchQueue.global(qos: .userInitiated).async {
                    guard prepareDirectory(directory) else {
                        terminalRunOnMain { completion(nil) }
                        return
                    }
                    let path: String?
                    if let encoded {
                        path = store(name: "image", extension: encoded.type.preferredFilenameExtension ?? "bin", in: directory) {
                            try encoded.data.write(to: $0, options: .atomic)
                        }
                    } else if let data = image?.pngData() {
                        path = store(name: "image", extension: "png", in: directory) {
                            try data.write(to: $0, options: .atomic)
                        }
                    } else {
                        path = nil
                    }
                    terminalRunOnMain { completion(path.map(TerminalShellEscape.escape)) }
                }
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                guard prepareDirectory(directory) else {
                    terminalRunOnMain { completion(nil) }
                    return
                }
                let group = DispatchGroup()
                let lock = NSLock()
                var paths = [String?](repeating: nil, count: providers.count)
                for (index, (provider, type)) in providers.enumerated() {
                    group.enter()
                    // The representation is deleted when the completion
                    // returns, so it is copied out before then.
                    provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                        defer { group.leave() }
                        guard let url else {
                            TerminalDebugLog.log(
                                .input,
                                "paste file representation failed type=\(type.identifier) error=\(String(describing: error))"
                            )
                            return
                        }
                        let (name, fileExtension) = fileName(suggested: provider.suggestedName, type: type)
                        let path = store(name: name, extension: fileExtension, in: directory) {
                            try FileManager.default.copyItem(at: url, to: $0)
                        }
                        lock.lock()
                        paths[index] = path
                        lock.unlock()
                    }
                }
                group.notify(queue: .main) {
                    let resolved = paths.compactMap { $0 }
                    TerminalDebugLog.log(.input, "paste resolved \(resolved.count)/\(providers.count) file(s)")
                    terminalRunOnMain {
                        completion(resolved.isEmpty ? nil : resolved.map(TerminalShellEscape.escape).joined(separator: " "))
                    }
                }
            }
        }

        /// The type worth a file among what one pasteboard item offers, or
        /// `nil` when it only carries text or a link. Images win over
        /// anything else the same item registers (a copied photo also
        /// registers its URL).
        static func fileType(among identifiers: [String]) -> UTType? {
            let types = identifiers.compactMap(UTType.init)
            if let image = types.first(where: { $0.conforms(to: .image) }) {
                return image
            }
            // Dynamic types (`dyn.a…`) are pasteboard bookkeeping.
            return types.first { type in
                !type.isDynamic
                    && type.conforms(to: .data)
                    && !type.conforms(to: .text)
                    && !type.conforms(to: .url)
            }
        }

        /// The file name a pasted item gets: its own when the provider carries
        /// one, else `image`/`file`, always with the type's preferred
        /// extension unless the name brought its own.
        static func fileName(suggested: String?, type: UTType) -> (name: String, extension: String) {
            let preferred = type.preferredFilenameExtension ?? "bin"
            guard let suggested = suggested.map({ $0 as NSString }), suggested.length > 0 else {
                return (type.conforms(to: .image) ? "image" : "file", preferred)
            }
            let existing = suggested.pathExtension
            return (
                existing.isEmpty ? suggested as String : suggested.deletingPathExtension,
                existing.isEmpty ? preferred : existing
            )
        }

        /// A path under `directory` that no earlier paste took: the name, the
        /// time in seconds, and a counter only when two pastes share both.
        /// The name loses path separators and control characters — the
        /// shell escape covers everything else.
        static func uniqueURL(name: String, extension fileExtension: String, in directory: URL) -> URL {
            let safeName = String(name.map { $0 == "/" || $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true ? "_" : $0 })
            let stamp = Int(Date().timeIntervalSince1970)
            var candidate = directory.appendingPathComponent("\(safeName)-\(stamp).\(fileExtension)")
            var counter = 1
            while FileManager.default.fileExists(atPath: candidate.path) {
                candidate = directory.appendingPathComponent("\(safeName)-\(stamp)-\(counter).\(fileExtension)")
                counter += 1
            }
            return candidate
        }

        /// Serialises name choice and write: provider completions arrive on
        /// concurrent queues, and two items with the same name would
        /// otherwise be handed the same path.
        private static let storeLock = NSLock()

        /// Writes one pasted item into `directory` — prepared by the caller,
        /// once per paste — readable by whoever can reach the directory, and
        /// returns its path, or `nil` when the write fails.
        private static func store(
            name: String,
            extension fileExtension: String,
            in directory: URL,
            write: (URL) throws -> Void
        ) -> String? {
            storeLock.lock()
            defer { storeLock.unlock() }
            let destination = uniqueURL(name: name, extension: fileExtension, in: directory)
            do {
                try write(destination)
                // A copied representation keeps the provider's mode and an
                // atomic write follows the umask; the shell that opens the
                // file may not be the app's user.
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
                return destination.path
            } catch {
                TerminalDebugLog.log(.input, "paste file write failed: \(error)")
                return nil
            }
        }

        /// Creates the paste directory, readable by anyone who can reach it
        /// (the shell may not be the app's own user), and drops pastes old
        /// enough that nothing still refers to them. Once per paste, before
        /// any file is written.
        private static func prepareDirectory(_ directory: URL) -> Bool {
            let manager = FileManager.default
            do {
                try manager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o755]
                )
            } catch {
                TerminalDebugLog.log(.input, "paste directory unavailable: \(error)")
                return false
            }
            let cutoff = Date().addingTimeInterval(-staleFileAge)
            let contents = (try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            for url in contents {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if modified < cutoff {
                    try? manager.removeItem(at: url)
                }
            }
            return true
        }

    #elseif canImport(AppKit)
        /// Upstream's `getOpinionatedStringContents`: URLs first — file URLs
        /// as escaped paths, others verbatim — then the string.
        static func text(from pasteboard: NSPasteboard = .general) -> String? {
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
                return urls
                    .map { $0.isFileURL ? TerminalShellEscape.escape($0.path) : $0.absoluteString }
                    .joined(separator: " ")
            }
            return pasteboard.string(forType: .string)
        }
    #endif
}
