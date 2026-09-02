# Ghostty Patches

This directory is the single place for local upstream Ghostty patches used by
the `libghostty-spm` build pipeline. They target the pinned upstream release
(`Ghostty.version` and `Ghostty.ref` at the repository root), not upstream
main.

## How they apply

`Script/build-ghostty.sh` runs `Script/apply-patches.sh <source_dir>` before
every Zig build, and `Script/build-platform.sh` calls it once per target, so
macOS, iOS, iOS Simulator, Mac Catalyst, visionOS, and visionOS Simulator all
build from the same patched tree. (Patches to Zig's own std live in
`../zig/`; they are staged by `Script/prepare-zig-lib.sh`, not by this
pipeline.) The script walks this directory in name order and dispatches on the
extension:

- `.patch` is a unified diff applied with `git -C <source> apply`; `git` must
  be installed (0003 carries a binary hunk `patch(1)` cannot apply), but the
  source may be a clone, a worktree or an extracted tarball. A patch that
  already reverse-applies is reported as applied and skipped; one that fails
  `--check` aborts the build.
- `.sh` is executed as `<script> <source_dir>`; each script checks for its
  own changes (a marker or the edited text) and skips whatever is already
  applied, so re-running it is a no-op.
- `.md` is ignored. Any other file aborts the build.

The two `0002-host-managed-io*` files are variants of one patch and only one
is applied: `-modern` when upstream `include/ghostty.h` already declares
`ghostty_surface_foreground_pid`, the plain one otherwise. Either is skipped
when the header already carries `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED`.

## Rules

- Keep patches numbered so they apply in a stable order (`0007` edits lines
  `0006` added).
- Prefer standard unified diff files (`.patch`) when the upstream context is
  stable.
- Use executable patch scripts (`.sh`) only when upstream context is too
  unstable for a reliable diff.
- Keep version-specific variants beside the original patch and select them in
  `Script/apply-patches.sh` using an upstream API marker.
- Preserve newer Ghostty's renamed internal-library outputs
  (`ghostty-internal.*`) when extending its Darwin static-library build path.
- Every patch in this directory must be safe to re-run: the pipeline applies
  the whole directory once per build target.
- Patches here are applied automatically by `Script/build-ghostty.sh`, so they
  affect macOS, iOS, Mac Catalyst, and visionOS builds equally.

## Patches

- `0001-darwin-libghostty-install.sh` — `build.zig`: install the header and
  static `libghostty.a` on Darwin, which upstream only wires for other OSes;
  handles both the `libghostty_*` and the renamed `lib_*` /
  `ghostty-internal` outputs.
- `0002-host-managed-io.patch` — the host-managed IO backend
  (`GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED`, receive-buffer and resize
  callbacks, `ghostty_surface_write_buffer` / `_process_exit`,
  `src/termio/HostManaged.zig`) plus `ghostty_surface_foreground_pid` /
  `_tty_name` stubs that return 0 / empty for every backend, `.exec`
  included: the 1.3.1 core has no process-info API to read from. The variant
  the pinned release selects.
- `0002-host-managed-io-modern.patch` — the same backend rebased onto upstream
  main (`GHOSTTY_API`, env API rename), for a release that declares
  `ghostty_surface_foreground_pid` itself.
- `0003-prebuilt-framedata.patch` — commit
  `src/build/framegen/framedata.compressed` and use it instead of building and
  running the `framegen` host tool.
- `0004-ios-fixes.sh` — ignore cf_release_thread loop errors, stub the private
  `CGSSetWindowBackgroundBlurRadius` call (App Store), link Metal and MetalKit
  in `pkg/macos`, iOS deployment target 15.0.
- `0005-ios-metal-rendering.sh` — iOS rendering: IOSurfaceLayer ±1 px
  tolerance on `CAIOSurfaceLayer`, first-frame display and synchronous present
  in `Metal.zig`, no CF release thread in coretext on iOS, 64-byte-aligned
  IOSurface rows, libxev update for the kqueue mach-port panic.
- `0006-disable-custom-shaders.sh` — `custom_shaders` build option gating
  glslang and spirv-cross (marker `LIBGHOSTTY_SPM_TRIM_PATCH`).
- `0007-disable-inspector.sh` — `inspector` build option gating dcimgui
  (marker `LIBGHOSTTY_SPM_INSPECTOR_DISABLE`).
- `0008-macos-metal-texture-storage.sh` — choose MTLTexture storage by GPU
  family: shared on Apple GPUs, managed on Intel and AMD.
- `0009-libcxx-apple-availability.sh` — force libc++ Apple availability
  annotations in highway, simdutf, and `src/simd`, so a symbol newer than the
  deployment floor (`__libcpp_verbose_abort`) fails at compile time instead of
  in dyld at launch on iOS 15 / macOS 13.0–13.2.
- `0010-fix-scroll-remainder-zeroing.patch` — `Surface.zig`: truncate the
  scrolled row amount so the pending scroll remainder is not always zero.
- `0011-replay-response-suppression.patch` —
  `ghostty_surface_write_buffer_replay`: feed reconstructed history through
  the parser with terminal protocol responses discarded at their origin.
- `0012-visionos.sh` — the `visionos` OS tag takes the iOS arm everywhere
  the build system and the Darwin runtime switch on it: `MetallibStep`
  learns the `xros` / `xrsimulator` SDKs and the Metal compiler's
  `-mtargetos=xros<ver>[-simulator]` flag (there is no
  `-mxros-version-min`), `Config.zig` gets a 1.0 minimum OS version, and
  `Metal.zig`, `IOSurfaceLayer.zig`, `coretext.zig`, `pty.zig` (NullPty),
  `os/{desktop,homedir,open}.zig`, `config/theme.zig`, `input/keycodes.zig`,
  `cli/tui.zig`, `Command.zig`, and `pkg/apple-sdk` each get `.visionos`
  beside `.ios` (marker `LIBGHOSTTY_SPM_VISIONOS_PATCH`). Needs the Zig std
  patch in `../zig/` as well.
- `0013-host-toolchain.sh` — two host-side fixes that hold for every target:
  `LibtoolStep` merges archives with `zig ar --format=darwin` (Xcode 27's
  libtool silently drops Zig's 2-byte-aligned members — oniguruma, libintl,
  freetype, simd — and only the consuming app's link notices; marker
  `LIBGHOSTTY_SPM_ZIG_AR_PATCH`), and `libghostty-vt.dylib` is no longer
  installed (nothing ships it, and its libc++ sub-compile is what fails
  under Xcode 27 and on visionOS everywhere; marker
  `LIBGHOSTTY_SPM_NO_VT_DYLIB`).
- `0014-free-text-signature.patch` — upstream commit `4803d58b`:
  `ghostty_surface_free_text` takes the surface as its first parameter, as
  `ghostty.h` has always declared it. The 1.3.1 export took only the text
  pointer, so a caller following the header handed the surface in its place
  and the text was never freed.

## Current goal

This patch workflow exists so we can carry the host-managed IO work required
for sandboxed iOS, macOS, and Mac Catalyst integration without hiding upstream
modifications inside ad-hoc build script edits. The stack currently applies to
upstream v1.3.1 (`Ghostty.version`), whose header lacks
`ghostty_surface_foreground_pid`, so `apply-patches.sh` selects
`0002-host-managed-io.patch`; the `-modern` twin waits for a release that
carries the process-info API. When bumping `Ghostty.version` and
`Ghostty.ref`, re-run the stack against the new tag and update whichever
variant or script no longer validates.
