# Zig Patches

Patches to the Zig *standard library*, for targets the pinned Zig only half
knows. They are applied to a copy of the toolchain's `lib/` staged under the
build cache by `Script/prepare-zig-lib.sh`, never to the installation itself;
`Script/build-ghostty.sh` exports that copy as `ZIG_LIB_DIR` for the visionOS
targets when a patch for the Zig on PATH exists here, and leaves every target
on the untouched toolchain otherwise.

Files are named `<zig version>-visionos-std.patch` and applied with
`patch -p1` from the lib directory (paths start at `std/`). A Zig with no
patch here builds visionOS against its stock std; a
`@compileError("unimplemented")` from a `native_os` switch on such a build
means the new Zig regressed an arm and needs a patch under its exact
`zig version`.

## Patches

None today. `0.15.2-visionos-std.patch` added `.visionos` to the `native_os`
switches 0.15.2 left it out of (`fs.max_path_bytes`, the `fs.Dir` iterator,
`process.Child` rusage, the DWARF unwinder); Zig 0.16.0 carries those arms
itself, so the patch was dropped with the 0.16 bump.
