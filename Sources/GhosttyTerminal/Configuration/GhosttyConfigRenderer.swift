//
//  GhosttyConfigRenderer.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

import Foundation

enum GhosttyConfigRenderer {
    static func render(
        baseContents: String,
        configuration: TerminalConfiguration,
        theme: TerminalConfiguration
    ) -> String {
        var sections: [String] = []

        let normalizedBase = normalize(baseContents)
        if !normalizedBase.isEmpty {
            sections.append(normalizedBase)
        }

        let configurationLines = configuration.commands.map(\.renderedLine)
        if !configurationLines.isEmpty {
            sections.append(configurationLines.joined(separator: "\n"))
        }

        let themeLines = theme.commands.map(\.renderedLine)
        if !themeLines.isEmpty {
            sections.append(themeLines.joined(separator: "\n"))
        }

        #if os(macOS)
        // Ghostty core defaults `shell-integration` to `.detect`, which now
        // actually does something since this package always points
        // GHOSTTY_RESOURCES_DIR at its bundled scripts. Force `none` unless
        // something above already set it, so hosts who never opted in don't
        // silently get their shell's startup rewritten.
        if !sections.contains(where: { setsKey("shell-integration", in: $0) }) {
            sections.append("shell-integration = none")
        }
        #endif

        guard !sections.isEmpty else { return "" }
        return sections.joined(separator: "\n") + "\n"
    }

    #if os(macOS)
    private static func setsKey(_ key: String, in section: String) -> Bool {
        section.split(separator: "\n").contains {
            $0.split(separator: "=", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces) == key
        }
    }
    #endif

    private static func normalize(_ contents: String) -> String {
        contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
