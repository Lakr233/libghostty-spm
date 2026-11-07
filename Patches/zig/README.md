# Zig Patches

Patches to the Zig *standard library*, for targets the pinned Zig only half
supports. They are applied to a copy of the toolchain's `lib/` staged under
the build cache by `Script/prepare-zig-lib.sh`, never to the installation
itself; `Script/build-ghostty.sh` exports that copy as `ZIG_LIB_DIR` for the
iOS and visionOS targets when a patch for the Zig on PATH exists here, and
leaves every target on the untouched toolchain otherwise.

Files are named `<zig version>-ios-visionos-std.patch` and applied with
`patch -p1` from the lib directory (paths start at `std/`). A Zig with no
patch here builds those targets against its stock std; a compile error
inside the std on such a build means the new Zig regressed them and needs a
patch under its exact `zig version`.

## Patches

`0.17.0-ios-visionos-std.patch` sets `process.can_replace` false on the iOS,
tvOS, visionOS and watchOS tags, where `can_spawn` already is. `Io.Threaded`'s
vtable always holds `processReplace`, which on every Darwin tag calls
`spawnDarwin` and through it `getDevNullFd`, and `NullFile` has no `fd` on
those tags, so a stock 0.17.0 std stops at `no field named 'fd'` for any
target on them. With `can_replace` false the body is never analyzed. Giving
`NullFile` the field compiles as well, but it pulls `posix_spawn` and its
`_np` helpers into every iOS archive for code nothing calls. Ghostty's exec
backend goes through `Command.zig`'s own `execve`, so it does not depend on
`can_replace`. Upstream stopped building Ghostty.xcframework for iOS in
2026-08, so its CI never meets this.

Earlier: `0.15.2-visionos-std.patch` added `.visionos` to the `native_os`
switches 0.15.2 left it out of (`fs.max_path_bytes`, the `fs.Dir` iterator,
`process.Child` rusage, the DWARF unwinder); Zig 0.16.0 carried those arms
itself, so the patch was dropped with the 0.16 bump.
