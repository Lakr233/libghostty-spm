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
/// A shared singleton is provided for convenience but callers may also
/// create dedicated instances with custom configuration.
@MainActor
public final class TerminalController {
    public static let shared = TerminalController()

    private static var runtimeInitialized = false

    private nonisolated(unsafe) var app: ghostty_app_t?
    private nonisolated(unsafe) var config: ghostty_config_t?
    private var bridges: [TerminalSurfaceBridge] = []

    // MARK: - Initialisation

    public init(configFilePath: String? = nil) {
        Self.initializeRuntimeIfNeeded()
        loadConfig(filePath: configFilePath)
        createApp()
    }

    // MARK: - Runtime Bootstrap

    private static func initializeRuntimeIfNeeded() {
        guard !runtimeInitialized else { return }
        runtimeInitialized = true
        ghostty_init(0, nil)
    }

    // MARK: - Configuration

    private func loadConfig(filePath: String?) {
        let cfg = ghostty_config_new()
        if let path = filePath {
            ghostty_config_load_file(cfg, path)
        }
        ghostty_config_finalize(cfg)
        config = cfg
    }

    // MARK: - App Creation

    private func createApp() {
        guard let cfg = config else { return }

        let userdata = Unmanaged.passUnretained(self).toOpaque()

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = userdata
        runtimeConfig.supports_selection_clipboard = false
        runtimeConfig.wakeup_cb = wakeupCallback
        runtimeConfig.action_cb = actionCallback
        runtimeConfig.close_surface_cb = closeSurfaceCallback
        runtimeConfig.write_clipboard_cb = writeClipboardCallback
        runtimeConfig.read_clipboard_cb = readClipboardCallback

        app = ghostty_app_new(&runtimeConfig, cfg)
    }

    // MARK: - Public API

    public func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    public func setColorScheme(_ scheme: ghostty_color_scheme_e) {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, scheme)
    }

    /// Creates a new Ghostty surface with the given configuration.
    ///
    /// The `platformSetup` closure lets the caller fill in
    /// platform-specific fields (`platform_tag`, `platform`, `scale_factor`)
    /// on the raw surface config struct before the surface is created.
    func createSurface(
        bridge: TerminalSurfaceBridge,
        configuration: TerminalSurfaceConfiguration,
        platformSetup: (inout ghostty_surface_config_s) -> Void
    ) -> ghostty_surface_t? {
        guard let app else { return nil }

        bridges.append(bridge)
        let bridgePtr = Unmanaged.passUnretained(bridge).toOpaque()

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.userdata = bridgePtr

        switch configuration.backend {
        case .exec:
            surfaceConfig.backend = GHOSTTY_SURFACE_IO_BACKEND_EXEC

        case let .hostManaged(session):
            surfaceConfig.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
            let sessionPtr = Unmanaged.passUnretained(session).toOpaque()
            surfaceConfig.receive_userdata = sessionPtr
            surfaceConfig.receive_buffer = TerminalHostManagedSession.receiveBufferCallback
            surfaceConfig.receive_resize = TerminalHostManagedSession.receiveResizeCallback
        }

        if let fontSize = configuration.fontSize {
            surfaceConfig.font_size = fontSize
        }

        // Working directory — withCString keeps the pointer alive through
        // ghostty_surface_new which copies the string.
        if let workingDirectory = configuration.workingDirectory {
            return workingDirectory.withCString { wdPtr in
                surfaceConfig.working_directory = wdPtr
                surfaceConfig.context = configuration.context
                platformSetup(&surfaceConfig)
                let surface = ghostty_surface_new(app, &surfaceConfig)
                configureSurfaceSession(surface, configuration: configuration)
                return surface
            }
        }

        surfaceConfig.context = configuration.context
        platformSetup(&surfaceConfig)
        let surface = ghostty_surface_new(app, &surfaceConfig)
        configureSurfaceSession(surface, configuration: configuration)
        return surface
    }

    func removeBridge(_ bridge: TerminalSurfaceBridge) {
        bridges.removeAll { $0 === bridge }
    }

    // MARK: - Private Helpers

    private func configureSurfaceSession(
        _ surface: ghostty_surface_t?,
        configuration: TerminalSurfaceConfiguration
    ) {
        if case let .hostManaged(session) = configuration.backend {
            session.setSurface(surface)
        }
    }

    // MARK: - Deinitialization

    deinit {
        if let app {
            ghostty_app_free(app)
        }
        if let config {
            ghostty_config_free(config)
        }
    }
}

// MARK: - C Callback Trampolines

private func wakeupCallback(userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    let controller = Unmanaged<TerminalController>.fromOpaque(userdata)
        .takeUnretainedValue()
    DispatchQueue.main.async {
        controller.tick()
    }
}

private func actionCallback(
    appPtr: ghostty_app_t?,
    target: ghostty_target_s,
    action: ghostty_action_s
) -> Bool {
    guard let appPtr else { return false }
    guard let userdata = ghostty_app_userdata(appPtr) else { return false }

    if target.tag == GHOSTTY_TARGET_SURFACE,
       let surfacePtr = target.target.surface
    {
        let surfaceUserdata = ghostty_surface_userdata(surfacePtr)
        if let bridgePtr = surfaceUserdata {
            let bridge = Unmanaged<TerminalSurfaceBridge>
                .fromOpaque(bridgePtr)
                .takeUnretainedValue()
            DispatchQueue.main.async {
                bridge.handleAction(action)
            }
        }
    }

    _ = userdata
    return false
}

private func closeSurfaceCallback(
    userdata: UnsafeMutableRawPointer?,
    processAlive: Bool
) {
    guard let userdata else { return }
    let bridge = Unmanaged<TerminalSurfaceBridge>
        .fromOpaque(userdata)
        .takeUnretainedValue()
    DispatchQueue.main.async {
        bridge.handleClose(processAlive: processAlive)
    }
}

private func writeClipboardCallback(
    userdata _: UnsafeMutableRawPointer?,
    clipboard _: ghostty_clipboard_e,
    contents: UnsafePointer<ghostty_clipboard_content_s>?,
    contentsLen: Int,
    confirm _: Bool
) {
    guard contentsLen > 0 else { return }
    guard let content = contents?.pointee else { return }
    guard let data = content.data else { return }
    let string = String(cString: data)

    #if canImport(UIKit)
        UIPasteboard.general.string = string
    #elseif canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    #endif
}

private func readClipboardCallback(
    userdata _: UnsafeMutableRawPointer?,
    clipboard _: ghostty_clipboard_e,
    opaquePtr: UnsafeMutableRawPointer?
) -> Bool {
    guard let opaquePtr else { return false }

    #if canImport(UIKit)
        let string = UIPasteboard.general.string
    #elseif canImport(AppKit)
        let string = NSPasteboard.general.string(forType: .string)
    #endif

    guard let string else { return false }
    string.withCString { cStr in
        ghostty_surface_complete_clipboard_request(nil, cStr, opaquePtr, true)
    }
    return true
}
