#!/bin/bash
# visionOS: teach the build system and the Darwin runtime switches that the
# `visionos` OS tag is the iOS shape — UIView + CAMetalLayer, no PTY, no home
# directory — so `-Dtarget=aarch64-visionos` builds the same libghostty iOS gets.
set -euo pipefail
SOURCE_DIR=${1:?usage: $0 <ghostty_source_dir>}
cd "$SOURCE_DIR"
if grep -q 'LIBGHOSTTY_SPM_VISIONOS_PATCH' src/build/MetallibStep.zig; then echo "[+] visionos patch already applied"; exit 0; fi

# 1. MetallibStep: xros / xrsimulator SDKs and the -mtargetos flag (the Metal
#    compiler has no -mxros-version-min; it takes -mtargetos=xros<ver>[-simulator]).
#
#    c4e16970a-era MetallibStep.create() dropped iOS support from `sdk` and
#    `min_version` entirely (both are macos-only, `else => return null` /
#    `else => unreachable`), so this can no longer append a `.visionos` arm
#    next to an existing `.ios` one — it rebuilds the macos-only switches
#    into three-way (macos/ios/visionos) ones from scratch.
python3 - src/build/MetallibStep.zig <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

sdk_anchor = """    const sdk = switch (opts.target.result.os.tag) {
        .macos => "macosx",
        else => return null,
    };
    const platform_version_arg = switch (opts.target.result.os.tag) {
        .macos => "-mmacos-version-min",
        else => null,
    };
"""
sdk_replacement = """    const sdk = switch (opts.target.result.os.tag) {
        .macos => "macosx",
        .ios => switch (opts.target.result.abi) {
            .simulator => "iphonesimulator",
            else => "iphoneos",
        },
        // LIBGHOSTTY_SPM_VISIONOS_PATCH
        .visionos => switch (opts.target.result.abi) {
            .simulator => "xrsimulator",
            else => "xros",
        },
        else => return null,
    };
"""

min_version_anchor = """    else switch (opts.target.result.os.tag) {
        .macos => "10.14",
        else => unreachable,
    };
"""
min_version_replacement = """    else switch (opts.target.result.os.tag) {
        .macos => "10.14",
        .ios => "11.0",
        .visionos => "1.0",
        else => unreachable,
    };
"""

version_arg_anchor = """    if (platform_version_arg) |arg| {
        run_ir.addArgs(&.{b.fmt(
            "{s}={s}",
            .{ arg, min_version },
        )});
    }
"""
version_arg_replacement = """    const version_flag: ?[]const u8 = switch (opts.target.result.os.tag) {
        .macos => b.fmt("-mmacos-version-min={s}", .{min_version}),
        .ios => switch (opts.target.result.abi) {
            .simulator => b.fmt("-mios-simulator-version-min={s}", .{min_version}),
            else => b.fmt("-mios-version-min={s}", .{min_version}),
        },
        .visionos => switch (opts.target.result.abi) {
            .simulator => b.fmt("-mtargetos=xros{s}-simulator", .{min_version}),
            else => b.fmt("-mtargetos=xros{s}", .{min_version}),
        },
        else => null,
    };
    if (version_flag) |arg| run_ir.addArgs(&.{arg});
"""

for anchor, replacement, label in (
    (sdk_anchor, sdk_replacement, "sdk/platform_version_arg"),
    (min_version_anchor, min_version_replacement, "min_version"),
    (version_arg_anchor, version_arg_replacement, "version_flag"),
):
    if anchor not in text:
        print(f"[-] MetallibStep.zig anchor not found: {label}; upstream changed, update this patch")
        sys.exit(1)
    text = text.replace(anchor, replacement)

path.write_text(text)
print("[+] patched: MetallibStep.zig")
PY
grep -q 'xrsimulator' src/build/MetallibStep.zig && grep -q 'version_flag' src/build/MetallibStep.zig || { echo "[!] MetallibStep patch failed"; exit 1; }
echo "[+] patched MetallibStep.zig"

# 2. Config.zig: a minimum OS version for visionOS, and the iOS defaults.
#
#    osVersionMin() no longer carries its own `.ios` arm (iOS's minimum now
#    lives only in the separate osVersionMinLibVt() special case), so there
#    is no existing `.ios => .{ .semver = ...}` line to append a `.visionos`
#    arm after. Add one directly, same as `.macos`'s.
perl -0pi -e 's/(        \.macos => \.\{ \.semver = \.\{\n            \.major = \d+,\n            \.minor = \d+,\n            \.patch = \d+,\n        \} \},\n)/$1\n        \/\/ visionOS 1.0 is the first release; nothing here needs newer.\n        .visionos => .{ .semver = .{\n            .major = 1,\n            .minor = 0,\n            .patch = 0,\n        } },\n/' src/build/Config.zig
perl -pi -e 's/^(\s+)\.macos, \.ios => (break :sentry true,|true,)$/$1.macos, .ios, .visionos => $2/' src/build/Config.zig
grep -q '\.visionos => \.{ \.semver' src/build/Config.zig || { echo "[!] Config.zig patch failed"; exit 1; }
echo "[+] patched Config.zig"

# 3. Runtime switches: visionOS takes the iOS arm everywhere.
perl -pi -e 's/^(\s+)\.macos, \.ios => \{\},/$1.macos, .ios, .visionos => {},/; s/^(\s+)\.ios => \.shared,/$1.ios, .visionos => .shared,/; s/^(\s+)\.ios => \{$/$1.ios, .visionos => {/; s/builtin\.os\.tag == \.ios\)/(builtin.os.tag == .ios or builtin.os.tag == .visionos))/g' src/renderer/Metal.zig
perl -pi -e 's/builtin\.os\.tag == \.ios\)/(builtin.os.tag == .ios or builtin.os.tag == .visionos))/g' src/renderer/metal/IOSurfaceLayer.zig
perl -pi -e 's/builtin\.os\.tag != \.ios\)/(builtin.os.tag != .ios and builtin.os.tag != .visionos))/g' src/font/shaper/coretext.zig
perl -pi -e 's/^(\s+)\.ios => NullPty,/$1.ios, .visionos => NullPty,/' src/pty.zig
perl -pi -e 's/^(\s+)\.ios => true,/$1.ios, .visionos => true,/' src/os/desktop.zig
perl -pi -e 's/^(\s+)\.ios => null,/$1.ios, .visionos => null,/; s/^(\s+)\.ios => return path,/$1.ios, .visionos => return path,/' src/os/homedir.zig
perl -pi -e 's/^(\s+)\.ios => return error\.Unimplemented,/$1.ios, .visionos => return error.Unimplemented,/' src/os/open.zig
perl -pi -e 's/^(\s+)\.ios => error\{BufferTooSmall\},/$1.ios, .visionos => error{BufferTooSmall},/' src/config/theme.zig
perl -pi -e 's/^(\s+)\.ios, \.macos => 4, \/\/ mac/$1.ios, .visionos, .macos => 4, \/\/ mac/' src/input/keycodes.zig
perl -pi -e 's/^(\s+)\.ios, \.tvos, \.watchos => false,/$1.ios, .visionos, .tvos, .watchos => false,/' src/cli/tui.zig
perl -pi -e 's/^(\s+)\.freebsd, \.ios, \.macos => \{/$1.freebsd, .ios, .visionos, .macos => {/' src/Command.zig
perl -pi -e 's/^(\s+)\.ios => error\.XcodeiOSSDKNotFound,/$1.ios => error.XcodeiOSSDKNotFound,\n$1.visionos => error.XcodeVisionOSSDKNotFound,/' pkg/apple-sdk/build.zig
for f in src/renderer/Metal.zig src/renderer/metal/IOSurfaceLayer.zig src/font/shaper/coretext.zig src/pty.zig src/os/desktop.zig src/os/homedir.zig src/os/open.zig src/config/theme.zig src/input/keycodes.zig src/cli/tui.zig src/Command.zig pkg/apple-sdk/build.zig; do grep -q visionos "$f" || { echo "[!] $f: visionos arm missing"; exit 1; }; done
echo "[+] all visionos patches applied"
