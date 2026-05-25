//
//  TerminalViewState.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import SwiftUI

@MainActor
public final class TerminalViewState: ObservableObject {
    @Published public internal(set) var title: String = ""
    @Published public internal(set) var surfaceSize: TerminalGridMetrics?
    @Published public internal(set) var isFocused: Bool = false

    @Published public internal(set) var bellCount: Int = 0
    @Published public internal(set) var lastBellAt: Date?

    @Published public internal(set) var lastDesktopNotificationTitle: String?
    @Published public internal(set) var lastDesktopNotificationBody: String?
    @Published public internal(set) var lastDesktopNotificationAt: Date?

    @Published public internal(set) var workingDirectory: String?

    @Published public internal(set) var lastCommandExitCode: Int?
    @Published public internal(set) var lastCommandDurationNanos: UInt64?

    public internal(set) weak var surface: TerminalSurface?

    @Published public var configuration: TerminalSurfaceOptions = .init()
    public var onClose: ((Bool) -> Void)?
    @Published public internal(set) var controller: TerminalController

    /// Sends text to the attached surface.
    @discardableResult
    public func send(_ text: String) -> Bool {
        guard let surface else {
            TerminalDebugLog.log(.input, "view state send ignored: missing surface")
            return false
        }
        return surface.sendText(text)
    }

    public convenience init() {
        self.init(configSource: .none)
    }

    public convenience init(configFilePath: String?) {
        if let configFilePath {
            self.init(configSource: .file(configFilePath))
        } else {
            self.init(configSource: .none)
        }
    }

    public init(
        configSource: TerminalController.ConfigSource = .none,
        theme: TerminalTheme = .default,
        terminalConfiguration: TerminalConfiguration = .init()
    ) {
        controller = TerminalController(
            configSource: configSource,
            theme: theme,
            terminalConfiguration: terminalConfiguration
        )
    }

    public init(controller: TerminalController) {
        self.controller = controller
    }

    // MARK: - Forwarded from Controller (single source of truth)

    public var renderedConfig: String {
        controller.renderedConfig
    }

    public var effectiveColorScheme: TerminalColorScheme {
        controller.effectiveColorScheme
    }

    public var theme: TerminalTheme {
        controller.theme
    }

    public var terminalConfiguration: TerminalConfiguration {
        controller.terminalConfiguration
    }
}
