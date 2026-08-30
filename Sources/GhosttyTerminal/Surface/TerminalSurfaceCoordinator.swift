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
/// synchronization, and frame rendering via scheduled wakeups.
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

    /// The view size, in points, the surface was last sized to. While a
    /// resize throttle window is open this trails the live bounds: the
    /// surface's IOSurface is still the old size, so a platform layer that
    /// stretches to the new bounds shows the old pixels scaled — and the
    /// engine, deriving `contentsScale` from old pixels over new points,
    /// fights the host's correction on every tick. A UIKit host keeps its
    /// sublayer at *this* size until the trailing sync lands, so the gap
    /// shows background instead of a stretched frame. `nil` until the first
    /// sync and after teardown.
    private(set) var syncedViewSize: (width: Double, height: Double)?

    private var isDisplayVisible = true
    /// The last visibility the SwiftUI host declared through
    /// `TerminalViewState.isSurfaceVisible`. The representable forwards only
    /// changes to this value, so an imperative `setSurfaceVisible` call made
    /// between SwiftUI updates is not silently reverted by every refresh
    /// re-stamping the declarative default.
    var hostDeclaredDisplayVisible: Bool?
    private var isApplicationActive = true
    private var pendingImmediateTick = true
    private var lastTickTimestamp: TimeInterval = 0

    /// Held only while frames are owed. The engine's wakeups arrive at PTY
    /// speed, not display speed; rendering straight from them draws far more
    /// often than the screen can show and starves input handling under heavy
    /// output. The link paces draws to vsync instead, and is released after
    /// a stretch of idle frames so a quiet terminal costs no per-frame
    /// wakeups at all. All instances share one platform link.
    ///
    /// The range floors at 60: letting the system drop to 30 while output
    /// streams read as flicker on a scrolling screen. ProMotion displays may
    /// go to 120.
    private var displayLink: DisplayLink?
    private var idleFrameCount = 0
    private static let displayLinkFrameRateRange = DisplayLinkFrameRateRange(
        minimum: 60, maximum: 120, preferred: 120
    )
    private static let idleFramesBeforeRelease = 30

    init() {
        bridge.onCellSizeChange = { [weak self] width, height in
            self?.handleCellSizeChange(width: width, height: height)
        }
        bridge.onRenderRequest = { [weak self] in
            self?.requestImmediateTick()
        }
    }

    func requestImmediateTick() {
        pendingImmediateTick = true
        ensureDisplayLink()
    }

    func startDisplayLink() {
        ensureDisplayLink()
    }

    func stopDisplayLink() {
        releaseDisplayLink()
    }

    // MARK: - Surface Lifecycle

    func rebuildIfReady(removingBridgeFrom previousController: TerminalController? = nil) {
        // A pane that is merely hidden reports a zero size. Tearing the surface
        // down here and then bailing out at the size guard below would destroy
        // ghostty's grid and scrollback for a condition that is temporary: when
        // the pane comes back there is nothing left to show, and only the app
        // redrawing can refill it. Keep the surface — the caller re-runs this
        // once the view has a usable size again.
        //
        // This is the same intent as the reattach guard in viewDidMoveToWindow
        // ("rebuilding on every reattach discards Ghostty's scrollback/state"),
        // which cannot help while the teardown happens before the checks.
        if surface != nil, previousController == nil, !hasValidViewSize {
            // The rebuild is owed, not cancelled. Configuration options are
            // consumed only by createSurface, and no caller re-runs this once
            // the view regains a size (fitToSize, viewDidMoveToWindow and the
            // UIKit twin all take the surface != nil branch and merely sync
            // metrics). Dropping the request outright would leave a hidden
            // pane running its old configuration indefinitely.
            pendingRebuild = true
            let size = viewSize()
            TerminalDebugLog.log(
                .lifecycle,
                "surface kept: view size temporarily invalid \(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height))"
            )

            return
        }
        pendingRebuild = false

        tearDownSurface(removingBridgeFrom: previousController ?? controller)
        guard let controller else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild skipped: missing controller")
            return
        }
        guard isAttached() else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild skipped: view detached")
            return
        }
        guard hasValidViewSize else {
            let size = viewSize()
            TerminalDebugLog.log(
                .lifecycle,
                "surface rebuild skipped: invalid view size=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height))"
            )
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
        let newSurface = TerminalSurface(rawSurface)
        surface = newSurface
        newSurface.setOcclusion(effectiveSurfaceVisible)
        // Wakeups must keep draining while the surface is merely occluded:
        // the app mailbox (titles, pwd, bell, child-exit) only empties in
        // ghostty_app_tick, and a full mailbox blocks the session's write
        // thread on its next push. Only a detached surface or a
        // backgrounded app suspends ticks — visibility gates rendering
        // alone (canRenderFrame).
        controller.addWakeupObserver(
            ObjectIdentifier(self),
            shouldProcess: { [weak self] in
                guard let self else { return false }
                return isApplicationActive && isAttached()
            },
            onWakeup: { [weak self] in
                self?.requestImmediateTick()
            }
        )
        TerminalDebugLog.log(.lifecycle, "surface rebuild succeeded")
        (delegate as? any TerminalSurfaceLifecycleDelegate)?
            .terminalDidAttachSurface(newSurface)
        synchronizeMetrics()
        requestImmediateTick()
    }

    // MARK: - Metrics

    // Ghostty's IO thread coalesces resize messages with a hardcoded 25ms
    // trailing-only window (Thread.zig). For an alt-screen TUI that fully
    // repaints on every winsize (Claude Code), a live divider drag posts new
    // sizes faster than that window resolves — the grid reflow runs
    // permanently behind the layer bounds and the renderer composites the
    // stale grid into the new frame: the mid-drag collapse. Bounding the
    // stream (leading edge for responsiveness, trailing edge so the final
    // size always lands) hands the engine a signal it can settle on.
    //
    // The right window is CONTENT-dependent, so it is a per-surface value
    // the host sets (`TerminalSurfaceOptions.resizeThrottleMilliseconds`, or
    // the platform setter for a live change): a primary-screen transcript
    // that never re-emits its scrollback (codex-style) renders best fully
    // unthrottled — large throttled jumps read as blinking — while the
    // alt-screen full-repaint agents need ~96ms. 0 disables. The env var
    // GHOSTTY_SURFACE_RESIZE_THROTTLE_MS, when set, overrides every surface
    // for whole-process A/B runs.
    private static let resizeThrottleOverride: TimeInterval? = {
        guard
            let raw = ProcessInfo.processInfo
                .environment["GHOSTTY_SURFACE_RESIZE_THROTTLE_MS"],
            let ms = Double(raw), ms >= 0
        else { return nil }
        return ms / 1000
    }()

    /// Set directly by a platform view; otherwise sourced from
    /// `configuration.resizeThrottleMilliseconds`. Kept as an override so the
    /// AppKit setter can adjust a live surface without rebuilding it.
    var resizeThrottleInterval: TimeInterval?

    private var effectiveResizeThrottle: TimeInterval {
        if let override = Self.resizeThrottleOverride { return override }
        if let interval = resizeThrottleInterval { return interval }
        return max(0, configuration.resizeThrottleMilliseconds) / 1000
    }

    private var resizeThrottleArmed = false
    private var resizeThrottleTrailing = false
    /// Invalidates in-flight throttle timers across a teardown. A timer
    /// armed for the old surface must not size — or re-arm against — the
    /// surface that replaced it.
    private var resizeThrottleGeneration = 0
    /// A rebuild deferred by the zero-size guard above, replayed by
    /// `synchronizeMetrics` as soon as the view has a usable size again.
    private var pendingRebuild = false

    func synchronizeMetrics() {
        // Redeem a rebuild the zero-size guard deferred. Every caller that
        // could restore a usable size lands here, so this is the one place
        // that reliably observes the transition.
        if pendingRebuild, hasValidViewSize {
            pendingRebuild = false
            rebuildIfReady()
            return
        }

        guard effectiveResizeThrottle > 0 else {
            performMetricsSync()
            return
        }

        guard !resizeThrottleArmed else {
            // Newest wins: the trailing fire re-reads the live view size,
            // so nothing needs to be captured here.
            resizeThrottleTrailing = true
            return
        }

        performMetricsSync()
        armResizeThrottle()
    }

    private func armResizeThrottle() {
        resizeThrottleArmed = true
        let generation = resizeThrottleGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + effectiveResizeThrottle
        ) { [weak self] in
            guard let self else { return }
            // A teardown bumped the generation: this timer belongs to a
            // surface that no longer exists. Returning without touching
            // `resizeThrottleArmed` leaves the current surface's own state
            // alone.
            guard generation == resizeThrottleGeneration else { return }
            resizeThrottleArmed = false
            guard resizeThrottleTrailing else { return }
            resizeThrottleTrailing = false
            guard surface != nil else { return }
            performMetricsSync()
            armResizeThrottle()
        }
    }

    private func performMetricsSync() {
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
        syncedViewSize = size

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
        // Deliberately no host resize dispatch here. This runs on the AppKit
        // thread right after setSize(), i.e. before the engine's IO thread has
        // run the resize operation at all — the host would learn the new size
        // from a thread that has not yet reflowed anything.
        //
        // Worse, it poisons the correctly-phased notification: the IO thread's
        // `receiveResizeCallback` (invoked from HostManaged.resize, immediately
        // before `terminal.resize`, both serial within one IO-thread resize
        // operation) then arrives carrying a size the session already recorded,
        // and is discarded as unchanged. A relative-cursor TUI therefore
        // repainted against a winsize that led the grid, and its clamped CUD
        // merged the footer.
        //
        // Leaving `receiveResizeCallback` as the sole PTY-resize source matches
        // stock Ghostty, where pty.setSize runs only inside Termio.resize.
        // Local UI metrics still flow via the delegate below and
        // onMetricsUpdate.
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
        if surface == nil {
            rebuildIfReady()
        } else {
            synchronizeMetrics()
        }
        if surface != nil {
            requestImmediateTick()
        }
    }

    func setDisplayVisible(_ visible: Bool) {
        guard isDisplayVisible != visible else {
            surface?.setOcclusion(effectiveSurfaceVisible)
            return
        }

        isDisplayVisible = visible
        surface?.setOcclusion(effectiveSurfaceVisible)

        if canRenderFrame {
            requestImmediateTick()
        } else {
            stopDisplayLink()
        }
    }

    func setApplicationActive(_ active: Bool) {
        guard isApplicationActive != active else {
            // Same state, but not necessarily the same surface: one built
            // between two syncs still wears the occlusion stamped at its
            // birth. Re-stamp — a surface born occluded that never hears
            // otherwise skips every draw and shows as a blank pane.
            surface?.setOcclusion(effectiveSurfaceVisible)
            if active {
                renderImmediately()
            } else {
                stopDisplayLink()
            }
            return
        }

        isApplicationActive = active
        surface?.setOcclusion(effectiveSurfaceVisible)

        if active {
            synchronizeMetrics()
            renderImmediately()
        } else {
            stopDisplayLink()
        }
    }

    // MARK: - Frame Rendering

    func tick(context: DisplayLinkCallbackContext) {
        guard canRenderFrame else {
            releaseDisplayLink()
            return
        }
        guard shouldRenderFrame(at: context.timestamp) else {
            idleFrameCount += 1
            if idleFrameCount >= Self.idleFramesBeforeRelease {
                releaseDisplayLink()
            }
            return
        }
        idleFrameCount = 0
        pendingImmediateTick = false
        lastTickTimestamp = context.timestamp
        TerminalDebugLog.log(.render, "tick")
        controller?.tick()
        surface?.refresh()
        surface?.draw()
        onPostRender?()
    }

    // MARK: - Focus

    func setFocus(_ focused: Bool) {
        requestImmediateTick()
        TerminalDebugLog.log(.lifecycle, "focus=\(focused)")
        surface?.setFocus(focused)
        (delegate as? any TerminalSurfaceFocusDelegate)?
            .terminalDidChangeFocus(focused)
    }

    #if DEBUG
        // Test access to the host-managed resize state. Read-only apart from
        // `pendingRebuild`, which tests set to drive the redemption path
        // without needing a real ghostty surface.
        var testHooks_pendingRebuild: Bool {
            get { pendingRebuild }
            set { pendingRebuild = newValue }
        }

        var testHooks_throttleArmed: Bool { resizeThrottleArmed }
        var testHooks_throttleTrailing: Bool { resizeThrottleTrailing }
        var testHooks_throttleGeneration: Int { resizeThrottleGeneration }
    #endif

    // MARK: - Cleanup

    func freeSurface() {
        TerminalDebugLog.log(.lifecycle, "free surface")
        tearDownSurface(removingBridgeFrom: controller)
    }

    deinit {
        // `@MainActor` classes have a nonisolated deinit by default, but
        // `tearDownSurface` calls methods on other main-actor types (surface,
        // bridge, controller). We rely on deinit running synchronously with
        // exclusive access; assume main-actor isolation so teardown can run
        // inline without crossing isolation.
        MainActor.assumeIsolated {
            tearDownSurface(removingBridgeFrom: controller)
        }
    }

    private func tearDownSurface(removingBridgeFrom controller: TerminalController?) {
        TerminalDebugLog.log(.lifecycle, "tear down surface")
        releaseDisplayLink()
        if let session = configuration.inMemorySession {
            session.clearSurface(ifMatches: surface?.rawValue)
        }
        controller?.removeWakeupObserver(ObjectIdentifier(self))
        bridge.rawSurface = nil
        let hadSurface = surface != nil
        surface?.setFocus(false)
        surface?.free()
        surface = nil
        lastMetrics = nil
        syncedViewSize = nil
        // Retire any armed timer with the surface it was armed for, and
        // clear the gate so the replacement surface sizes immediately
        // instead of being suppressed by the old surface's armed flag.
        resizeThrottleGeneration &+= 1
        resizeThrottleArmed = false
        resizeThrottleTrailing = false
        pendingImmediateTick = true
        lastTickTimestamp = 0
        controller?.remove(bridge)
        if hadSurface {
            (delegate as? any TerminalSurfaceLifecycleDelegate)?
                .terminalDidDetachSurface()
        }
    }

    private func handleCellSizeChange(width: UInt32, height: UInt32) {
        TerminalDebugLog.log(
            .metrics,
            "cell size changed width=\(width) height=\(height)"
        )
        synchronizeMetrics()
        requestImmediateTick()
        onCellSizeDidChange?()
    }

    private func shouldRenderFrame(at _: TimeInterval) -> Bool {
        guard canRenderFrame else {
            return false
        }
        return pendingImmediateTick || lastTickTimestamp == 0
    }

    private func ensureDisplayLink() {
        guard canRenderFrame else {
            releaseDisplayLink()
            return
        }
        idleFrameCount = 0
        guard displayLink == nil else { return }
        let link = DisplayLink(preferredFrameRateRange: Self.displayLinkFrameRateRange)
        link.delegatingObject(self)
        displayLink = link
        TerminalDebugLog.log(.lifecycle, "display link acquired")
    }

    private func releaseDisplayLink() {
        guard displayLink != nil else { return }
        displayLink = nil
        idleFrameCount = 0
        TerminalDebugLog.log(.lifecycle, "display link released")
    }

    private static func monotonicTimestamp() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private var effectiveSurfaceVisible: Bool {
        isDisplayVisible && isApplicationActive
    }

    private var canRenderFrame: Bool {
        effectiveSurfaceVisible && isAttached()
    }

    private var hasValidViewSize: Bool {
        let size = viewSize()
        return size.width > 0 && size.height > 0
    }

    private func renderImmediately() {
        guard canRenderFrame else {
            releaseDisplayLink()
            return
        }

        pendingImmediateTick = true
        let timestamp = Self.monotonicTimestamp()
        tick(
            context: .init(
                duration: 0,
                timestamp: timestamp,
                targetTimestamp: timestamp
            )
        )
        ensureDisplayLink()
    }
}

extension TerminalSurfaceCoordinator: DisplayLinkDelegate {
    // The shared CADisplayLink dispatches synchronously on the main run
    // loop; the protocol just cannot say so.
    nonisolated func synchronization(context: DisplayLinkCallbackContext) {
        MainActor.assumeIsolated {
            tick(context: context)
        }
    }
}
