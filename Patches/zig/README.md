# Zig Patches

Patches to the Zig *standard library*, for targets the pinned Zig only half
knows. They are applied to a copy of the toolchain's `lib/` staged under the
build cache by `Script/prepare-zig-lib.sh`, never to the installation itself;
`Script/build-ghostty.sh` exports that copy as `ZIG_LIB_DIR` for the targets
that need it and leaves every other target on the untouched toolchain.

Files are named `<zig version>-<name>.patch` and applied with `patch -p1`
from the lib directory (paths start at `std/`). When the Zig pin moves
(build.yml / source-build.yml, and the upstream `minimum_zig_version`),
re-diff the patch against the new std or delete it if the arms landed
upstream — `prepare-zig-lib.sh` refuses to run without a patch for the
exact `zig version` it finds.

## Patches

- `0.15.2-visionos-std.patch` — adds `.visionos` (and the other Apple tags,
  `.tvos` / `.watchos`, where the arm is generic Darwin) to the `native_os`
  switches that stop a `-Dtarget=*-visionos` build: `fs.max_path_bytes` /
  `max_name_bytes`, the `fs.Dir` iterator and `deleteTree`, `process.Child`
  rusage, and the DWARF unwinder's Darwin `mcontext` arms. Zig 0.15.2's
  `Target.zig` already knows the tag; only these switches were missing it.
