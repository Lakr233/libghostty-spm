# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SPM package wrapping Ghostty terminal emulator C library for Apple platforms (macOS 13+, iOS 16+, Mac Catalyst 16+). Three library products:

- **GhosttyKit** — minimal re-export of the libghostty C API (`@_exported import libghostty`)
- **GhosttyTerminal** — Swift wrapper: native views, SwiftUI integration, input handling, display link, host-managed I/O
- **ShellCraftKit** — sandboxed shell emulation framework (depends on GhosttyTerminal)

Binary target: pre-built `libghostty` XCFramework. Dependency: MSDisplayLink ^2.1.0.

## Build & Test Commands

```bash
# Build the SPM package
swift build

# Run tests
swift test

# Multi-destination build verification (macOS, iOS, iOS Simulator, Mac Catalyst)
./Script/test.sh

# Build full XCFramework from Ghostty source (requires zig)
./build.sh
./build.sh --platforms macos,ios --source /path/to/ghostty --skip-tests

# Generate Package.swift for release
./Script/build-manifest.sh
```

## Architecture

```
GhosttyKit (C API re-export)
  └─ libghostty.a (Zig → static lib) + ghostty.h

GhosttyTerminal (Swift wrapper, ~40 files)
  ├─ Configuration/    Config structs, themes, color schemes, ghostty.conf rendering
  ├─ Controller/       TerminalController — app lifecycle, config, surface creation
  ├─ InMemory/         Sandbox-safe I/O backend (no PTY), C callback bridge
  ├─ Metrics/          Grid size, viewport dimensions, input/scroll modifiers
  ├─ Platform/AppKit/  macOS NSView: input, IME, key events
  ├─ Platform/UIKit/   iOS UIView: UITextInput, keyboard, touch/gesture, IME, input accessory bar
  ├─ State/            @Observable TerminalViewState (SwiftUI state container)
  ├─ Surface/          Metal rendering bridge, display link, surface lifecycle
  └─ View/             SwiftUI TerminalSurfaceView + platform representables

ShellCraftKit (~5 files)
  ├─ Definition/       ShellDefinition, SandboxShell, ShellCommand protocol
  └─ Session/          ShellSession + Bridge + Engine
```

Key types: `TerminalViewState` (@Observable, SwiftUI entry point), `TerminalSurfaceView` (SwiftUI view), `TerminalView` (platform typealias: UITerminalView / AppTerminalView), `TerminalController`, `InMemoryTerminalSession`.

### Platform Branching

Use `#if canImport(UIKit)` FIRST, then `#else #if canImport(AppKit)` — Catalyst imports both UIKit and AppKit.

### Host-Managed I/O

All example apps run in App Sandbox. Use `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED` for non-PTY I/O. Never disable sandbox or spawn subprocesses.

### iOS Input Architecture (UITextInput)

`UITerminalView` conforms to `UITextInput` (which includes `UIKeyInput`) to receive both software keyboard and hardware keyboard input on iOS/Catalyst. The input chain:

1. **Hardware keys** → `pressesBegan`/`pressesEnded` in `+Keyboard.swift` → builds `ghostty_input_key_s` → `surface.sendKeyEvent()`. Sets `hardwareKeyHandled = true` to suppress the duplicate `insertText`/`deleteBackward` that UIKit would otherwise deliver.
2. **Software keyboard** → UIKit calls `insertText(_:)` / `deleteBackward()` via UIKeyInput. Guarded by `hardwareKeyHandled` flag to avoid double-processing hardware key presses.
3. **Input accessory bar** (iOS only, excludes Catalyst) → `TerminalInputAccessoryView` provides a toolbar above the software keyboard with Esc, Tab, arrow keys, modifier keys (Ctrl/Alt/Cmd), symbol keys, and Paste. Modifier keys support **sticky states**: tap to arm (consumed after next key), double-tap to lock (persists until toggled off). Sticky modifier state is tracked by `TerminalStickyModifierState`. Actions are dispatched via `UITerminalView+InputAccessory.swift`.
4. **IME / marked text** → `setMarkedText` / `unmarkText` delegate to `TerminalTextInputHandler`, which calls `surface.preedit()` for inline composition preview. Committed text goes through `insertText`. Sticky modifiers are respected during IME composition.
5. **Text positioning** → `TerminalTextPosition` / `TerminalTextRange` (UITextPosition/UITextRange subclasses) provide minimal cursor geometry. `caretRect`/`firstRect` use `surface.imePoint()` for IME candidate window placement.

Files in `Platform/UIKit/`:

- `UITerminalView.swift` — main view, `canBecomeFirstResponder`, coordinator setup
- `UITerminalView+UITextInput.swift` — full UITextInput conformance (UIKeyInput, marked text, positions, geometry)
- `UITerminalView+Keyboard.swift` — hardware key handling via UIPress, modifier translation
- `UITerminalView+InputAccessory.swift` — input accessory bar integration, key actions, sticky modifier dispatch
- `UITerminalView+Interaction.swift` — touch scrolling, momentum scroll via CADisplayLink, Catalyst pointer/mouse
- `UITerminalView+Lifecycle.swift` — display scale, sublayer frames, focus, color scheme
- `TerminalInputAccessoryView.swift` — input accessory bar UIView (blur background, scrollable button layout)
- `TerminalInputBarKey.swift` — enum defining accessory bar key types (esc, tab, arrows, symbols, paste)
- `TerminalStickyModifierState.swift` — modifier key state machine (inactive/armed/locked, double-tap locking)
- `TerminalTextInputHandler@UIKit.swift` — IME state machine (marked text, preedit bridge, sticky modifier support)
- `TerminalTextPosition.swift` — TerminalTextPosition / TerminalTextRange subclasses

The macOS equivalent uses `NSTextInputClient` in `AppTerminalView+NSTextInputClient.swift` with a parallel `TerminalTextInputHandler@AppKit.swift`.

### Manifest Sync

When changing SwiftPM products, targets, or test dependencies, update all three together:

- `Package.swift` — production manifest (remote XCFramework URL + checksum)
- `Package.local.swift` — local development (path-based binary target)
- `Package.swift.template` — CI template with `__DOWNLOAD_URL__` / `__CHECKSUM__` placeholders

## Swift Code Style

- **4-space indentation**, opening brace on same line
- PascalCase types, camelCase properties/methods
- PascalCase files for types, `+` for extensions (e.g., `AppTerminalView+Input.swift`)
- **@Observable macro** over ObservableObject/@Published
- **Swift concurrency**: async/await, Task, actor, @MainActor
- Early returns, guard statements, single responsibility per type/extension
- Value types over reference types, composition over inheritance
- Dependency injection over singletons
- Avoid protocol-oriented design unless necessary
- Split files frequently — keep files small and focused (~40-100 lines typical)
- Don't extract methods unnecessarily — avoid premature abstraction

## Shell Script Style

- Shebang: `#!/bin/zsh`, failure handling: `set -euo pipefail`
- Output: `[+]` success, `[-]` failure, lowercase messages
- Minimal comments, no color output, assume tools available
- Don't add if-checks when pipefail handles failures

## GhosttyKit Design Requirements

### Wrapper Design

- GhosttyTerminal must expose **all** functionality from `ghostty.h`
- Clean Swift APIs mapping to C API: config, app lifecycle, surfaces, input, clipboard, inspector, splits, mouse, IME, text selection
- Proper Swift patterns: enums for C enums, structs for C structs, closures for callbacks

### Example App Requirements

- Apps run in **App Sandbox** — must NOT spawn subprocesses (non-negotiable)
- Use mock terminal IO with real GhosttyTerminal surface/view layer
- Use host-managed I/O backend, never disable sandbox for PTY workarounds
- Keep echo terminal as self-contained module separate from GhosttyKit integration
