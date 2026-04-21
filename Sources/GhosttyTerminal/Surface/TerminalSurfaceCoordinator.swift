//
//  TerminalSurfaceCoordinator.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit
import MSDisplayLink

/// Shared terminal state and logic used by both UIKit and AppKit views.
///
/// Platform views own a `TerminalSurfaceCoordinator` instance and set platform-specific
/// hooks via closures. The core handles surface lifecycle, metrics
/// synchronization, and frame rendering via display link.
@MainActor
final class TerminalSurfaceCoordinator {
    weak var delegate: (any TerminalSurfaceViewDelegate)? {
        didSet { bridge.delegate = delegate }
    }

    var controller: TerminalController? {
        didSet {
            guard controller !== oldValue else { return }
            rebuildIfReady(removingBridgeFrom: oldValue)
        }
    }

    var configuration: TerminalSurfaceOptions = .init() {
        didSet {
            guard !configuration.isEquivalent(to: oldValue) else { return }
            rebuildIfReady()
        }
    }

    var surface: TerminalSurface?
    let bridge = TerminalCallbackBridge()

    // MARK: - Platform Hooks

    var isAttached: () -> Bool = { false }
    var scaleFactor: () -> Double = { 2.0 }
    var viewSize: () -> (width: Double, height: Double) = { (0, 0) }
    var platformSetup: ((inout ghostty_surface_config_s) -> Void)?
    var onMetricsUpdate: (() -> Void)?
    var onCellSizeDidChange: (() -> Void)?

    /// Called after every display-link render (`tick`).
    ///
    /// When `synchronizeMetrics` sends a new pixel size to ghostty via
    /// `setSize`, the underlying IOSurface is not rebuilt synchronously.
    /// Until the next full render pass ghostty still uses the **old**
    /// IOSurface, so it derives an incorrect `contentsScale` for the
    /// IOSurfaceLayer (e.g. old-pixel-height / new-point-height → 4.62
    /// instead of the expected 3.0). This causes a visible "jump" on
    /// every layout change (keyboard show/hide, rotation, color-scheme
    /// toggle, etc.).
    ///
    /// Platform views use this hook to silently enforce the correct
    /// `contentsScale` and `frame` on sublayers after each render,
    /// correcting any drift introduced by ghostty within a single frame.
    var onPostRender: (() -> Void)?

    private var lastMetrics: TerminalViewportMetrics?
    private var isDisplayVisible = true

    // MARK: - Display Link

    private var displayLink: DisplayLink?
    private let displayLinkTarget = DisplayLinkTarget()

    init() {
        bridge.onCellSizeChange = { [weak self] width, height in
            self?.handleCellSizeChange(width: width, height: height)
        }
    }

    func startDisplayLink() {
        guard isDisplayVisible else { return }
        guard displayLink == nil else { return }
        TerminalDebugLog.log(.lifecycle, "display link start")
        displayLinkTarget.core = self
        let link = DisplayLink()
        link.delegatingObject(displayLinkTarget)
        displayLink = link
    }

    func stopDisplayLink() {
        TerminalDebugLog.log(.lifecycle, "display link stop")
        displayLink = nil
        displayLinkTarget.core = nil
    }

    // MARK: - Surface Lifecycle

    func rebuildIfReady(removingBridgeFrom previousController: TerminalController? = nil) {
        tearDownSurface(removingBridgeFrom: previousController ?? controller)
        guard let controller else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild skipped: missing controller")
            return
        }
        guard isAttached() else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild skipped: view detached")
            return
        }

        let scale = scaleFactor()
        TerminalDebugLog.log(
            .lifecycle,
            "surface rebuild scale=\(String(format: "%.2f", scale)) \(configuration.debugSummary)"
        )
        let rawSurface = controller.createSurface(
            bridge: bridge,
            configuration: configuration,
            platformSetup: { [self] config in
                platformSetup?(&config)
                config.scale_factor = scale
            }
        )
        guard let rawSurface else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild failed")
            return
        }

        bridge.rawSurface = rawSurface
        surface = TerminalSurface(rawSurface)
        surface?.setOcclusion(isDisplayVisible)
        TerminalDebugLog.log(.lifecycle, "surface rebuild succeeded")
        synchronizeMetrics()
    }

    // MARK: - Metrics

    func synchronizeMetrics() {
        guard let surface else {
            TerminalDebugLog.log(.metrics, "synchronizeMetrics skipped: missing surface")
            return
        }

        let scale = scaleFactor()
        let size = viewSize()
        guard size.width > 0, size.height > 0 else {
            TerminalDebugLog.log(
                .metrics,
                "synchronizeMetrics skipped: invalid view size=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height))"
            )
            return
        }

        let pixelWidth = UInt32((size.width * scale).rounded(.down))
        let pixelHeight = UInt32((size.height * scale).rounded(.down))
        guard pixelWidth > 0, pixelHeight > 0 else {
            TerminalDebugLog.log(
                .metrics,
                "synchronizeMetrics skipped: invalid pixel size=\(pixelWidth)x\(pixelHeight)"
            )
            return
        }

        TerminalDebugLog.log(
            .metrics,
            "sync view=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height)) scale=\(String(format: "%.2f", scale)) pixels=\(pixelWidth)x\(pixelHeight)"
        )

        surface.setContentScale(x: scale, y: scale)
        surface.setSize(width: pixelWidth, height: pixelHeight)

        guard let surfaceSize = surface.size(),
              surfaceSize.columns > 0, surfaceSize.rows > 0
        else {
            TerminalDebugLog.log(.metrics, "sync missing grid metrics after resize")
            onMetricsUpdate?()
            return
        }

        let metrics = TerminalViewportMetrics(surfaceSize: surfaceSize, scale: scale)
        guard metrics != lastMetrics else {
            TerminalDebugLog.log(
                .metrics,
                "sync unchanged \(metrics.debugSummary)"
            )
            onMetricsUpdate?()
            return
        }

        lastMetrics = metrics
        TerminalDebugLog.log(.metrics, "sync updated \(metrics.debugSummary)")
        configuration.inMemorySession?.updateViewport(surfaceSize)
        if let delegate = delegate as? any TerminalSurfaceGridResizeDelegate {
            delegate.terminalDidResize(surfaceSize)
        } else if let delegate = delegate as? any TerminalSurfaceResizeDelegate {
            delegate.terminalDidResize(
                columns: Int(surfaceSize.columns),
                rows: Int(surfaceSize.rows)
            )
        }
        onMetricsUpdate?()
    }

    func fitToSize() {
        synchronizeMetrics()
    }

    func forceRefresh(reason: String = "unspecified") {
        guard let surface else {
            TerminalDebugLog.log(.render, "forceRefresh skipped: missing surface reason=\(reason)")
            return
        }

        TerminalDebugLog.log(.render, "forceRefresh reason=\(reason)")
        synchronizeMetrics()
        surface.refresh()
        surface.draw()
        onPostRender?()
    }

    func setDisplayVisible(_ visible: Bool) {
        guard isDisplayVisible != visible else {
            surface?.setOcclusion(visible)
            return
        }

        isDisplayVisible = visible
        surface?.setOcclusion(visible)

        if visible {
            if isAttached() {
                startDisplayLink()
            }
        } else {
            stopDisplayLink()
        }
    }
    // MARK: - Frame Rendering

    func tick() {
        TerminalDebugLog.log(.render, "tick")
        controller?.tick()
        surface?.refresh()
        surface?.draw()
        onPostRender?()
    }

    // MARK: - Focus

    func setFocus(_ focused: Bool) {
        TerminalDebugLog.log(.lifecycle, "focus=\(focused)")
        surface?.setFocus(focused)
        (delegate as? any TerminalSurfaceFocusDelegate)?
            .terminalDidChangeFocus(focused)
    }

    // MARK: - Cleanup

    func freeSurface() {
        TerminalDebugLog.log(.lifecycle, "free surface")
        tearDownSurface(removingBridgeFrom: controller)
    }

    deinit {
        displayLink = nil
    }

    private func tearDownSurface(removingBridgeFrom controller: TerminalController?) {
        TerminalDebugLog.log(.lifecycle, "tear down surface")
        if let session = configuration.inMemorySession {
            session.clearSurface(ifMatches: surface?.rawValue)
        }
        bridge.rawSurface = nil
        surface?.setFocus(false)
        surface?.free()
        surface = nil
        lastMetrics = nil
        controller?.remove(bridge)
    }

    private func handleCellSizeChange(width: UInt32, height: UInt32) {
        TerminalDebugLog.log(
            .metrics,
            "cell size changed width=\(width) height=\(height)"
        )
        synchronizeMetrics()
        onCellSizeDidChange?()
    }
}

// MARK: - DisplayLinkTarget

/// Bridges the `nonisolated` display link callback back to `@MainActor`
/// TerminalSurfaceCoordinator. Stored as a separate object because `TerminalSurfaceCoordinator` itself
/// is `@MainActor` and cannot directly conform to `nonisolated` protocol.
private final class DisplayLinkTarget: DisplayLinkDelegate, @unchecked Sendable {
    @MainActor var core: TerminalSurfaceCoordinator?

    nonisolated func synchronization(context _: DisplayLinkCallbackContext) {
        terminalRunOnMain { [weak self] in
            self?.core?.tick()
        }
    }
}
