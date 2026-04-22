//
//  TerminalController.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Manages the Ghostty app lifecycle, configuration loading, and surface
/// creation.
///
/// `TerminalController` is the **single source of truth** for terminal
/// configuration, including the base config, per-session overrides, theme
/// colors, and the active color scheme. When any of these change the
/// controller re-resolves the effective config and pushes it to ghostty.
@MainActor
public final class TerminalController {
    struct PreparedConfig {
        let rawValue: ghostty_config_t
        let managedConfigURL: URL?
        let renderedContents: String
    }

    struct ConfigurationIssue: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    public enum ConfigSource: Sendable, Hashable {
        case none
        case file(String)
        case generated(String)
    }

    public static let shared = TerminalController()

    static let defaultRenderedConfig = TerminalConfiguration.default.rendered
    private static var runtimeInitialized = false

    nonisolated(unsafe) var app: ghostty_app_t?
    nonisolated(unsafe) var config: ghostty_config_t?
    var retainedBridges: [TerminalCallbackBridge] = []
    var configSource: ConfigSource
    var managedConfigURL: URL?
    var renderedConfigContents: String = TerminalController.defaultRenderedConfig

    public internal(set) var lastConfigurationIssue: String?
    var onWakeup: (() -> Void)?

    // MARK: - Config Resolution State

    /// The base config before theme/colorScheme are applied.
    private let baseConfigSource: ConfigSource
    private var baseConfigTemplate: String = ""

    /// Per-session configuration overrides (e.g. font size changes).
    public private(set) var terminalConfiguration: TerminalConfiguration

    /// Color theme (light + dark variants).
    public private(set) var theme: TerminalTheme

    /// The currently active color scheme.
    public private(set) var effectiveColorScheme: TerminalColorScheme = .light

    // MARK: - Public Accessors

    public var currentConfigSource: ConfigSource {
        configSource
    }

    public var renderedConfig: String {
        renderedConfigContents
    }

    // MARK: - Initializers

    /// Creates a controller with the default terminal configuration.
    public convenience init() {
        self.init(configuration: .default)
    }

    /// Creates a controller with a fully custom configuration.
    public convenience init(
        configuration: TerminalConfiguration,
        theme: TerminalTheme = .default
    ) {
        self.init(
            configSource: .generated(configuration.rendered),
            theme: theme
        )
    }

    /// Creates a controller by composing additional commands on top of
    /// the default configuration.
    ///
    ///     TerminalController {
    ///         $0.withBackgroundOpacity(0)
    ///         $0.withCustom("keybind", "super+k=text:\\x0c")
    ///     }
    public convenience init(
        theme: TerminalTheme = .default,
        configure: (inout TerminalConfiguration.Builder) -> Void
    ) {
        self.init(
            configuration: TerminalConfiguration(
                startingFrom: .default,
                configure: configure
            ),
            theme: theme
        )
    }

    /// Creates a controller that loads its configuration from a file.
    public convenience init(
        configFilePath: String?,
        theme: TerminalTheme = .default
    ) {
        guard let configFilePath else {
            self.init(configSource: .none, theme: theme)
            return
        }
        self.init(configSource: .file(configFilePath), theme: theme)
    }

    /// Low-level initialiser for full control over the config source.
    public init(
        configSource: ConfigSource = .none,
        theme: TerminalTheme = .default,
        terminalConfiguration: TerminalConfiguration = .init()
    ) {
        Self.initializeRuntimeIfNeeded()

        baseConfigSource = configSource
        self.theme = theme
        self.terminalConfiguration = terminalConfiguration
        self.configSource = configSource

        // Load the base config (without theme) so ghostty validates it.
        applyInitialConfig(source: configSource)
        baseConfigTemplate = renderedConfigContents

        // Now apply theme on top and push to ghostty.
        reconfigure()
        createApp()
    }

    // MARK: - Color Scheme

    /// Updates the active color scheme and reconfigures the terminal.
    ///
    /// Called by platform views when the OS appearance changes. This is
    /// the only method views need to call — the controller handles all
    /// config resolution internally.
    public func setColorScheme(_ scheme: TerminalColorScheme) {
        let previous = effectiveColorScheme
        guard scheme != previous else {
            if let app {
                ghostty_app_set_color_scheme(app, scheme.ghosttyValue)
            }
            return
        }

        effectiveColorScheme = scheme
        guard reconfigure() else {
            effectiveColorScheme = previous
            return
        }

        if let app {
            ghostty_app_set_color_scheme(app, scheme.ghosttyValue)
        }
    }

    // MARK: - Theme

    /// Updates the theme and reconfigures the terminal.
    @discardableResult
    public func setTheme(_ theme: TerminalTheme) -> Bool {
        guard theme != self.theme else { return false }
        let previous = self.theme
        self.theme = theme
        guard reconfigure() else {
            self.theme = previous
            return false
        }
        return true
    }

    // MARK: - Terminal Configuration

    /// Updates per-session configuration overrides and reconfigures.
    @discardableResult
    public func setTerminalConfiguration(
        _ terminalConfiguration: TerminalConfiguration
    ) -> Bool {
        guard terminalConfiguration != self.terminalConfiguration else { return false }
        let previous = self.terminalConfiguration
        self.terminalConfiguration = terminalConfiguration
        guard reconfigure() else {
            self.terminalConfiguration = previous
            return false
        }
        return true
    }

    // MARK: - Config Resolution

    @discardableResult
    private func reconfigure() -> Bool {
        let resolved = resolveEffectiveConfig()
        guard resolved.source != configSource else {
            renderedConfigContents = resolved.contents
            return true
        }
        return updateConfigSource(resolved.source)
    }

    private func resolveEffectiveConfig() -> (
        source: ConfigSource, contents: String
    ) {
        let themeConfig = theme.configuration(for: effectiveColorScheme)
        if terminalConfiguration.isEmpty, themeConfig.isEmpty {
            return (baseConfigSource, baseConfigTemplate)
        }

        let contents = GhosttyConfigRenderer.render(
            baseContents: baseConfigTemplate,
            configuration: terminalConfiguration,
            theme: themeConfig
        )
        return (.generated(contents), contents)
    }

    // MARK: - Tick

    public func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    private static func initializeRuntimeIfNeeded() {
        guard !runtimeInitialized else { return }
        runtimeInitialized = true
        ghostty_init(0, nil)
    }

    deinit {
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
        if let managedConfigURL {
            try? FileManager.default.removeItem(at: managedConfigURL)
        }
    }
}
