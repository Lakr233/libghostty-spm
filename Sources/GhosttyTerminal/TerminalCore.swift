import Foundation
import GhosttyKit
import MSDisplayLink

/// Shared terminal state and logic used by both UIKit and AppKit views.
///
/// Platform views own a `TerminalCore` instance and set platform-specific
/// hooks via closures. The core handles surface lifecycle, metrics
/// synchronization, and frame rendering via display link.
@MainActor
final class TerminalCore {
    weak var delegate: (any TerminalViewDelegate)? {
        didSet { bridge.delegate = delegate }
    }

    var controller: TerminalController? {
        didSet { rebuildIfReady() }
    }

    var configuration: TerminalSurfaceConfiguration = .init() {
        didSet { rebuildIfReady() }
    }

    private(set) var surface: Surface?
    let bridge = TerminalSurfaceBridge()

    // MARK: - Platform Hooks

    var isAttached: () -> Bool = { false }
    var scaleFactor: () -> Double = { 2.0 }
    var viewSize: () -> (width: Double, height: Double) = { (0, 0) }
    var platformSetup: ((inout ghostty_surface_config_s) -> Void)?
    var onMetricsUpdate: (() -> Void)?

    // MARK: - Display Link

    private var displayLink: DisplayLink?
    private let displayLinkTarget = DisplayLinkTarget()

    func startDisplayLink() {
        guard displayLink == nil else { return }
        displayLinkTarget.core = self
        let link = DisplayLink()
        link.delegatingObject(displayLinkTarget)
        displayLink = link
    }

    func stopDisplayLink() {
        displayLink = nil
        displayLinkTarget.core = nil
    }

    // MARK: - Surface Lifecycle

    func rebuildIfReady() {
        surface?.free()
        surface = nil

        guard let controller else { return }
        guard isAttached() else { return }

        let scale = scaleFactor()
        let rawSurface = controller.createSurface(
            bridge: bridge,
            configuration: configuration
        ) { [self] config in
            platformSetup?(&config)
            config.scale_factor = scale
        }

        if let rawSurface {
            surface = Surface(rawSurface)
            synchronizeMetrics()
        }
    }

    // MARK: - Metrics

    func synchronizeMetrics() {
        guard let surface else { return }
        let scale = scaleFactor()
        let size = viewSize()
        guard size.width > 0, size.height > 0 else { return }

        surface.setContentScale(x: scale, y: scale)
        surface.setSize(
            width: UInt32(size.width * scale),
            height: UInt32(size.height * scale)
        )

        if let termSize = surface.size(),
           termSize.columns > 0, termSize.rows > 0
        {
            delegate?.terminalDidResize(
                columns: Int(termSize.columns),
                rows: Int(termSize.rows)
            )
        }

        onMetricsUpdate?()
    }

    func fitToSize() {
        synchronizeMetrics()
    }

    // MARK: - Frame Rendering

    func tick() {
        controller?.tick()
        surface?.refresh()
        surface?.draw()
    }

    // MARK: - Focus

    func setFocus(_ focused: Bool) {
        surface?.setFocus(focused)
    }

    // MARK: - Cleanup

    func freeSurface() {
        surface?.setFocus(false)
        surface?.free()
        surface = nil
    }

    deinit {
        displayLink = nil
    }
}

// MARK: - DisplayLinkTarget

/// Bridges the `nonisolated` display link callback back to `@MainActor`
/// TerminalCore. Stored as a separate object because `TerminalCore` itself
/// is `@MainActor` and cannot directly conform to `nonisolated` protocol.
private final class DisplayLinkTarget: DisplayLinkDelegate, @unchecked Sendable {
    @MainActor var core: TerminalCore?

    nonisolated func synchronization(context _: DisplayLinkCallbackContext) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.core?.tick()
            }
        }
    }
}
