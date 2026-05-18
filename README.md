# GhosttyKit

Swift Package wrapping [Ghostty](https://ghostty.org)'s terminal emulator library for Apple platforms.

> Pre-built `libghostty` static library distributed as an XCFramework binary target.

## Platforms

- macOS 13+
- iOS 16+
- Mac Catalyst 16+

## Products

| Library           | Description                                                                     |
| ----------------- | ------------------------------------------------------------------------------- |
| `GhosttyKit`      | Re-exports the libghostty C API (`ghostty.h`)                                   |
| `GhosttyTerminal` | Swift wrapper — native views, SwiftUI integration, input handling, display link |
| `GhosttyTheme`    | 485 terminal color themes from [iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes) (MIT License) |
| `ShellCraftKit`   | Sandboxed shell emulation framework (depends on GhosttyTerminal)                |

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "0.1.0"),
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

### SwiftUI (iOS 17+ / macOS 14+)

```swift
import SwiftUI
import GhosttyTerminal

struct ContentView: View {
    @State private var context = TerminalViewState(
        theme: .init(
            light: TerminalConfiguration {
                $0.withBackgroundOpacity(0.9)
            },
            dark: TerminalConfiguration {
                $0.withBackgroundOpacity(0.7)
            }
        ),
        terminalConfiguration: TerminalConfiguration {
            $0.withFontSize(14)
            $0.withCursorStyle(.block)
            $0.withCursorStyleBlink(true)
        }
    )

    var body: some View {
        TerminalSurfaceView(context: context)
            .navigationTitle(context.title)
            .onAppear {
                context.configuration = TerminalSurfaceOptions(
                    backend: .inMemory(session)
                )
            }
    }
}
```

`TerminalViewState` is an `@Observable` class that publishes terminal state:

- `title` — current terminal title
- `surfaceSize` — grid dimensions (columns, rows, pixels)
- `isFocused` — whether the terminal has input focus
- `renderedConfig` — the effective composed `terminal.conf` text
- `effectiveColorScheme` — the active light/dark scheme adopted from SwiftUI
- `theme` — light/dark visual overrides built from typed config commands
- `terminalConfiguration` — behavior-oriented config commands layered in order
- `configuration` — surface backend and settings
- `onClose` — callback when the terminal session ends

### UIKit

```swift
import GhosttyTerminal

let terminalView = TerminalView(frame: .zero)
terminalView.delegate = self
terminalView.controller = TerminalController(configFilePath: path)
terminalView.configuration = TerminalSurfaceOptions(
    backend: .inMemory(session)
)
```

### AppKit

```swift
import GhosttyTerminal

let terminalView = TerminalView(frame: bounds)
terminalView.delegate = self
terminalView.controller = TerminalController(configFilePath: path)
terminalView.configuration = TerminalSurfaceOptions(
    backend: .inMemory(session)
)
```

`TerminalView` is a type alias that resolves to `UITerminalView` (iOS/Catalyst) or `AppTerminalView` (macOS).

### Host-Managed I/O

For sandboxed apps that cannot spawn subprocesses, use the host-managed backend:

```swift
let session = InMemoryTerminalSession(
    write: { data in
        // Terminal produced output bytes — process or display them
    },
    resize: { viewport in
        // Terminal grid resized — update your backend
    }
)

// Feed input to the terminal
session.receive("Hello, terminal!\r\n")

// Signal process exit
session.finish(exitCode: 0, runtimeMilliseconds: 0)
```

### TerminalSurfaceViewDelegate

The delegate is split into focused protocols, all inheriting from `TerminalSurfaceViewDelegate`. Conform to only the ones you need:

```swift
protocol TerminalSurfaceTitleDelegate      { func terminalDidChangeTitle(_ title: String) }
protocol TerminalSurfaceGridResizeDelegate { func terminalDidResize(_ size: TerminalGridMetrics) }
protocol TerminalSurfaceResizeDelegate     { func terminalDidResize(columns: Int, rows: Int) }
protocol TerminalSurfaceFocusDelegate      { func terminalDidChangeFocus(_ focused: Bool) }
protocol TerminalSurfaceBellDelegate       { func terminalDidRingBell() }
protocol TerminalSurfaceCloseDelegate      { func terminalDidClose(processAlive: Bool) }
```

## Architecture

```
GhosttyKit (C API)
    libghostty.a — Ghostty core (Zig → static lib)
    ghostty.h — C header

GhosttyTerminal (Swift)
    TerminalViewState          — @Observable state for SwiftUI
    TerminalSurfaceView        — SwiftUI View (wraps representable)
    TerminalView               — Platform view typealias (UIView / NSView)
    TerminalController         — App lifecycle, config, surface creation
    TerminalSurfaceCoordinator — Shared logic, display link, metrics
    TerminalSurface            — Thin wrapper around ghostty_surface_t
    TerminalKeyEventHandler    — Keyboard event translation (AppKit)
    InMemoryTerminalSession    — Sandbox-safe I/O backend

GhosttyTheme (485 color themes)
    GhosttyThemeDefinition     — Theme data model (name, colors, palette)
    GhosttyThemeCatalog        — Static catalog, search, lookup by name
```

## Trimmed Build

The bundled `libghostty` is a trimmed build optimized for sandboxed, embedded use on Apple platforms. Several upstream Ghostty components that are unnecessary (or incompatible) in this context have been removed or stubbed out via build flags and patches.

| Component                        | Upstream Ghostty | libghostty-spm   | Reason                                                                                                                                                |
| -------------------------------- | ---------------- | ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Terminal emulation core          | Yes              | Yes              | Full VT parser, state machine, grid — retained                                                                                                        |
| Metal renderer                   | Yes              | Yes              | GPU rendering via CAMetalLayer / IOSurface — retained                                                                                                 |
| Font rasterization & shaping     | Yes              | Yes              | CoreText font backend — retained                                                                                                                      |
| Configuration system             | Yes              | Yes              | All terminal config options — retained                                                                                                                |
| Input handling (key, mouse, IME) | Yes              | Yes              | Full keyboard/mouse/touch/IME pipeline — retained                                                                                                     |
| Text selection & clipboard       | Yes              | Yes              | Selection, copy/paste APIs — retained                                                                                                                 |
| Custom shaders (GLSL)            | Yes              | **No**           | `glslang` and `spirv-cross` removed (`-Dcustom-shaders=false`). Shadertoy/post-processing shaders are a desktop feature unnecessary for embedded use. |
| Terminal inspector (ImGui)       | Yes              | **No**           | `dcimgui` (Dear ImGui) removed (`-Dinspector=false`). Debug inspector UI replaced with no-op stubs.                                                   |
| Sentry crash reporting           | Yes              | **No**           | Disabled (`-Dsentry=false`). Not needed for library consumers.                                                                                        |
| Native app runtime               | Yes              | **No**           | Cocoa/GTK/Wayland app shell disabled (`-Dapp-runtime=none`). The host app provides its own runtime.                                                   |
| Standalone executable            | Yes              | **No**           | No terminal `.app` or CLI binary emitted (`-Demit-exe=false`).                                                                                        |
| Documentation generation         | Yes              | **No**           | Skipped (`-Demit-docs=false`).                                                                                                                        |
| Frame data generator             | Build-time tool  | **Pre-compiled** | `framedata.compressed` shipped pre-built; framegen C tool dependency removed.                                                                         |
| Host-managed I/O backend         | No               | **Added**        | New `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED` for non-PTY, sandbox-safe terminal I/O.                                                                 |
| iOS Metal rendering fixes        | No               | **Added**        | IOSurface +1px tolerance, synchronous present, 64-byte row alignment for iOS.                                                                         |
| iOS platform fixes               | No               | **Added**        | Deployment target lowered, private API removed (`CGSSetWindowBackgroundBlurRadius`), kqueue fix for simulator.                                        |

## Building from Source

The package includes a pre-built XCFramework. To rebuild libghostty from the Ghostty source:

```bash
# Requires: zig compiler
./Script/build.sh
```

This applies patches from `Patches/ghostty/`, builds for all target architectures, and assembles the XCFramework.

## Example Apps

- `Example/GhosttyTerminalApp/` — macOS demo (AppKit + delegate pattern)
- `Example/MobileGhosttyApp/` — iOS demo (UIKit + safe area handling)

Both use a mock echo terminal (`MockTerminalSession`) with the host-managed I/O backend to run inside App Sandbox without spawning subprocesses.

## License

MIT License. See [LICENSE](LICENSE) for details.

The bundled `libghostty` binary is built from [Ghostty](https://ghostty.org), which has its own license terms.

## Sponsor

[LookInside](https://lookinside-app.com/) helps you inspect a running iOS or macOS app UI from your Mac.
