//
//  TerminalViewState.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import SwiftUI

@available(macOS 14.0, iOS 17.0, macCatalyst 17.0, *)
@MainActor @Observable
public final class TerminalViewState {
    public internal(set) var title: String = ""
    public internal(set) var surfaceSize: TerminalGridMetrics?
    public internal(set) var isFocused: Bool = false

    public internal(set) var bellCount: Int = 0
    public internal(set) var lastBellAt: Date?

    public internal(set) var lastDesktopNotificationTitle: String?
    public internal(set) var lastDesktopNotificationBody: String?
    public internal(set) var lastDesktopNotificationAt: Date?

    public internal(set) var workingDirectory: String?

    public internal(set) var lastCommandExitCode: Int?
    public internal(set) var lastCommandDurationNanos: UInt64?

    /// The surface currently attached to a platform view, or `nil` when no
    /// view is attached. Set by ``TerminalSurfaceLifecycleDelegate`` callbacks.
    /// `weak` because the underlying coordinator owns the surface.
    @ObservationIgnored
    public internal(set) weak var surface: TerminalSurface?

    public var configuration: TerminalSurfaceOptions = .init()
    public var onClose: ((Bool) -> Void)?
    public internal(set) var controller: TerminalController

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
