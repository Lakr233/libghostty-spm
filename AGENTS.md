# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SPM package wrapping Ghostty terminal emulator C library for Apple platforms (macOS 13+, iOS 15+, Mac Catalyst 15+). Four library products:

- **GhosttyKit** — minimal re-export of the libghostty C API (`@_exported import libghostty`)
- **GhosttyTerminal** — Swift wrapper: native views, SwiftUI integration, input handling, display link, host-managed I/O
- **GhosttyTheme** — 485 terminal color themes from iTerm2-Color-Schemes (MIT License, depends on GhosttyTerminal)
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

# Regenerate GhosttyTheme Swift files from iTerm2-Color-Schemes
./Script/generate-themes.sh
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
  ├─ State/            ObservableObject TerminalViewState (SwiftUI state container)
  ├─ Surface/          Metal rendering bridge, display link, surface lifecycle
  └─ View/             SwiftUI TerminalSurfaceView + platform representables

GhosttyTheme (485 terminal color themes)
  ├─ GhosttyThemeDefinition     — theme data model (name, colors, palette)
  ├─ GhosttyThemeCatalog        — static catalog, search, lookup by name
  ├─ +TerminalConfiguration     — bridge to TerminalConfiguration/TerminalTheme, isDark helper
  └─ Themes/                    — auto-generated Swift files (A-Z) from iTerm2-Color-Schemes

ShellCraftKit (~5 files)
  ├─ Definition/       ShellDefinition, SandboxShell, ShellCommand protocol
  └─ Session/          ShellSession + Bridge + Engine
```

Key types: `TerminalViewState` (ObservableObject, SwiftUI entry point), `TerminalSurfaceView` (SwiftUI view), `TerminalView` (platform typealias: UITerminalView / AppTerminalView), `TerminalController`, `InMemoryTerminalSession`, `GhosttyThemeDefinition`, `GhosttyThemeCatalog`.

### Platform Branching

Use `#if canImport(UIKit)` FIRST, then `#else #if canImport(AppKit)` — Catalyst imports both UIKit and AppKit.

### Host-Managed I/O

All example apps run in App Sandbox. Use `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED` for non-PTY I/O. Never disable sandbox or spawn subprocesses.

### iOS Input Architecture (UITextInput)

`UITerminalView` conforms to `UITextInput` (which includes `UIKeyInput`) to receive both software keyboard and hardware keyboard input on iOS/Catalyst. The input chain:

1. **Hardware keys** → `pressesBegan`/`pressesEnded` in `+Keyboard.swift` → builds `ghostty_input_key_s` → `surface.sendKeyEvent()`. Sets `hardwareKeyHandled = true` to suppress the duplicate `insertText`/`deleteBackward` that UIKit would otherwise deliver.
2. **Software keyboard** → UIKit calls `insertText(_:)` / `deleteBackward()` via UIKeyInput. Guarded by `hardwareKeyHandled` flag to avoid double-processing hardware key presses. The text is then re-encoded as a key event (`sendTypedText`), **not** handed to `surface.sendText` — see "Key Path vs Text Path" below.
3. **Input accessory bar** (iOS only, excludes Catalyst) → `TerminalInputAccessoryView` provides a toolbar above the software keyboard with Esc, Tab, arrow keys, modifier keys (Ctrl/Alt/Cmd), symbol keys, and Paste. Modifier keys support **sticky states**: tap to arm (consumed after next key), double-tap to lock (persists until toggled off). Sticky modifier state is tracked by `TerminalStickyModifierState`. Actions are dispatched via `UITerminalView+InputAccessory.swift`. Button colors are configurable via `TerminalInputAccessoryStyle` (regular/active background and foreground), exposed as `UITerminalView.inputAccessoryStyle`.
4. **IME / marked text** → `setMarkedText` / `unmarkText` delegate to `TerminalTextInputHandler`, which calls `surface.preedit()` for inline composition preview. Committed text goes through `insertText`. Sticky modifiers are respected during IME composition.
5. **Text positioning** → `TerminalTextPosition` / `TerminalTextRange` (UITextPosition/UITextRange subclasses) provide minimal cursor geometry. `caretRect`/`firstRect` use `surface.imePoint()` for IME candidate window placement.

Files in `Platform/UIKit/`:

- `UITerminalView.swift` — main view, `canBecomeFirstResponder`, coordinator setup
- `UITerminalView+UITextInput.swift` — full UITextInput conformance (UIKeyInput, marked text, positions, geometry)
- `UITerminalView+Keyboard.swift` — hardware key handling via UIPress, modifier translation
- `UITerminalView+InputAccessory.swift` — input accessory bar integration, key actions, sticky modifier dispatch
- `UITerminalView+Interaction.swift` — touch scrolling, momentum scroll via CADisplayLink, Catalyst pointer/mouse, copy/paste actions
- `UITerminalView+Drop.swift` — drag and drop: files staged to paths, text and links as text (see "Key Path vs Text Path")
- `UITerminalView+Lifecycle.swift` — display scale, sublayer frames, focus, color scheme
- `TerminalInputAccessoryView.swift` — input accessory bar UIView (blur background, scrollable button layout)
- `TerminalInputAccessoryStyle.swift` — configurable button colors for the accessory bar (regular/active background and foreground)
- `TerminalInputBarKey.swift` — enum defining accessory bar key types (esc, tab, arrows, symbols, paste)
- `TerminalStickyModifierState.swift` — modifier key state machine (inactive/armed/locked, double-tap locking)
- `TerminalTextInputHandler@UIKit.swift` — IME state machine (marked text, preedit bridge, sticky modifier support)
- `TerminalTextPosition.swift` — TerminalTextPosition / TerminalTextRange subclasses

The macOS equivalent uses `NSTextInputClient` in `AppTerminalView+NSTextInputClient.swift` with a parallel `TerminalTextInputHandler@AppKit.swift`.

### Key Path vs Text Path (read before touching input)

libghostty has two ways to get characters into a surface, and they are **not**
interchangeable:

| | C API | ghostty core | shell sees |
| --- | --- | --- | --- |
| key path | `ghostty_surface_key` | `keyEvent` → key encoder | keystrokes, per terminal mode (legacy / modifyOtherKeys / Kitty) |
| text path | `ghostty_surface_text` | `textCallback` → `completeClipboardPaste` | **a paste**, wrapped in `ESC[200~ … ESC[201~` when the app enabled bracketed paste (mode 2004) |

The header says it outright: *"Send raw text to the terminal. This is treated
like a paste, so this isn't useful for sending escape sequences. For that,
individual key input should be used."*

**Typing goes on the key path. Only clipboard content goes on the text path.**

Hosts get the same split: `sendKey(_:)` (`Surface/TerminalKeyPress.swift` —
`TerminalKey` mirrors every `ghostty_input_key_e`, `TerminalKeyPress` adds
modifiers and derives `text` / `unshifted_codepoint` from a US-layout table,
and the surface sends press then release) is the key path; `paste(text:)` is the
text path. `send(_:)` / `sendText(_:)` are deprecated names of `paste(text:)`
because hosts read them as "type this" and sent `"ls\r"` through a paste.
`TerminalSurface.sendText` stays the internal primitive under `paste`.

Getting this backwards does not fail loudly — it produces symptoms that look
like rendering or cursor bugs, because the shell is the thing that behaves
differently:

- zsh renders a pasted region using `zle_highlight`'s `paste:standout`, so a
  character typed through the text path sits there **reverse-video** until the
  next edit redraws the line. It reads as a block cursor stuck on the last
  character with the real cursor blinking a cell ahead. `zle_highlight=(paste:none)`
  in the affected session makes it vanish — that is the one-line confirmation
  that a paste, not the renderer, is at fault.
- Return sent as text lands in the edit buffer as a literal newline under
  bracketed paste instead of accepting the line (fixed in `f8c1bde`, which is
  why `insertText("\n")` is special-cased to a synthetic Return key event).
- A host that tries to rewrite the outbound byte stream to add modifiers hits
  the bracketed-paste markers wrapped around every `sendText` call, which is
  why the sticky-modifier state machine is exposed instead
  (`UITerminalView+PublicSticky.swift`).

Neither the AppKit path nor the sample app can catch a regression here:

- AppKit types through `keyDown`, accumulating `insertText` output into the key
  event, so it never touches the text path for typed characters.
- `Example/MobileGhosttyApp` drives a ShellCraftKit simulated shell, which has
  no bracketed paste at all. **Only a real shell over a pty shows the bug**, so
  verify iOS input against one (`zsh` on device), not against the sample app.

Where this lives today, in `Platform/UIKit`:

- `TerminalTextInputHandler@UIKit.swift` → `sendTypedText(_:)` — typing, IME
  commits, dictation, autocorrect replacements. Builds a `ghostty_input_key_s`
  with `keycode = 0xFFFF`, deliberately outside the AppKit virtual-keycode
  table, so ghostty resolves the physical key to `.unidentified` and encodes
  from `text` alone. The legacy encoder writes unmodified printable text
  directly; the Kitty encoder treats an unmapped key carrying UTF-8 as a pure
  text event. Text containing newlines falls back to the text path — whatever
  produced it, a shell must not read those lines as Return presses.
- `UITerminalView+Interaction.swift` → `paste(text:)` / `pasteFromPasteboard()` —
  clipboard only. The override is **load-bearing**: `UIResponder`'s default
  paste for a `UIKeyInput` conformer calls `insertText(_:)`, which would send
  a pasted multi-line command through the key path and run it line by line.
  It performs ghostty's `paste_from_clipboard` binding instead, so every
  paste — edit menu, the accessory bar's Paste button, hardware Cmd+V — is
  one pipeline: `readClipboard` in `TerminalController+Callbacks.swift`
  resolves the pasteboard and completes the request, and paste protection
  can ask (see Clipboard Confirmation) before an unsafe paste lands.
  `canPerformAction` gates it on `TerminalPasteboardContent.hasContent()`.

`readClipboard` reads through `TerminalPasteboardContent.text` on both
platforms, and both apply upstream's `getOpinionatedStringContents` rule
(`text(string:urls:)`, shared and unit-tested): URLs first — a file URL as
its shell-escaped path, any other verbatim — then the string. The order is
load-bearing: a file copied in Finder or Files carries its URL *and* its
display name as the string, and UIKit once took the string first, so a
copied screenshot pasted "Screenshot … AM" instead of a path. The reader has
no side effects, because the same callback serves a program's OSC 52 read.
Image or document data with no path (a screenshot, a file copied out of
Files — what a phone's clipboard holds far more often than a desktop's) is
the host button's business alone: `pasteFromPasteboard` calls
`TerminalPasteboardContent.files`, which stages it through
`TerminalFileStaging` and sends the escaped paths on the text path. Only the
standard clipboard is read or written; selection clipboard traffic
(`copy-on-select`) is dropped so a drag never replaces the user's pasteboard.

Drops (`UITerminalView+Drop.swift`, a `UIDropInteraction`, iOS and Catalyst)
go the same way: files and images are staged and their escaped paths sent on
the text path; a folder, link, or text is sent as text
(`TerminalPasteboardContent.text(string:urls:)` again). A drop never becomes
keystrokes, and paste protection is not consulted for it — a drop is the
user's own act, like the accessory bar's Paste button.

`TerminalFileStaging` (`Platform/Shared`, Foundation-only so `swift test`
covers it on macOS) owns the staged files: `directory` (default
`<tmp>/ghostty-paste`; `TerminalPasteboardContent.fileDirectory` forwards to
it), `staleFileAge` (24 h), the naming (`fileName`, `uniqueURL`), the
world-readable write (`store`, 0644 — the shell may not be the app's user),
and the two cleanups. A staged file belongs to the shell that got its path
and nothing in the library knows when that shell is done, so cleanup is
time-based by default (`prepareDirectory` sweeps stale files before every
paste or drop; `removeStaleFiles()` on demand) and total only on the host's
say-so: `removeAllFiles()` when its last shell ends or the app quits with
its shells.

Synthetic key events (`sendControlByte`, `sendModifiedTextKey`) must carry
`unshifted_codepoint`. The legacy encoder recovers the letter from the keycode,
so shells never notice its absence; the kitty encoder keys `CSI <cp>;<mods>u`
off it and silently drops the press without it — Ctrl+C never reached codex
until it was set.

When adding an input entry point, decide which of the two it is first, and say
so in the code — "it's just text" is the mistake this section exists to prevent.

### iOS Touch and Pointer Input

- A short direct-touch tap (`touchesEnded` in `+Interaction`) is a left click
  first (`sendTapClick`: mouse position, press, release) and a keyboard toggle
  second, in both directions. A mouse-tracking TUI gets the press before the
  keyboard's resize; the shell sees click-to-move at its prompt.
- Three pan recognizers coexist: direct touches scroll with momentum,
  indirect-pointer drags select (`handleIndirectPointerSelectionGesture`), and
  wheel/trackpad scroll events drive `handleScrollWheelGesture` on iOS and
  Catalyst alike. `TerminalScrollWheelGestureRecognizer` accepts scroll events
  only (`allowedScrollTypesMask` plus `shouldReceive(_:)`): a scroll event is
  neither a touch nor a pointer drag, so without it a mouse scrolls nothing
  on iOS, and with it a finger or a pointer drag never lands on it.

### Clipboard Confirmation

Ghostty asks the host before a protected clipboard operation: an OSC 52 read
(`clipboard-read = ask`, the default), an OSC 52 write when
`clipboard-write = ask`, and a paste that paste protection flagged (newlines
into a program without bracketed paste). `TerminalViewState` conforms to
`TerminalSurfaceClipboardConfirmationDelegate` and forwards to
`onClipboardConfirmationRequest`; while that hook is `nil` a program's read or
write is denied silently and a paste the user started is allowed. A host that
wants programs to read the clipboard, or a say on unsafe pastes, sets it and
presents the request.

### iOS Long-Press Text Selection

Long-press ≥0.5s on `UITerminalView` (single-finger, iOS only — Catalyst excluded) triggers `TerminalSurfaceTextSelectionRequestDelegate.terminalDidRequestTextSelection(_:)`. The host receives a `TerminalTextSelectionRequest` (viewport text snapshot + UTF-16 `NSRange?` for pre-selection + source point) and is expected to present a host UI (e.g. UITextView sheet). Word detection uses `ghostty_surface_quicklook_word` (Apple-only); `TerminalSelectionAnchor.resolveRange` maps the result to an `NSRange` via NSString UTF-16 calculations. Same-row duplicate occurrences are disambiguated by `pointX / cellWidthPoints`; callers must convert `cellPixels / displayScale → points` so ghostty's `tl_px_x/y` host-point units match. Prefix CJK full-width characters can shift cell-vs-UTF-16 columns and degrade disambiguation (ASCII-only correct, best-effort otherwise). The recognizer is gated by `gestureRecognizerShouldBegin` to stay inactive when no host has opted in. MVP supports only the `inMemory` backend.

In iPhone UI tests, synthesize ordinary terminal taps as explicitly short presses and verify `hasKeyboardFocus` before `typeText`; a loaded hosted runner can stretch `tap()` long enough for the selection recognizer to present its sheet. Keep the ordinary XCTest tap and typing path on iPad, where short presses do not reliably publish keyboard focus through accessibility.

### Manifest Sync

When changing SwiftPM products, targets, or test dependencies, update all three together:

- `Package.swift` — production manifest (remote XCFramework URL + checksum)
- `Package.local.swift` — local development (path-based binary target)
- `Package.swift.template` — CI template with `__DOWNLOAD_URL__` / `__CHECKSUM__` placeholders

### Release Versioning

Two release tracks, decoupled since 1.4.0:

- **`upstream.<X.Y.Z>` tags own the XCFramework.** `X.Y.Z` is the upstream
  Ghostty *release* version: `Ghostty.version` names it, `Ghostty.ref` pins
  its tag's exact commit sha, and the "Build Upstream XCFramework" workflow
  (build.yml, dispatch-only) verifies they agree, builds all targets with
  Zig, and publishes `GhosttyKit.xcframework.zip` on the `upstream.<X.Y.Z>`
  release. Patches in `Patches/ghostty/` target that release, not upstream
  main. When bumping, keep build.yml's Zig version in sync with the pinned
  upstream's `minimum_zig_version` (build.zig.zon).
- **Bare semver tags (1.4.0+) are Swift package releases** and follow their
  own sequence, independent of upstream's. The "Release Package" workflow
  (release.yml, dispatch with `package_version`) never runs Zig: it points
  `Package.swift` at the `upstream.<Ghostty.version>` asset, runs the full
  test matrix against it, commits the manifest, and tags. A Swift-only
  change releases in minutes.
- `storage.<package-version>` is the pre-1.4.0 legacy layout; those
  releases were built from upstream *main* snapshots (e.g. storage.1.3.2 ←
  ghostty commit 35e1a016, 2026-07), not from the similarly numbered
  upstream tags.
- Before deleting a storage or upstream release, repoint every live manifest that references it to an available compatible asset; otherwise package resolution fails before any build starts.
- Do not publish arm64e slices until the Zig compiler supports Apple's complete arm64e pointer-authentication ABI; never synthesize an architecture by rewriting Mach-O metadata or patching selected ABI boundaries.

## Swift Code Style

- **Per-concern view state structs**: the platform views (`UITerminalView` /
  `AppTerminalView`) keep no loose stored properties. Each concern's mutable
  state is a struct defined in the `+Xxx` extension file that owns the
  behavior (`SoftwareKeyboardState` in `+Keyboard`, `PointerInteractionState`
  in `+Interaction`, `FocusBridgeState` in `+Lifecycle`, …); the root class
  declares only `var xxx: XxxState = .init()` lines — the storage must live
  in the class because extensions cannot add stored properties. Lazy objects
  that need `self` stay in the class; constants are `static let`s in the
  extension that uses them; anything derivable from other state is a computed
  var, never stored.
- **4-space indentation**, opening brace on same line
- PascalCase types, camelCase properties/methods
- PascalCase files for types, `+` for extensions (e.g., `AppTerminalView+Input.swift`)
- **ObservableObject/@Published** for SwiftUI state that must support iOS 15 / Mac Catalyst 15
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
