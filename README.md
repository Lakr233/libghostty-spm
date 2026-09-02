# GhosttyKit

Swift Package wrapping [Ghostty](https://ghostty.org)'s terminal emulator library for Apple platforms.

> Pre-built `libghostty` static library distributed as an XCFramework binary target.

## Platforms

- macOS 13+
- iOS 15+
- Mac Catalyst 15+
- visionOS 1+ (`GhosttyTerminal` is the iOS view: touch, pointer, and
  hardware keyboard work; there is no input accessory bar, no haptics, and
  no `UIScreen`-derived scale — see the `#if os(visionOS)` guards)

## Products

| Library           | Description                                                                     |
| ----------------- | ------------------------------------------------------------------------------- |
| `GhosttyKit`      | Re-exports the libghostty C API (`ghostty.h`)                                   |
| `GhosttyTerminal` | Swift wrapper — native views, SwiftUI integration, input handling, display link |
| `GhosttyTheme`    | 485 terminal color themes from [iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes) (MIT License) |
| `ShellCraftKit`   | Sandboxed shell emulation framework (depends on GhosttyTerminal)                |

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.5.1"),
]
```

Then add the product you need:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "GhosttyTerminal", package: "libghostty-spm"),
    ]
)
```

## Usage

Start from the example apps:

- `Example/GhosttyTerminalApp/` — macOS AppKit demo with delegate callbacks
- `Example/MobileGhosttyApp/` — iOS UIKit demo with keyboard, safe area, themes, and text selection

### SwiftUI (iOS 15+ / macOS 13+ / Mac Catalyst 15+ / visionOS 1+)

```swift
import SwiftUI
import GhosttyTerminal

struct ContentView: View {
    @StateObject private var terminal = TerminalViewState()
    private let session = InMemoryTerminalSession(
        write: { data in
            // Handle bytes produced by the terminal.
        },
        resize: { viewport in
            // Keep your host backend in sync with the terminal grid.
        }
    )

    var body: some View {
        TerminalSurfaceView(context: terminal)
            .navigationTitle(terminal.title)
            .onAppear {
                terminal.configuration = TerminalSurfaceOptions(
                    backend: .inMemory(session)
                )
            }
    }
}
```

A host that keeps several surfaces mounted at once (tabs hidden behind
`opacity(0)`) sets `terminal.isSurfaceVisible = false` on the hidden ones.
The surface keeps its grid, scrollback, and session; only rendering stops.

### UIKit / AppKit

```swift
import GhosttyTerminal

let terminalView = TerminalView(frame: .zero)
terminalView.delegate = self
terminalView.controller = TerminalController(configFilePath: path)
terminalView.configuration = TerminalSurfaceOptions(
    backend: .inMemory(session)
)
```

`TerminalView` is a type alias that resolves to `UITerminalView` (iOS/Catalyst) or `AppTerminalView` (macOS).

### Keys and Pasted Text

`TerminalViewState` and `TerminalView` expose the same two input paths, and
they are not interchangeable:

```swift
terminal.sendKey(.enter)                         // Press and release a key.
terminal.sendKey(.c, modifiers: .ctrl)           // Ctrl+C.
terminal.sendKey(TerminalKeyPress(typing: "C")!) // c with Shift, from the US layout.
terminal.paste(text: "ls -la")                   // A paste, not keystrokes.
```

`sendKey(_:)` is the key path (also on `TerminalSurface`): `TerminalKey`
mirrors every libghostty key, the press is encoded the way the program's key
mode expects, and a release follows. `paste(text:)` is the text path: a
program that enabled bracketed paste receives it framed as a paste, so a `\r`
in it is a pasted character, not Enter. `TerminalViewState.send(_:)` and
`AppTerminalView.sendText(_:)` are deprecated names of `paste(text:)` for that
reason — they never sent keystrokes. On `TerminalSurface` the text path keeps
its primitive name, `sendText(_:)`.

### Prompt and Scrollback Navigation

`TerminalViewState`, `TerminalView`, and `TerminalSurface` expose the same
programmatic navigation APIs:

```swift
terminal.jumpToPrompt(by: -1) // Previous prompt.
terminal.jumpToPrompt(by: 1)  // Next prompt.
terminal.scrollToRow(0)        // First absolute scrollback row.
```

Prompt navigation requires [shell integration](https://ghostty.org/docs/features/shell-integration),
which records prompt boundaries. The package bundles its own MIT-licensed
bash and zsh integration (OSC 133 prompt marks, OSC 7 working directory,
OSC 2 title, cursor shape) under `Resources/Ghostty/shell-integration`, and
the `.exec` backend injects it the way upstream Ghostty does; upstream's own
scripts are GPLv3 and are deliberately not shipped. Other shells get no
automatic integration. A host-managed backend must preserve or emit
equivalent OSC 133 prompt markers. Arbitrary Ghostty actions remain available
through `performBindingAction(_:)`.

### Pasting and Dropping Files

A paste reads the pasteboard the way Ghostty's macOS app does: URLs first —
a file URL as its shell-escaped path, any other URL verbatim — then the
string. A file copied in Finder or Files therefore pastes its path, never the
display name that sits beside it on the pasteboard. On iOS and Mac Catalyst,
image or document data with no path of its own (a screenshot, a photo, a file
copied out of Files) is written to a file first and the file's escaped path is
pasted.

Ghostty asks the host before a protected clipboard operation — a program
reading the clipboard through OSC 52, writing it when `clipboard-write = ask`,
or a paste that paste protection flagged — through
`TerminalViewState.onClipboardConfirmationRequest` (a delegate adopts
`TerminalSurfaceClipboardConfirmationDelegate`); the host presents the request
and answers `respond(allow:)`. While the hook is `nil`, a program's read or
write is denied silently and a paste the user started is allowed.

Dropping onto the terminal works the same way on iOS and Mac Catalyst: files
and images are copied into the staging directory and their escaped paths are
pasted; a dropped folder, link, or text pastes as text. Everything a drop
delivers travels the text path, like a paste — never as keystrokes.

Staged files live under `TerminalFileStaging.directory`, a `ghostty-paste`
folder in the app's temporary directory by default. A host whose shell cannot
read the app container points it somewhere both can reach before the first
paste or drop. Files stay until `TerminalFileStaging.staleFileAge` (24 hours)
has passed — swept whenever a new file is written, or on
`TerminalFileStaging.removeStaleFiles()`. A host calls
`TerminalFileStaging.removeAllFiles()` once no shell can reach the staged
files — its last shell ended, or the app is quitting together with its shells.

```swift
// A host that ends every shell when it quits.
func applicationWillTerminate(_: UIApplication) {
    endAllSessions()
    TerminalFileStaging.removeAllFiles()
}
```

### Surface Snapshots and Host View Subclasses

`TerminalView.snapshotImage()` renders the surface's current on-screen
contents into a `UIImage`/`NSImage`, and
`TerminalViewState.attachedPlatformView` hands the presenting view to hosts
that hold only the state. On UIKit the snapshot is a render-server pass
(`drawHierarchy`), so the Metal layer's presented frame is included; on AppKit
it is `cacheDisplay`, best-effort for Metal content.

Hosts that need their own view behavior — an interaction lock, custom hit
testing, a keyboard policy — set `TerminalViewState.makePlatformView` to
return a `TerminalView` subclass before the surface first appears; the
SwiftUI representable instantiates it instead of the base class. Policy
belongs in such a subclass, never in the byte stream: output keeps flowing
and rendering regardless. The overridable seams are everything UIKit/AppKit
give a view (`hitTest`, `canBecomeFirstResponder`) plus
`UITerminalView.toggleSoftwareKeyboard()`, which a clean tap calls after its
click has been sent — override it to keep a tap from raising or dismissing
the software keyboard.

## Notes

- `TerminalViewState` is the SwiftUI state container.
- `TerminalView` is the UIKit/AppKit view typealias.
- `TerminalController` owns app lifecycle, config resolution, themes, and surface creation.
- `InMemoryTerminalSession` provides the host-managed backend used by the sandboxed example apps.
- `GhosttyThemeCatalog` exposes bundled iTerm2 color schemes.

## Building from Source

The package downloads a pre-built XCFramework. To rebuild libghostty from the Ghostty source:

```bash
# Requires: zig (CI builds with 0.15.2 — the pinned upstream's minimum_zig_version)
./build.sh
./build.sh --platforms macos,ios --source /path/to/ghostty --skip-tests
```

`build.sh` forwards to `Script/build.sh`. Without `--source` it clones Ghostty
into `References/ghostty-upstream`; `--ref` checks out a tag or commit there
(`Ghostty.ref` is the commit the shipped asset was built from). It applies the
patches in `Patches/ghostty/`, builds each platform group (`macos`, `ios`,
`maccatalyst`, `visionos` by default; macOS, Catalyst, and simulator slices
are arm64 and x86_64), assembles `BinaryTarget/GhosttyKit.xcframework` and
`build/GhosttyKit.xcframework.zip`, and runs `Script/test.sh` and `swift test`
against the result unless `--skip-tests` is given. `Package.local.swift`
points the binary target at that local `BinaryTarget/` build; `--download-url`
regenerates `Package.swift` from `Package.swift.template` for an uploaded zip.

The `visionos` group builds against a patched copy of Zig 0.15.2's standard
library (`Patches/zig/`, staged under `build/cache` by
`Script/prepare-zig-lib.sh`; the toolchain itself is not modified). On a Mac
with Xcode 27 the pinned Zig cannot link its own build runner against the
macOS SDK; `eval "$(./Script/support/xcode27-sdk-overlay.sh)"` puts a
per-checkout SDK overlay on PATH that fixes that for the shell.

## Versions

Pin `1.5.1` or later (`from: "1.5.1"`). The `1.4.0` … `1.4.13` and `1.5.0`
tags and releases were withdrawn and no longer exist, so `1.5.1` is the
oldest live tag on this track and the first with visionOS slices. Package
versions are independent of Ghostty's own version — every release so far ships Ghostty
v1.3.1 (`Ghostty.version`; `Ghostty.ref` pins its commit). Package tags are
cut by the "Release Package" workflow only; `Script/audit-releases.sh`
checks every tag's manifest against the asset it downloads.

`upstream.<X.Y.Z>` releases carry the XCFramework built from Ghostty `X.Y.Z`
(`upstream.<X.Y.Z>-<N>` when the same Ghostty was rebuilt with a changed patch
stack or target set — `Ghostty.build` holds `N`; `upstream.1.3.1-2` is the
first asset with visionOS slices); each package tag's `Package.swift`
downloads one of them. Those and the older
`storage.*` tags are XCFramework assets, not package versions. SPM should not
depend on them.

## Trimmed Build

The bundled `libghostty` is a trimmed build optimized for sandboxed, embedded use on Apple platforms.

| Component                        | Upstream Ghostty | libghostty-spm   | Reason                                                                                                                                                |
| -------------------------------- | ---------------- | ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Terminal emulation core          | Yes              | Yes              | Full VT parser, state machine, grid — retained                                                                                                        |
| Metal renderer                   | Yes              | Yes              | GPU rendering via CAMetalLayer / IOSurface — retained                                                                                                 |
| Font rasterization & shaping     | Yes              | Yes              | CoreText font backend — retained                                                                                                                      |
| Configuration system             | Yes              | Yes              | All terminal config options — retained                                                                                                                |
| Input handling (key, mouse, IME) | Yes              | Yes              | Full keyboard/mouse/touch/IME pipeline — retained                                                                                                     |
| Text selection & clipboard       | Yes              | Yes              | Selection, copy/paste APIs — retained                                                                                                                 |
| Custom shaders (GLSL)            | Yes              | **No**           | `glslang` and `spirv-cross` removed (`-Dcustom-shaders=false`). Shadertoy/post-processing shaders are a desktop feature unnecessary for embedded use. |
| Terminal inspector (ImGui)       | Yes              | **No**           | `dcimgui` removed (`-Dinspector=false`). Debug inspector UI replaced with no-op stubs.                                                                |
| Sentry crash reporting           | Yes              | **No**           | Disabled (`-Dsentry=false`).                                                                                                                          |
| Native app runtime               | Yes              | **No**           | Cocoa/GTK/Wayland app shell disabled (`-Dapp-runtime=none`). The host app provides its own runtime.                                                   |
| Standalone executable            | Yes              | **No**           | No terminal `.app`, CLI binary, or upstream xcframework emitted (`-Demit-exe=false`, `-Demit-macos-app=false`, `-Demit-xcframework=false`).           |
| Documentation generation         | Yes              | **No**           | Skipped (`-Demit-docs=false`).                                                                                                                        |
| Frame data generator             | Build-time tool  | **Pre-compiled** | `framedata.compressed` shipped pre-built; framegen C tool dependency removed.                                                                         |
| Host-managed I/O backend         | No               | **Added**        | New `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED` for non-PTY, sandbox-safe terminal I/O.                                                                 |
| iOS Metal rendering fixes        | No               | **Added**        | IOSurface +1px tolerance, synchronous present, 64-byte row alignment for iOS.                                                                         |
| iOS platform fixes               | No               | **Added**        | Deployment target lowered to 15.0, private window blur API removed, kqueue fix for simulator.                                                        |
| macOS Metal texture storage      | No               | **Added**        | Shared textures on iOS and Apple GPUs, managed on Intel/AMD macOS GPUs.                                                                              |
| libc++ availability              | No               | **Added**        | Zig's libc++ headers built with Apple availability annotations; `__libcpp_verbose_abort` shipped in the archive so apps launch below iOS 16.3 / macOS 13.3. |
| Scroll remainder fix             | No               | **Added**        | Wheel scrolling keeps its sub-row remainder instead of zeroing it.                                                                                   |
| History replay                   | No               | **Added**        | `ghostty_surface_write_buffer_replay` feeds reconstructed history through the parser with terminal protocol responses suppressed.                     |

## License

MIT License. See [LICENSE](LICENSE) for details.

The bundled `libghostty` binary is built from [Ghostty](https://ghostty.org), MIT License, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors.

`Sources/GhosttyTerminal/Resources/terminfo/` is the `xterm-ghostty` terminfo entry compiled from Ghostty's `src/terminfo/ghostty.zig` (same MIT License and copyright).

`Sources/GhosttyTerminal/Resources/Ghostty/shell-integration/` is this package's own bash and zsh integration, MIT License, written from scratch — Ghostty's own bash and zsh integration scripts are GPLv3 and are not shipped. `bash/bash-preexec.sh` is vendored from [bash-preexec](https://github.com/rcaloras/bash-preexec), MIT License; see [LICENSE-bash-preexec.md](Sources/GhosttyTerminal/Resources/Ghostty/shell-integration/bash/LICENSE-bash-preexec.md).

`GhosttyTheme` color data comes from [iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes), MIT License; see [Sources/GhosttyTheme/LICENSE](Sources/GhosttyTheme/LICENSE).

## Sponsor

- [LookInside](https://lookinside-app.com/) helps you inspect a running iOS or macOS app UI from your Mac.
- This project is sponsored by AFK AI, INC.
