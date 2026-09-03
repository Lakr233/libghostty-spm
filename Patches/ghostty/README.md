# Ghostty Patches

This directory is the single place for local upstream Ghostty patches used by
the `libghostty-spm` build pipeline. They target the pinned upstream commit
(`Ghostty.ref` at the repository root), not whatever upstream main is today.

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
  `--check` is retried with `git apply --3way`, which merges the hunks
  against the blobs named in the patch's `index` lines (so cut every patch
  with `git diff`, which writes them, and regenerate a patch the log says
  needed the 3-way merge); one that conflicts even then aborts the build.
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
  `Script/apply-patches.sh` using an upstream API marker — a grep for the
  code the patch touches (`linkSystemLibrary2` in `GhosttyFrameData.zig`,
  `pub fn environMap` in `global.zig`), never a version string: a version
  test picks the wrong variant the moment the next version lands, a code
  test keeps picking the right one until that code moves again.
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
- `0002-host-managed-io-modern-v2.patch` — the `-modern` patch after
  upstream's `global.environMap()` / `global.resourcesDir()` rename
  (selected when `src/global.zig` declares `environMap`). The variant the
  pinned commit selects.
- `0003-prebuilt-framedata.patch` — commit
  `src/build/framegen/framedata.compressed` and use it instead of building and
  running the `framegen` host tool.
- `0003-prebuilt-framedata-v2.patch` — the same for a source that requires
  Zig 0.16 (`addCSourceFile` / `linkSystemLibrary` moved onto
  `root_module`); `0005-ios-metal-rendering-v2.sh` and
  `0006-disable-custom-shaders-v2.sh` are the matching variants of 0005
  and 0006, selected by the same markers in `apply-patches.sh`.
- `0004-ios-fixes.sh` — ignore cf_release_thread loop errors, stub the private
  `CGSSetWindowBackgroundBlurRadius` call (App Store), link Metal and MetalKit
  in `pkg/macos`, iOS deployment target 15.0, and turn upstream's "iOS is
  not a supported target for the full Ghostty build" refusal in
  `Config.zig` into a comptime-false branch (marker
  `LIBGHOSTTY_SPM_IOS_FULL_BUILD`; skipped on a source without the guard).
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
  `apprt.surface.Message.discardIfTerminalResponse` does not cover
  `kitty_clipboard_read`/`kitty_clipboard_write` (added after this patch was
  authored) — the receiver takes ownership of a boxed request it must
  destroy, which the classifier has no way to do. Replaying reconstructed
  history containing a Kitty clipboard protocol sequence can still leak a
  confirmation to the host; low risk today (no on-disk scrollback replay uses
  this path yet) but worth closing if that changes.
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
- `0016-maccatalyst.sh` — Zig 0.16 made Mac Catalyst its own OS tag
  (`aarch64-maccatalyst`; 0.15 spelled it `aarch64-ios-macabi`, os `.ios`
  + abi `.macabi`), so the `.ios` arms stopped covering it. `.maccatalyst`
  takes the iOS arm wherever 0012 gives `.visionos` one, `osVersionMin`
  gets a 15.0 arm (Catalyst versions follow iOS), `MetallibStep` compiles
  the shaders as for device iOS (what the 0.15 fall-through shipped), and
  `apple-sdk/native_link.zig` learns the macOS SDK + `-macabi` triple
  (marker `LIBGHOSTTY_SPM_MACCATALYST_PATCH`; runs after 0012).
- `0017-zig-pkg-apple-targets.sh` — the Zig packages Ghostty pulls in that
  predate one of our targets: libxev (the event loop) gets `.maccatalyst`
  beside its Darwin arms, and aro (the C frontend behind 0.16's
  translate-c) gets a `.visionos` arm for the Apple version macro it would
  otherwise abort on. Packages are unpacked by 0.16 under
  `<source>/zig-pkg/`, so the script runs `zig build --fetch` when they are
  missing (a fresh clone) and edits the unpacked copies, which later builds
  leave alone; `build-ghostty.sh` hands `apply-patches.sh` the build's
  `ZIG_GLOBAL_CACHE_DIR` so the fetch reuses its cache.

Dropped once upstream carried them: `0014-free-text-signature.patch`
(`ghostty_surface_free_text` taking the surface, upstream `4803d58b`). A
patch that only "already applies" is a liability — the day its context
moves, both the forward and the reverse check fail on a change we no
longer need — so delete one as soon as the pin includes it.

## Current goal

This patch workflow exists so we can carry the host-managed IO work required
for sandboxed iOS, macOS, and Mac Catalyst integration without hiding upstream
modifications inside ad-hoc build script edits. The pin (`Ghostty.ref`)
moves to upstream main's head every week (weekly.yml), so the stack is
exercised against a fresh tree each time: a variant that stops validating
fails that week's build, and the fix is a new `-vN` variant selected by an
upstream marker in `apply-patches.sh`, never an edit to the older one.
