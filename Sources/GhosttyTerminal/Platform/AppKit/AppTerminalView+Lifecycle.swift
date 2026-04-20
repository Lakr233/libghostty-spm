//
//  AppTerminalView+Lifecycle.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    public extension AppTerminalView {
        internal func resolvedDisplayScale() -> CGFloat {
            CGFloat(core.scaleFactor())
        }

        internal func setupTrackingArea() {
            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ]
            let area = NSTrackingArea(
                rect: bounds,
                options: options,
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            setupTrackingArea()
        }

        override var acceptsFirstResponder: Bool {
            true
        }

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            core.setFocus(true)
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            core.setFocus(false)
            return result
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                synchronizeViewGeometry()
                core.rebuildIfReady()
                updateColorScheme()
                core.startDisplayLink()
                scheduleSurfaceRefresh(reason: "viewDidMoveToWindow")

                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidBecomeKey),
                    name: NSWindow.didBecomeKeyNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidResignKey),
                    name: NSWindow.didResignKeyNotification,
                    object: window
                )
            } else {
                pendingRefreshWorkItem?.cancel()
                pendingRefreshWorkItem = nil
                core.stopDisplayLink()
                core.freeSurface()
                NotificationCenter.default.removeObserver(self)
            }
        }

        @objc internal func windowDidBecomeKey(_: Notification) {
            let focused = window?.isKeyWindow == true
                && window?.firstResponder === self
            core.setFocus(focused)
        }

        @objc internal func windowDidResignKey(_: Notification) {
            core.setFocus(false)
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            synchronizeViewGeometry()
            core.synchronizeMetrics()
            scheduleSurfaceRefresh(reason: "setFrameSize")
        }

        override func layout() {
            super.layout()
            synchronizeViewGeometry()
            core.synchronizeMetrics()
            scheduleSurfaceRefresh(reason: "layout")
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            synchronizeViewGeometry()
            core.synchronizeMetrics()
            scheduleSurfaceRefresh(reason: "viewDidChangeBackingProperties")
        }

        func fitToSize() {
            core.fitToSize()
        }

        @discardableResult
        func reconcileGeometryNow() -> Bool {
            synchronizeViewGeometry()
            core.synchronizeMetrics()
            return true
        }

        func refreshSurfaceNow(reason: String = "unspecified") {
            layoutSubtreeIfNeeded()
            displayIfNeeded()
            synchronizeViewGeometry()
            core.forceRefresh(reason: reason)
        }

        internal func scheduleSurfaceRefresh(reason: String) {
            pendingRefreshWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, window != nil else { return }
                self.pendingRefreshWorkItem = nil
                self.refreshSurfaceNow(reason: reason)
            }
            pendingRefreshWorkItem = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        internal func synchronizeViewGeometry() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = resolvedDisplayScale()
            wantsLayer = true
            layer?.frame = bounds
            layer?.contentsScale = scale
            layer?.masksToBounds = true
            updateSublayerFrames()
            updateMetalLayerMetrics()
        }

        internal func updateMetalLayerMetrics() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = core.scaleFactor()
            metalLayer?.contentsScale = scale
            metalLayer?.frame = bounds
            metalLayer?.drawableSize = CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )
        }

        internal func updateSublayerFrames() {
            guard let layer else { return }
            let scale = resolvedDisplayScale()
            updateSublayerFrames(of: layer, in: bounds, scale: scale, isRoot: true)
        }

        private func updateSublayerFrames(
            of layer: CALayer,
            in bounds: CGRect,
            scale: CGFloat,
            isRoot: Bool = false
        ) {
            if !isRoot, layer.frame != bounds {
                layer.frame = bounds
            }
            if layer.contentsScale != scale {
                layer.contentsScale = scale
            }
            layer.masksToBounds = true

            if let metalLayer = layer as? CAMetalLayer {
                metalLayer.frame = bounds
                let drawableSize = CGSize(
                    width: max(1, floor(bounds.width * scale)),
                    height: max(1, floor(bounds.height * scale))
                )
                if metalLayer.drawableSize != drawableSize {
                    metalLayer.drawableSize = drawableSize
                }
            }

            for sublayer in layer.sublayers ?? [] {
                updateSublayerFrames(of: sublayer, in: bounds, scale: scale)
            }
        }

        internal func enforceMetalLayerScale() {
            guard let metalLayer else { return }
            let scale = core.scaleFactor()
            if metalLayer.contentsScale != scale {
                metalLayer.contentsScale = scale
            }
            if metalLayer.frame != bounds {
                metalLayer.frame = bounds
            }
            enforceSublayerScale()
        }

        internal func enforceSublayerScale() {
            guard let layer else { return }
            let scale = resolvedDisplayScale()
            updateSublayerFrames(of: layer, in: bounds, scale: scale, isRoot: true)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColorScheme()
        }

        internal func updateColorScheme() {
            let scheme: TerminalColorScheme = switch effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua: .dark
            default: .light
            }
            surface?.setColorScheme(scheme.ghosttyValue)
            controller?.setColorScheme(scheme)
        }
    }
#endif
