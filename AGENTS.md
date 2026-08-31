# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SPM package wrapping Ghostty terminal emulator C library for Apple platforms (macOS 13+, iOS 15+, Mac Catalyst 15+, visionOS 1+). Four library products:

- **GhosttyKit** — minimal re-export of the libghostty C API (`@_exported import libghostty`)
- **GhosttyTerminal** — Swift wrapper: native views, SwiftUI integration, input handling, display link, host-managed I/O
- **GhosttyTheme** — 485 terminal color themes from iTerm2-Color-Schemes (MIT License, depends on GhosttyTerminal)
- **ShellCraftKit** — sandboxed shell emulation framework (depends on GhosttyTerminal)

Binary target: pre-built `libghostty` XCFramework. Dependency: MSDisplayLink ^2.2.0.

## Build & Test Commands

```bash
# Build the SPM package
swift build

# Run tests
swift test

# Multi-destination build verification (macOS, iOS, iOS Simulator, Mac Catalyst,
# and visionOS + visionOS Simulator when the host Xcode has the xros SDK)
./Script/test.sh

# Build full XCFramework from Ghostty source (requires zig)
./build.sh
./build.sh --platforms macos,ios --source /path/to/ghostty --skip-tests

# On a Mac with Xcode 27, first: eval "$(./Script/support/xcode27-sdk-overlay.sh)"
# (Zig 0.15.2 cannot link its build runner against that macOS SDK otherwise)

# Generate Package.swift from Package.swift.template (release.yml runs this)
./Script/build-manifest.sh <xcframework_zip> <download_url>

# Regenerate GhosttyTheme Swift files from iTerm2-Color-Schemes
./Script/generate-themes.sh
```

## Architecture

```
GhosttyKit (C API re-export)
  └─ libghostty.a (Zig → static lib) + ghostty.h

GhosttyTerminal (Swift wrapper, ~70 files)
  ├─ Configuration/    Config structs, themes, color schemes, ghostty.conf rendering, GhosttyRuntimeResources
  ├─ Controller/       TerminalController — app lifecycle, config, surface creation, C callbacks
  ├─ Debug/            TerminalDebugLog — category-gated logging to a host-settable sink
  ├─ InMemory/         Sandbox-safe I/O backend (no PTY), TerminalSessionBackend, C callback bridge
  ├─ Metrics/          Grid size, viewport dimensions, input/scroll modifiers
  ├─ Platform/AppKit/  macOS NSView: key events, NSTextInputClient IME, CAMetalLayer, public input
  ├─ Platform/Shared/  Pasteboard reading, file staging, shell escaping, key tables, IME state, foreground pid
  ├─ Platform/UIKit/   iOS UIView: UITextInput, keyboard, touch/gesture, drop, pinch zoom, IME, input accessory bar
  ├─ Resources/        Bundled Ghostty shell-integration + terminfo (exec backend)
  ├─ State/            ObservableObject TerminalViewState (SwiftUI state container)
  ├─ Surface/          TerminalSurface, coordinator + display link, SwiftUI TerminalSurfaceView, delegates, TerminalKey/TerminalKeyPress
  └─ View/             TerminalView typealias + platform representables

GhosttyTheme (485 terminal color themes)
  ├─ GhosttyThemeDefinition     — theme data model (name, colors, palette)
  ├─ GhosttyThemeCatalog        — static catalog, search, lookup by name
  ├─ +TerminalConfiguration     — bridge to TerminalConfiguration/TerminalTheme, isDark helper
  └─ Themes/                    — auto-generated Swift files (Themes_A-Z, Themes_Symbols, ThemeCatalog_Generated) from iTerm2-Color-Schemes

ShellCraftKit (6 files)
  ├─ Definition/       ShellDefinition + ShellCommandBuilder, ShellCommand struct, defaultSandboxShell
  └─ Session/          ShellSession + Bridge + Engine
```

Key types: `TerminalViewState` (ObservableObject, SwiftUI entry point), `TerminalSurfaceView` (SwiftUI view), `TerminalView` (platform typealias: UITerminalView / AppTerminalView), `TerminalController`, `TerminalSurfaceOptions` / `TerminalSessionBackend`, `InMemoryTerminalSession`, `TerminalKey` / `TerminalKeyPress` (key path for hosts), `TerminalPasteboardContent` / `TerminalFileStaging` (clipboard and drop payloads), `GhosttyThemeDefinition`, `GhosttyThemeCatalog`.

### Platform Branching

**The order is the rule: `canImport(UIKit)` is always asked first.** Mac
Catalyst imports UIKit *and* AppKit, so a chain that leads with AppKit sends
Catalyst down the AppKit branch. Write guards in exactly these shapes:

```swift
// Both platforms have code.
#if canImport(UIKit)
    ...
#elseif canImport(AppKit)
    ...
#endif

// UIKit only, with a Catalyst exclusion. `targetEnvironment(...)` is never
// the head of a chain — Catalyst is a UIKit platform, so it is only ever a
// nested check inside the UIKit branch.
#if canImport(UIKit)
    #if !targetEnvironment(macCatalyst)
        ...
    #endif
#endif

// AppKit only. When the UIKit branch would be empty, invert instead of
// leaving it there.
#if !canImport(UIKit) && canImport(AppKit)
    ...
#endif

// visionOS is a UIKit platform with a few APIs missing (`UIScreen`,
// `inputAccessoryView`, `UIImpactFeedbackGenerator`, `UIGlassEffect`,
// `inputAssistantItem`). Like `targetEnvironment`, `os(visionOS)` is only
// ever a nested check inside the UIKit branch, wrapped tightly around the
// one call that does not exist there — never a whole-file fork.
#if canImport(UIKit)
    #if !os(visionOS)
        ...
    #endif
#endif
```

Two omissions keep the noise down:

- An **empty branch is omitted**, never written out. An empty
  `#elseif canImport(AppKit)` is dropped; an empty leading UIKit branch
  becomes `#if !canImport(UIKit) && canImport(AppKit)`.
- **No file carries an `#else` / `#error` arm.** The unsupported-platform
  assertion lives once, in `Platform/PlatformSupport.swift`, and every other
  file simply compiles to nothing there.

Swift spells the middle branch **`#elseif`**. C's `#elif` parses as an
expression and fails with "consecutive statements on a line must be separated
by ';'" pointing at the directive — an entire guard sweep once shipped broken
that way, so grep for it before pushing.

### Host-Managed I/O

All example apps run in App Sandbox. Use `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED` for non-PTY I/O: `TerminalSurfaceOptions.backend = .inMemory(session)` selects it (`TerminalController+Surface.swift`); the default `.exec` is a PTY and needs the bundled `Resources/` (`GhosttyRuntimeResources`). Never disable sandbox or spawn subprocesses.

### iOS Input Architecture (UITextInput)

`UITerminalView` conforms to `UITextInput` (which includes `UIKeyInput`) to receive both software keyboard and hardware keyboard input on iOS/Catalyst. The input chain:

1. **Hardware keys** → `pressesBegan`/`pressesEnded` in `+Keyboard.swift` → `handleKeyPress` builds `ghostty_input_key_s` (HID usage translated to an AppKit keycode by `TerminalHardwareKeyRouter.appKitKeyCodeForUIKit`) → `surface.sendKeyEvent()`. Sets `hardwareKeyboard.keyHandled = true` (`HardwareKeyboardState`) to suppress the duplicate `insertText`/`deleteBackward` that UIKit would otherwise deliver. Ctrl combos never reach `pressesBegan` — the text-input system consumes them first, on iPadOS and Catalyst alike — so `keyCommands` registers a `UIKeyCommand` for every Ctrl+letter/digit/symbol with `wantsPriorityOverSystemBehavior`; `handleControlKeyCommand` sends it as a `TerminalKeyPress` on the key path, and `claimKeyCommandDelivery` dedupes per runloop turn against systems that deliver both the command and the press. Escape takes the same route for a different reason, on iPadOS and Catalyst alike: UIKit's system behaviour for a hardware Escape on a `UITextInput` first responder ends editing — the view resigns, the keyboard drops on iOS, and on Catalyst every later key goes nowhere until the next click — so `escapeKeyCommands` claims it under every non-Cmd modifier set and `handleEscapeKeyCommand` sends `.escape` to the surface; the commands are withheld while text is marked, since then the key is the input method's (it cancels the composition). On iOS (not Catalyst) a printable press under a composing input mode (`TerminalIMEComposition.shouldDeferKey`) is loaned to the input method as a `DeferredInputMethodKey`; any UITextInput mutation claims it (`claimPendingInputMethodKeys`), and an unclaimed one is forwarded to `super` or replayed to the surface.
2. **Software keyboard** → UIKit calls `insertText(_:)` / `deleteBackward()` via UIKeyInput. `TerminalSoftwareKeyCommitRouter.route` (`Shared/TerminalInputText.swift`) reads the `hardwareKeyboard.keyHandled` flag to drop a hardware duplicate and turns a lone unmarked `"\n"`/`"\r"` into a synthetic Return key event (`sendSyntheticKey(usage: 0x28)` on iOS, `sendReturnKey()` on Catalyst). Other text is re-encoded as a key event (`sendTypedText`), **not** handed to `surface.sendText` — see "Key Path vs Text Path" below.
3. **Input accessory bar** (iOS only, excludes Catalyst) → `TerminalInputAccessoryView` provides a toolbar above the software keyboard with Esc, Tab, arrow keys, modifier keys (Ctrl/Alt/Cmd), symbol keys, and Paste. The layout is `UITerminalView.inputAccessoryItems: [TerminalInputAccessoryItem]` (`defaultItems`; an empty array removes the bar). Modifier keys support **sticky states**: tap to arm (consumed after next key), double-tap to lock (persists until toggled off). Sticky modifier state is tracked by `TerminalStickyModifierState`; `+PublicSticky.swift` exposes it (`toggleStickyModifier`, `stickyActivation(for:)`, `resetStickyModifiers`, `setStickyModifierChangeHandler`) for hosts that draw their own bar. Actions are dispatched via `UITerminalView+InputAccessory.swift` (`handleInputBarKey`: keys go through `sendSyntheticKey`, symbols through `handleStickyTextInput`, Paste through `pasteFromPasteboard`). Button colors are configurable via `TerminalInputAccessoryStyle` (regular/active background and foreground), exposed as `UITerminalView.inputAccessoryStyle`. A clean direct-touch tap sends its click, then calls `toggleSoftwareKeyboard()` — an `open func` declared in the class body (not an extension) precisely so a host's `makePlatformView` subclass can override it; a keyboard lock overrides it to do nothing, and the tap's click still lands on the program.
4. **IME / marked text** → `setMarkedText` / `unmarkText` delegate to `TerminalTextInputHandler`, which keeps the composition in a `TerminalMarkedTextState` and calls `surface.preedit()` for inline composition preview. Committed text goes through `insertText`. Sticky modifiers are respected during IME composition (`handleStickyMarkedText` / `handleStickyCommittedText`).
5. **Text positioning** → `TerminalTextPosition` / `TerminalTextRange` (UITextPosition/UITextRange subclasses) provide minimal cursor geometry. `caretRect`/`firstRect` use `surface.imePoint()` for IME candidate window placement.

Hosts drive the same paths through `+PublicInput.swift`: `sendKey(_:)` (commits an open composition, applies armed sticky modifiers), `paste(text:)`, `acquireProgrammaticFocus()`, `performBindingAction`, `jumpToPrompt(by:)`, `scrollToRow`.

Files in `Platform/UIKit/`:

- `UITerminalView.swift` — main view, `canBecomeFirstResponder`, coordinator setup, per-concern state storage, `setSurfaceVisible`, selection copy menu (context menu / edit menu), keyboard show/hide observers
- `UITerminalView+UITextInput.swift` — full UITextInput conformance (UIKeyInput, marked text, positions, geometry), `TextInputBridgeState`
- `UITerminalView+Keyboard.swift` — hardware key handling via UIPress, Ctrl `UIKeyCommand`s, input-method key deferral, modifier translation; `HardwareKeyboardState`, `SoftwareKeyboardState`
- `UITerminalView+InputAccessory.swift` — input accessory bar integration (iOS only), key actions, sticky modifier dispatch, `sendSyntheticKey` / `sendControlByte` / `sendModifiedTextKey`
- `UITerminalView+Interaction.swift` — tap-to-click and keyboard toggle, touch scrolling, momentum scroll via CADisplayLink, scroll-wheel recognizer, indirect-pointer selection, long-press selection, copy/paste actions; `PointerInteractionState`, `MomentumScrollState`
- `UITerminalView+Drop.swift` — drag and drop: files staged to paths, text and links as text (see "Key Path vs Text Path")
- `UITerminalView+PinchZoom.swift` — pinch changes font size via `increase_font_size` / `decrease_font_size` bindings (iOS only); `FontZoomState`
- `UITerminalView+PublicInput.swift` — public `acquireProgrammaticFocus`, `paste(text:)`, `sendKey`, `performBindingAction`, `jumpToPrompt(by:)`, `scrollToRow`
- `UITerminalView+PublicSticky.swift` — public sticky-modifier API (`TerminalPublicStickyModifier` / `TerminalPublicStickyActivation`) for hosts with their own accessory UI (iOS only)
- `UITerminalView+Snapshot.swift` — public `snapshotImage()`: render-server snapshot (`drawHierarchy`) of the surface, Metal layer included; the AppKit twin (`AppTerminalView+Snapshot.swift`, `cacheDisplay`) is best-effort for Metal content. Reached from state via `TerminalViewState.attachedPlatformView`
- `UITerminalView+Lifecycle.swift` — application active/background observers, display scale, sublayer frames (held at `core.syncedViewSize`, not the bounds, while a resize throttle has the surface at an older size — a layer stretched to the new bounds shows the old frame scaled and the engine's derived `contentsScale` fights the post-render correction every tick), focus, color scheme; `FocusBridgeState`
- `TerminalInputAccessoryView.swift` — input accessory bar UIView (blur background, scrollable button layout)
- `TerminalInputAccessoryStyle.swift` — configurable button colors for the accessory bar (regular/active background and foreground)
- `TerminalInputBarKey.swift` — public `TerminalInputAccessoryItem` (bar layout, `defaultItems`) and internal `TerminalInputBarKey` (esc, tab, arrows, symbols, paste)
- `TerminalStickyModifierState.swift` — modifier key state machine (inactive/armed/locked, double-tap locking)
- `TerminalTextInputHandler@UIKit.swift` — IME state machine (marked text, preedit bridge, sticky modifier support), `sendTypedText`
- `TerminalTextPosition.swift` — TerminalTextPosition / TerminalTextRange subclasses

Files in `Platform/Shared/` (both platforms; the Foundation-only ones have unit tests in `Tests/GhosttyKitTest`):

- `TerminalFileStaging.swift` — staged files for pastes and drops: `directory`, `staleFileAge`, `stage`, `fileType(among:)`, cleanup (see "Key Path vs Text Path")
- `TerminalPasteboardContent.swift` — pasteboard reading: `text(string:urls:)` rule, `hasContent`, `text(from:)`, `fileURLs(in:)` (UIKit reads `public.file-url` items that `hasURLs`/`urls` do not report), `files(from:)`
- `TerminalShellEscape.swift` — backslash-escapes a path for a live prompt
- `TerminalHardwareKeyRouter.swift` — HID usage / AppKit keycode / `ghostty_input_key_e` tables, `unidentifiedAppKitKeyCode`
- `TerminalIMEComposition.swift` — which input modes compose (zh/ja/ko) and whether a hardware key belongs to the input method
- `TerminalInputText.swift` — function-key text filtering, `lineCount`, `TerminalSoftwareKeyCommitRouter`
- `TerminalMarkedTextState.swift` — marked text + selected range struct used by both `TerminalTextInputHandler`s
- `TerminalMainActor.swift` — `terminalRunOnMain` for C callbacks
- `TerminalView+Process.swift` — `foregroundPid` / `ttyName` on `TerminalView`

The macOS equivalent uses `NSTextInputClient` in `AppTerminalView+NSTextInputClient.swift` with a parallel `TerminalTextInputHandler@AppKit.swift`.

### Key Path vs Text Path (read before touching input)

libghostty has two ways to get characters into a surface, and they are **not**
interchangeable:

| | C API | ghostty core | shell sees |
| --- | --- | --- | --- |
| key path | `ghostty_surface_key` | `keyEvent` → `keyCallback` → key encoder | keystrokes, per terminal mode (legacy / modifyOtherKeys / Kitty) |
| text path | `ghostty_surface_text` | `textCallback` → `completeClipboardPaste` | **a paste**, wrapped in `ESC[200~ … ESC[201~` when the app enabled bracketed paste (mode 2004) |

Upstream says it outright, on `ghostty_surface_text` in
`src/apprt/embedded.zig` (the shipped `ghostty.h` documents no functions —
its own header comment points at the Zig sources):
*"Send raw text to the terminal. This is treated like a paste so this isn't
useful for sending escape sequences. For that, individual key input should be
used."*

**Typing goes on the key path. Only a paste — clipboard content, or what a
drop delivers — goes on the text path.**

Hosts get the same split. `sendKey(_:)` is the key path: `TerminalKey`
(`Surface/TerminalKey.swift`) has one case per `ghostty_input_key_e` plus the
US-layout table (`usLayoutCharacters`); `TerminalKeyPress`
(`Surface/TerminalKeyPress.swift`) adds `TerminalInputModifiers` and derives
`text` / `unshiftedCodepoint` from that table; `TerminalSurface.sendKey`
(same file) sends press then release and returns false for a key with no
macOS keycode (`hasPlatformKeycode`). It is re-exposed on `TerminalViewState`
and on both views in `+PublicInput.swift` — the UIKit one commits an open
composition and spends armed sticky modifiers first, the AppKit one commits
the composition. `paste(text:)` on the same three is the text path.
`TerminalViewState.send(_:)` and `AppTerminalView.sendText(_:)` are
deprecated names of `paste(text:)` because hosts read them as "type this" and
sent `"ls\r"` through a paste. `TerminalSurface.sendText` stays the primitive
under `paste`.

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
  why `TerminalSoftwareKeyCommitRouter.route` in `Shared/TerminalInputText.swift`
  turns a lone unmarked `insertText("\n")` / `"\r"` into a synthetic Return
  key event).
- A host that tries to rewrite the outbound byte stream to add modifiers hits
  the bracketed-paste markers wrapped around every `sendText` call, which is
  why the sticky-modifier state machine is exposed instead
  (`UITerminalView+PublicSticky.swift`).

Neither the AppKit path nor the sample app can catch a regression here:

- AppKit types through `keyDown`, accumulating `insertText` output into the key
  event (`startCollectingText` / `finishCollectingText` in
  `TerminalTextInputHandler@AppKit.swift`), so it never touches the text path
  for typed characters; only an `insertText` outside a key event — an IME
  commit from the candidate window — reaches `sendText`.
- `Example/MobileGhosttyApp` drives a ShellCraftKit simulated shell, which has
  no bracketed paste at all. **Only a real shell over a pty shows the bug**, so
  verify iOS input against one (`zsh` on device), not against the sample app.

Where this lives today, in `Platform/UIKit`:

- `TerminalTextInputHandler@UIKit.swift` → `sendTypedText(_:)` — typing, IME
  commits, dictation, autocorrect replacements. Builds a `ghostty_input_key_s`
  with `keycode = 0xFFFF`, deliberately outside the AppKit virtual-keycode
  table, so ghostty resolves the physical key to `.unidentified` and encodes
  from `text` alone (no mods; `unshifted_codepoint` is the text's first
  scalar). The legacy encoder writes unmodified printable text directly; the
  Kitty encoder treats an unmapped key carrying UTF-8 as a pure text event.
  Text containing newlines falls back to the text path — whatever produced
  it, a shell must not read those lines as Return presses.
- `UITerminalView+Interaction.swift` → `paste(_:)` / `pasteFromPasteboard()` —
  clipboard only. The override is **load-bearing**: `UIResponder`'s default
  paste for a `UIKeyInput` conformer calls `insertText(_:)`, which would send
  a pasted multi-line command through the key path and run it line by line.
  It performs ghostty's `paste_from_clipboard` binding instead, so every
  paste — edit menu, the accessory bar's Paste button, hardware Cmd+V — is
  one pipeline: `readClipboard` in `TerminalController+Callbacks.swift`
  resolves the pasteboard and completes the request, and paste protection
  can ask (see Clipboard Confirmation) before an unsafe paste lands.
  `canPerformAction` gates it on `TerminalPasteboardContent.hasContent()`.

`readClipboard` reads through `TerminalPasteboardContent.text()` on both
platforms, and both apply upstream's `getOpinionatedStringContents` rule
(`text(string:urls:)`, shared and unit-tested in
`TerminalPasteboardContentTests`): URLs first — a file URL as its
shell-escaped path, any other verbatim — then the string. The order is
load-bearing: a file copied in Finder or Files carries its URL *and* its
display name as the string, and UIKit once took the string first, so a
copied screenshot pasted "Screenshot … AM" instead of a path. AppKit gets the
URLs from `readObjects(forClasses: [NSURL.self])`. UIKit gets `public.url`
items from `hasURLs` / `urls`, but those do not report `public.file-url`,
which is what a file copied in Finder (Catalyst) or Files lands as — the
reader saw no URL and either pasted the display name or staged a copy of the
file instead of its path — so `fileURLs(in:)` reads that representation off
every item (as `URL`, `Data`, or `String`) whenever the general list holds no
file URL, and `hasContent` asks for the type too. The reader has no side
effects, because the same callback serves a program's OSC 52 read. Image or
document data with no path (a screenshot, a file copied out of Files — what
a phone's clipboard holds far more often than a desktop's) is the host
button's business alone: `pasteFromPasteboard` calls
`TerminalPasteboardContent.files`, which stages it through
`TerminalFileStaging` and sends the escaped paths on the text path. Only the
standard clipboard is read or written; selection clipboard traffic
(`copy-on-select`) is dropped so a drag never replaces the user's pasteboard.

Drops (`UITerminalView+Drop.swift`, a `UIDropInteraction`, iOS and Catalyst)
go the same way: items with a stageable type (`TerminalFileStaging.fileType(among:)`
— images first, then any non-dynamic data that is not text, a link, or a
folder) are staged and their escaped paths sent on the text path; otherwise
the dropped URLs (a folder, a link — `text(string:urls:)` again, so a folder
pastes as its escaped path) or strings are sent as text. A drop never
becomes keystrokes, and paste protection is not consulted for it — a drop is
the user's own act, like the accessory bar's Paste button.

`TerminalFileStaging` (`Platform/Shared`, no UIKit or AppKit dependency so
`swift test` covers it on macOS in `TerminalFileStagingTests`) owns the
staged files: `directory` (default `<tmp>/ghostty-paste`;
`TerminalPasteboardContent.fileDirectory` forwards to it), `staleFileAge`
(24 h), the two writers (`stage(_:completion:)` for item providers,
`stage(data:name:type:completion:)` for raw bytes — both complete on the main
queue with the escaped, space-joined paths), the naming (`fileName`,
`uniqueURL`), the world-readable write (`store`, 0644 — the shell may not be
the app's user), and the two cleanups. A staged file belongs to the shell
that got its path and nothing in the library knows when that shell is done,
so cleanup is time-based by default (`prepareDirectory` creates the
directory 0755 and sweeps stale files before every paste or drop;
`removeStaleFiles()` on demand) and total only on the host's say-so:
`removeAllFiles()` when its last shell ends or the app quits with its shells.

Synthetic key events (`sendControlByte`, `sendModifiedTextKey` in
`UITerminalView+InputAccessory.swift`) must carry `unshifted_codepoint`. The
legacy encoder recovers the letter from the keycode, so shells never notice
its absence; the kitty encoder keys `CSI <cp>;<mods>u` off it and silently
drops the press without it — Ctrl+C never reached codex until it was set.

When adding an input entry point, decide which of the two it is first, and say
so in the code — "it's just text" is the mistake this section exists to prevent.

### iOS Touch and Pointer Input

- A short direct-touch tap (`touchesEnded` in `+Interaction`, iOS only) is a
  left click first (`sendTapClick`: mouse position, press, release) and a
  keyboard toggle second, in both directions. A mouse-tracking TUI gets the
  press before the keyboard's resize; the shell sees click-to-move at its
  prompt. The tap candidate lives in `SoftwareKeyboardState`: armed by a lone
  finger down, disarmed by a second finger, movement past
  `tapCandidateSlop` (10 pt), a recognized pan/pinch/long press, or a press
  longer than `tapCandidateMaxDuration` (0.35 s, below the long-press
  recognizer's 0.5 s so a hold never toggles the keyboard).
- Indirect-pointer touches (`handleIndirectPointerTouches`, iOS and
  Catalyst) are mouse events: a click makes the view first responder and
  sends position and button; a right click inside a selection opens the copy
  menu. On Catalyst `touchesBegan` also calls `becomeFirstResponder`.
- Three pan recognizers coexist: direct touches scroll with momentum
  (`MomentumScrollState`, a `CADisplayLink`), indirect-pointer drags select
  (`handleIndirectPointerSelectionGesture`), and wheel/trackpad scroll
  events drive `handleScrollWheelGesture` on iOS and Catalyst alike.
  `TerminalScrollWheelGestureRecognizer` accepts scroll events only
  (`allowedScrollTypesMask` plus `shouldReceive(_:)`): a scroll event is
  neither a touch nor a pointer drag, so without it a mouse scrolls nothing
  on iOS, and with it a finger or a pointer drag never lands on it.
- A pinch (`+PinchZoom`, iOS only) steps the font size through the
  `increase_font_size:1` / `decrease_font_size:1` bindings, clamped to
  `minFontSize`…`maxFontSize` (4…64); Cmd+`=`/`-` on a hardware keyboard
  moves the same `FontZoomState` counter.

### Clipboard Confirmation

Ghostty asks the host before a protected clipboard operation: an OSC 52 read
(`clipboard-read = ask`, the default), an OSC 52 write when
`clipboard-write = ask`, and a paste that paste protection flagged (newlines
into a program without bracketed paste). `TerminalViewState` conforms to
`TerminalSurfaceClipboardConfirmationDelegate` and forwards to
`onClipboardConfirmationRequest`; while that hook is `nil` a program's read or
write is denied silently and a paste the user started is allowed. A host that
wants programs to read the clipboard, or a say on unsafe pastes, sets it and
presents the request. The request is a `TerminalClipboardConfirmationRequest`
(`contents`, `kind: TerminalClipboardRequestKind` — `.paste`, `.osc52Read`,
`.osc52Write`) answered once with `respond(allow:)`; dropping it unanswered
denies. `TerminalCallbackBridge.handleClipboardConfirmation` denies outright
when the delegate does not adopt the protocol. The C side is the
`confirm_read_clipboard_cb` runtime callback (`TerminalController+Config.swift`
→ `TerminalCallbacks.confirmReadClipboard`) for reads and pastes, and the
write-clipboard callback for `.osc52Write`; tests in
`Tests/GhosttyKitTest/TerminalClipboardConfirmationTests.swift`.

### iOS Long-Press Text Selection

Long-press ≥0.5s on `UITerminalView` (single-finger direct touch, iOS only — Catalyst excluded; `handleLongPressForSelection` in `+Interaction`) triggers `TerminalSurfaceTextSelectionRequestDelegate.terminalDidRequestTextSelection(_:)`. The host receives a `TerminalTextSelectionRequest` (`text`: viewport snapshot, `anchorRange`: UTF-16 `NSRange?` for pre-selection, `sourcePoint`) and is expected to present a host UI (e.g. UITextView sheet). Word detection uses `ghostty_surface_quicklook_word` via `surface.quicklookWord()` (Apple-only); `TerminalSelectionAnchor.resolveRange` (`Surface/`) maps the result to an `NSRange` via NSString UTF-16 calculations. Same-row duplicate occurrences are disambiguated by `pointX / cellWidthPoints`; callers must convert `cellPixels / displayScale → points` so ghostty's `tl_px_x/y` host-point units match. Prefix CJK full-width characters can shift cell-vs-UTF-16 columns and degrade disambiguation (ASCII-only correct, best-effort otherwise). The recognizer is gated by `gestureRecognizerShouldBegin` to stay inactive when no host has opted in: the delegate must adopt the protocol, and for a `TerminalViewState` delegate (which adopts it unconditionally) `onTextSelectionRequest` must be set (`activeTextSelectionDelegate`). Only the `inMemory` backend is supported — the snapshot comes from `InMemoryTerminalSession.readViewportText()`, and any other backend logs and returns.

In iPhone UI tests, synthesize ordinary terminal taps as explicitly short presses and verify `hasKeyboardFocus` before `typeText`; a loaded hosted runner can stretch `tap()` long enough for the selection recognizer to present its sheet. Keep the ordinary XCTest tap and typing path on iPad, where short presses do not reliably publish keyboard focus through accessibility.

### Manifest Sync

When changing SwiftPM products, targets, or test dependencies, update all three together:

- `Package.swift` — production manifest (remote XCFramework URL + checksum)
- `Package.local.swift` — local development (path-based binary target,
  `BinaryTarget/GhosttyKit.xcframework`)
- `Package.swift.template` — CI template with `__DOWNLOAD_URL__` / `__CHECKSUM__` placeholders

`Script/build-manifest.sh <zip> <url>` renders `Package.swift` from the
template (release.yml and `build.sh --download-url` both call it), so an edit
made only to `Package.swift` is lost at the next release. release.yml also
copies `Package.local.swift` over `Package.swift` to run the test matrix, so
the two must describe the same targets.

### Release Versioning

Two release tracks, decoupled since 1.4.0:

- **`upstream.<X.Y.Z>` tags own the XCFramework.** `X.Y.Z` is the upstream
  Ghostty *release* version: `Ghostty.version` names it, `Ghostty.ref` pins
  its tag's exact commit sha, and the "Build Upstream XCFramework" workflow
  (build.yml, dispatch-only) verifies they agree, builds all targets with
  Zig, and publishes `GhosttyKit.xcframework.zip` on the `upstream.<X.Y.Z>`
  release (it exits early if that tag already exists). Both files sit at
  the repo root, one line each. Patches in `Patches/ghostty/` target that
  release, not upstream main; the "Source Build" workflow (source-build.yml)
  rebuilds every target on a PR that touches `Ghostty.ref`, `Patches/`,
  `Script/build-ghostty.sh`, `Script/prepare-zig-lib.sh`, or
  `Script/support/`. When bumping, keep the Zig version pinned in build.yml
  *and* source-build.yml (0.15.2 today) in sync with the pinned upstream's
  `minimum_zig_version` (build.zig.zon) — and re-diff `Patches/zig/` against
  the new std, since `prepare-zig-lib.sh` looks the patch up by exact Zig
  version. **`Ghostty.build`** is the asset revision for one Ghostty
  release: `Script/storage-tag.sh` turns version + build into the storage
  tag (`upstream.1.3.1` for build 1 or no file, `upstream.1.3.1-2` from 2
  on), and both build.yml and release.yml read it from there. Bump it when
  the patch stack or the target set changes without a Ghostty bump —
  build.yml exits early on an existing tag, so nothing else republishes
  the asset. The visionOS slices (xros, xrsimulator) build against a
  patched Zig std (`Patches/zig/`, `Script/prepare-zig-lib.sh` — a copy
  under the build cache exported as `ZIG_LIB_DIR`; the toolchain on PATH
  is never edited).
- **Bare semver tags (1.4.0+) are Swift package releases** and follow their
  own sequence, independent of upstream's. The "Release Package" workflow
  (release.yml, dispatch with `package_version`) never runs Zig: it
  refuses a version that is not newer than the latest semver tag, requires
  the `upstream.<Ghostty.version>` release to exist, renders `Package.swift`
  against its asset, runs `Script/test.sh` and `swift test` through
  `Package.local.swift`, commits the manifest, tags, and runs
  `Script/verify-release.sh <package_tag> <upstream_tag>` to check the
  manifest's URL and checksum against the asset the tag serves. A
  Swift-only change releases in minutes. `Script/tag-release.sh` predates
  this track (it cuts `1.0.<epoch>` tags) and no workflow uses it.
  **Never push a bare semver tag by hand**: nothing but release.yml checks
  a manifest against its asset before tagging, and a hand-pushed tag gets
  no GitHub release (1.4.8, 1.4.9 and 1.4.12 were pushed that way; their
  releases were created after the fact once their manifests had been
  verified). `Script/audit-releases.sh` walks every 1.4.0+ tag and
  reports one with no release, no upstream URL/checksum, or a checksum
  its `upstream.*` asset does not carry — run it after any release
  activity, and before deleting a storage or upstream release.
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
  behavior (UIKit: `HardwareKeyboardState` and `SoftwareKeyboardState` in
  `+Keyboard`, `PointerInteractionState` and `MomentumScrollState` in
  `+Interaction`, `FontZoomState` in `+PinchZoom`, `FocusBridgeState` in
  `+Lifecycle`, `TextInputBridgeState` in `+UITextInput`; AppKit:
  `KeyEchoState` and `PointerSelectionState` in `+Input`, `FocusBridgeState`
  in `+Lifecycle`); the root class declares only `var xxx: XxxState = .init()`
  lines — the storage must live in the class because extensions cannot add
  stored properties. Lazy objects that need `self` (`inputHandler`,
  `terminalInputAccessory`) and reference-type helpers
  (`TerminalStickyModifierState`) stay in the class; constants are
  `static let`s in the extension that uses them; anything derivable from
  other state is a computed var, never stored.
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

- Failure handling: `set -euo pipefail` in every script
- Two shebang/prefix conventions exist, by lineage: the build and release
  pipeline (`build.sh`, `Script/build*.sh`, `merge-xcframework.sh`,
  `test*.sh`, `verify-*.sh`) is `#!/bin/bash` with `[*]` progress and `[!]`
  failure; the repo-maintenance scripts (`apply-patches.sh`,
  `generate-themes.sh`, `tag-release.sh`) are `#!/bin/zsh` with `[+]`
  success and `[-]` failure. Match the file you are editing; use zsh and
  `[+]`/`[-]` for a new standalone script
- Scripts `cd "$(dirname "$0")/.."` to the repo root first; most then
  refuse to run unless the `.root` marker file is there
- Minimal comments, no color output, assume tools available
- Don't add if-checks when pipefail handles failures

## GhosttyKit Design Requirements

### Wrapper Design

- GhosttyTerminal must expose **all** functionality from `ghostty.h`
- Clean Swift APIs mapping to C API: config, app lifecycle, surfaces, input, clipboard, inspector, splits, mouse, IME, text selection
- Proper Swift patterns: enums for C enums, structs for C structs, closures for callbacks
- Known gaps today: the inspector is compiled out of the shipped library
  (`Patches/ghostty/0007-disable-inspector.sh`), so `ghostty_inspector_*`
  and `ghostty_surface_inspector` are deliberately unbound; the
  `ghostty_surface_split*` family, `ghostty_app_key*`,
  `ghostty_config_load_cli_args` / `ghostty_config_load_default_files` /
  `ghostty_config_load_recursive_files` / `ghostty_config_get` (the
  controller only calls `ghostty_config_load_file` on its rendered config),
  and `ghostty_surface_quicklook_font` have no Swift wrapper yet

### Example App Requirements

- Two apps: `Example/GhosttyTerminalApp` (macOS 13+, AppKit,
  `Entitlement.entitlements` = app-sandbox + user-selected read-only) and
  `Example/MobileGhosttyApp` (iOS 16+, iPhone and iPad, Catalyst enabled,
  sandboxed by the platform); each has a `*UITests` target, and ui-tests.yml
  runs them on PRs as four jobs (iPhone and iPad simulators, Mac Catalyst,
  macOS AppKit)
- Apps run in **App Sandbox** (`ENABLE_APP_SANDBOX = YES` in both projects)
  — must NOT spawn subprocesses (non-negotiable)
- Use simulated terminal IO with the real GhosttyTerminal surface/view layer:
  both apps drive ShellCraftKit's `defaultSandboxShell` through a
  `ShellSession` and hand `backend: .inMemory(shellSession.terminalSession)`
  to the surface, which the controller maps to
  `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED`; never `.exec`, and never
  disable the sandbox for a PTY workaround
- Keep the simulated shell in ShellCraftKit, separate from the
  GhosttyTerminal integration in the view controllers
