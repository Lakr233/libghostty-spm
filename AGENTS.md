# Swift Code Style Guidelines

## Core Style
- **Indentation**: 4 spaces
- **Braces**: Opening brace on same line
- **Spacing**: Single space around operators and commas
- **Naming**: PascalCase for types, camelCase for properties/methods

## File Organization
- Logical directory grouping
- PascalCase files for types, `+` for extensions
- Modular design with extensions

## Modern Swift Features
- **@Observable macro**: Replace `ObservableObject`/`@Published`
- **Swift concurrency**: `async/await`, `Task`, `actor`, `@MainActor`
- **Result builders**: Declarative APIs
- **Property wrappers**: Use line breaks for long declarations
- **Opaque types**: `some` for protocol returns

## Code Structure
- Early returns to reduce nesting
- Guard statements for optional unwrapping
- Single responsibility per type/extension
- Value types over reference types

## Error Handling
- `Result` enum for typed errors
- `throws`/`try` for propagation
- Optional chaining with `guard let`/`if let`
- Typed error definitions

## Architecture
- Avoid using protocol-oriented design unless necessary
- Dependency injection over singletons
- Composition over inheritance
- Factory/Repository patterns

## Debug Assertions
- Use `assert()` for development-time invariant checking
- Use `assertionFailure()` for unreachable code paths
- Assertions removed in release builds for performance
- Precondition checking with `precondition()` for fatal errors

## Memory Management
- `weak` references for cycles
- `unowned` when guaranteed non-nil
- Capture lists in closures
- `deinit` for cleanup

# Shell Script Style

## Core Principles

- **Simplicity**: Keep scripts minimal and focused
- **No unnecessary complexity**: Avoid features that aren't needed
- **Visual clarity**: Use line breaks for readability
- **Failure handling**: Use `set -euo pipefail`
- **Use shebang for scripts**: Use `#!/bin/zsh`

## Output Guidelines

- Use `[+]` for successful operations
- Use `[-]` for failed operations (when needed)
- Keep echo messages lowercase
- Simple status messages: "building...", "completed successfully"

## Code Style

- Minimal comments - focus on self-evident code
- No unnecessary color output or visual fluff
- Line breaks for long command chains
- Assume required tools are available (e.g., xcbeautify)
- Don't add if checks when pipefail handles failures

# Code Organization Principles

- **Single Source of Truth**: Maintain one authoritative source for each piece of logic or data
- **Method Extraction**: Think carefully before extracting logic into methods - avoid unnecessary abstraction
- **File Splitting**: Split files frequently, maintain small, focused files using `Xxx+Xxx.swift` pattern
- **File Size**: Keep files small and beautiful, aim for concise, focused implementations
- **Method Length**: Split long methods and complex logic into smaller, digestible pieces

# GhosttyKit Design Requirements

## Wrapper Design

- The GhosttyTerminal Swift wrapper must expose **all** functionality from `ghostty.h`
- Design clean Swift APIs that map to the C API: config management, app lifecycle, surface creation, input handling, clipboard, inspector, splits, mouse, IME, text selection, etc.
- Use proper Swift patterns: enums for C enums, structs for C structs, closures for callbacks
- Follow dependency injection over singletons (TerminalController.shared is convenience, not the only path)

## Example App Requirements

- The example app runs in **App Sandbox** — it must NOT spawn subprocesses
- This sandbox requirement is non-negotiable: do **not** disable App Sandbox to work around `forkpty`, PTY creation, or any other Ghostty integration issue
- Use **mock terminal IO** (echo/chat interface) to demonstrate the terminal UI
- The example app must still use the real `GhosttyTerminal` surface/view layer while providing terminal IO from an in-process mock backend
- If `NativeTerminalView` or lower-level Ghostty surface setup expects PTY-backed IO, the implementation work must inspect the API and add the necessary in-process input/output bridge instead of falling back to a fake `NSTextView`
- “Keep sandbox enabled, and inspect how we can grab input and output” is a required project goal, not an optional approach
- Use GhosttyKit for config initialization and to demonstrate API usage
- Apply the default ghostty config for theming and terminal behavior
- Keep the echo terminal as a self-contained module separate from GhosttyKit integration
