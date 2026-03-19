//
//  TerminalSurface.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

/// Thread-safe wrapper around `ghostty_surface_t`.
///
/// All access must happen on the main actor. The surface should be freed
/// explicitly via ``free()`` before the wrapper is deallocated; `deinit`
/// includes a safety net but relying on it is discouraged.
@MainActor
public final class TerminalSurface {
    private var surface: ghostty_surface_t?
    private var hasBeenFreed = false

    init(_ surface: ghostty_surface_t) {
        self.surface = surface
    }

    var rawValue: ghostty_surface_t? {
        surface
    }

    // MARK: - Input

    @discardableResult
    func sendKeyEvent(_ event: ghostty_input_key_s) -> Bool {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface key ignored: missing surface")
            return false
        }
        let result = ghostty_surface_key(s, event)
        TerminalDebugLog.log(
            .input,
            "surface key action=\(TerminalDebugLog.describe(event.action)) keycode=\(event.keycode) mods=0x\(String(event.mods.rawValue, radix: 16)) consumed=0x\(String(event.consumed_mods.rawValue, radix: 16)) text=\(terminalKeyText(event)) composing=\(event.composing) result=\(result)"
        )
        return result
    }

    func sendText(_ text: String) {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface text ignored: missing surface")
            return
        }
        TerminalDebugLog.log(
            .input,
            "surface text=\(TerminalDebugLog.describe(text))"
        )
        text.withCString { cStr in
            ghostty_surface_text(s, cStr, UInt(text.utf8.count))
        }
    }

    @discardableResult
    func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        mods: ghostty_input_mods_e
    ) -> Bool {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface mouse button ignored: missing surface")
            return false
        }
        let result = ghostty_surface_mouse_button(s, state, button, mods)
        TerminalDebugLog.log(
            .input,
            "surface mouseButton state=\(TerminalDebugLog.describe(state)) button=\(button.rawValue) mods=0x\(String(mods.rawValue, radix: 16)) result=\(result)"
        )
        return result
    }

    func sendMousePos(x: Double, y: Double, mods: ghostty_input_mods_e) {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface mouse position ignored: missing surface")
            return
        }
        TerminalDebugLog.log(
            .input,
            "surface mousePos x=\(String(format: "%.2f", x)) y=\(String(format: "%.2f", y)) mods=0x\(String(mods.rawValue, radix: 16))"
        )
        ghostty_surface_mouse_pos(s, x, y, mods)
    }

    func sendMouseScroll(x: Double, y: Double, mods: ghostty_input_scroll_mods_t) {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface scroll ignored: missing surface")
            return
        }
        TerminalDebugLog.log(
            .input,
            "surface scroll x=\(String(format: "%.2f", x)) y=\(String(format: "%.2f", y)) mods=0x\(String(mods, radix: 16))"
        )
        ghostty_surface_mouse_scroll(s, x, y, mods)
    }

    func preedit(_ text: String) {
        guard let s = surface else {
            TerminalDebugLog.log(.ime, "surface preedit ignored: missing surface")
            return
        }
        TerminalDebugLog.log(.ime, "surface preedit=\(TerminalDebugLog.describe(text))")
        text.withCString { cStr in
            ghostty_surface_preedit(s, cStr, UInt(text.utf8.count))
        }
    }

    // MARK: - Actions

    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        guard let s = surface else {
            TerminalDebugLog.log(.actions, "binding action ignored: missing surface")
            return false
        }
        let result = action.withCString { cStr in
            ghostty_surface_binding_action(s, cStr, UInt(action.utf8.count))
        }
        TerminalDebugLog.log(
            .actions,
            "binding action=\(TerminalDebugLog.describe(action)) result=\(result)"
        )
        return result
    }

    // MARK: - Rendering

    func draw() {
        guard let s = surface else { return }
        TerminalDebugLog.log(.render, "surface draw")
        ghostty_surface_draw(s)
    }

    func refresh() {
        guard let s = surface else { return }
        TerminalDebugLog.log(.render, "surface refresh")
        ghostty_surface_refresh(s)
    }

    func setSize(width: UInt32, height: UInt32) {
        guard let s = surface else {
            TerminalDebugLog.log(.metrics, "surface setSize ignored: missing surface")
            return
        }
        TerminalDebugLog.log(.metrics, "surface setSize \(width)x\(height)")
        ghostty_surface_set_size(s, width, height)
    }

    func setContentScale(x: Double, y: Double) {
        guard let s = surface else {
            TerminalDebugLog.log(.metrics, "surface contentScale ignored: missing surface")
            return
        }
        TerminalDebugLog.log(
            .metrics,
            "surface contentScale x=\(String(format: "%.2f", x)) y=\(String(format: "%.2f", y))"
        )
        ghostty_surface_set_content_scale(s, x, y)
    }

    // MARK: - State

    func setFocus(_ focused: Bool) {
        guard let s = surface else { return }
        TerminalDebugLog.log(.lifecycle, "surface focus=\(focused)")
        ghostty_surface_set_focus(s, focused)
    }

    func setColorScheme(_ scheme: ghostty_color_scheme_e) {
        guard let s = surface else { return }
        TerminalDebugLog.log(.lifecycle, "surface colorScheme=\(scheme.rawValue)")
        ghostty_surface_set_color_scheme(s, scheme)
    }

    func setOcclusion(_ visible: Bool) {
        guard let s = surface else { return }
        TerminalDebugLog.log(.lifecycle, "surface occlusion visible=\(visible)")
        ghostty_surface_set_occlusion(s, visible)
    }

    // MARK: - Size Query

    func size() -> TerminalGridMetrics? {
        guard let s = surface else {
            TerminalDebugLog.log(.metrics, "surface size query ignored: missing surface")
            return nil
        }
        let metrics = TerminalGridMetrics(ghostty_surface_size(s))
        TerminalDebugLog.log(.metrics, "surface size \(metrics.debugSummary)")
        return metrics
    }

    // MARK: - IME

    func imePoint() -> (x: Double, y: Double, width: Double, height: Double) {
        var x: Double = 0
        var y: Double = 0
        var w: Double = 0
        var h: Double = 0
        if let s = surface {
            ghostty_surface_ime_point(s, &x, &y, &w, &h)
        }
        TerminalDebugLog.log(
            .ime,
            "surface imePoint x=\(String(format: "%.2f", x)) y=\(String(format: "%.2f", y)) width=\(String(format: "%.2f", w)) height=\(String(format: "%.2f", h))"
        )
        return (x, y, w, h)
    }

    // MARK: - Mouse Capture

    var isMouseCaptured: Bool {
        guard let s = surface else { return false }
        return ghostty_surface_mouse_captured(s)
    }

    // MARK: - Lifecycle

    func free() {
        guard !hasBeenFreed, let s = surface else { return }
        TerminalDebugLog.log(.lifecycle, "surface free")
        hasBeenFreed = true
        surface = nil
        ghostty_surface_free(s)
    }

    deinit {
        // Surface should be freed explicitly via free() before deinit.
        // The deinit safety net is intentionally removed because
        // Swift 6 strict concurrency prevents accessing @MainActor
        // state from nonisolated deinit.
    }
}

private func terminalKeyText(_ event: ghostty_input_key_s) -> String {
    guard let text = event.text else { return "nil" }
    return TerminalDebugLog.describe(String(cString: text))
}
