//
//  GhosttyThemeDefinition+TerminalConfiguration.swift
//  libghostty-spm
//

import GhosttyTerminal

public extension GhosttyThemeDefinition {
    func toTerminalConfiguration() -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withBackground(background)
            builder.withForeground(foreground)
            if let cursorColor {
                builder.withCursorColor(cursorColor)
            }
            if let cursorText {
                builder.withCursorText(cursorText)
            }
            if let selectionBackground {
                builder.withSelectionBackground(selectionBackground)
            }
            if let selectionForeground {
                builder.withSelectionForeground(selectionForeground)
            }
            for (index, color) in palette.sorted(by: { $0.key < $1.key }) {
                builder.withPalette(index, color: "#\(color)")
            }
        }
    }

    func toTerminalTheme() -> TerminalTheme {
        let config = toTerminalConfiguration()
        return TerminalTheme(light: config, dark: config)
    }

    /// Whether this theme appears to be a dark theme based on background luminance.
    var isDark: Bool {
        let hex = background.hasPrefix("#") ? String(background.dropFirst()) : background
        guard hex.count >= 6,
              let r = UInt8(hex.prefix(2), radix: 16),
              let g = UInt8(hex.dropFirst(2).prefix(2), radix: 16),
              let b = UInt8(hex.dropFirst(4).prefix(2), radix: 16)
        else { return true }
        let luminance = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
        return luminance < 128
    }
}
