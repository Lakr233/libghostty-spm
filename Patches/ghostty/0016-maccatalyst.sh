#!/bin/bash
# Mac Catalyst: Zig 0.16 made it its own OS tag (`aarch64-maccatalyst`) where
# 0.15 spelled it `aarch64-ios-macabi` — os `.ios`, abi `.macabi` — so every
# `.ios` switch arm that used to cover it no longer does. Give `.maccatalyst`
# the iOS arm everywhere 0012 gives `.visionos` one, plus the three build-side
# switches that used to read the abi. Runs after 0012 (name order), so the
# `.ios, .visionos` pairs it extends are already there.
set -euo pipefail
SOURCE_DIR=${1:?usage: $0 <ghostty_source_dir>}
cd "$SOURCE_DIR"
if grep -q 'LIBGHOSTTY_SPM_MACCATALYST_PATCH' src/build/MetallibStep.zig; then echo "[+] maccatalyst patch already applied"; exit 0; fi

# 1. MetallibStep: the shaders are compiled as for a device iOS build, which
#    is what the 0.15-era `.ios` + `.macabi` fall-through produced and shipped.
perl -0pi -e 's/(        \/\/ LIBGHOSTTY_SPM_VISIONOS_PATCH\n)/        .maccatalyst => "iphoneos", \/\/ LIBGHOSTTY_SPM_MACCATALYST_PATCH\n$1/' src/build/MetallibStep.zig
perl -pi -e 's/^(\s+)\.ios => "11\.0",$/$1.ios => "11.0",\n$1.maccatalyst => "15.0",/' src/build/MetallibStep.zig
perl -0pi -e 's/(        \.visionos => switch \(opts\.target\.result\.abi\) \{\n            \.simulator => b\.fmt\("-mtargetos=xros)/        .maccatalyst => b.fmt("-mios-version-min={s}", .{min_version}),\n$1/' src/build/MetallibStep.zig
grep -q 'LIBGHOSTTY_SPM_MACCATALYST_PATCH' src/build/MetallibStep.zig && grep -q '\.maccatalyst => "15\.0"' src/build/MetallibStep.zig && grep -q '\.maccatalyst => b\.fmt("-mios-version-min' src/build/MetallibStep.zig || { echo "[!] MetallibStep.zig maccatalyst patch failed"; exit 1; }
echo "[+] patched MetallibStep.zig: maccatalyst"

# 2. Config.zig: deployment floor (Catalyst versions follow iOS; 15.0 like
#    the package manifest) and the Apple-platform feature arms.
perl -0pi -e 's/(        \.ios => \.\{ \.semver = \.\{\n            \.major = 15,\n            \.minor = 0,\n            \.patch = 0,\n        \} \},\n)/$1        .maccatalyst => .{ .semver = .{\n            .major = 15,\n            .minor = 0,\n            .patch = 0,\n        } },\n/' src/build/Config.zig
grep -q '\.maccatalyst => \.{ \.semver' src/build/Config.zig || { echo "[!] Config.zig osVersionMin maccatalyst arm failed (0004 must have added the .ios arm first)"; exit 1; }
echo "[+] patched Config.zig: maccatalyst"

# 3. Every `.ios, .visionos` arm and comptime os check takes `.maccatalyst` too.
for f in \
    src/build/Config.zig \
    src/Command.zig \
    src/pty.zig \
    src/renderer/Metal.zig \
    src/renderer/metal/IOSurfaceLayer.zig \
    src/font/shaper/coretext.zig \
    src/config/theme.zig \
    src/input/keycodes.zig \
    src/cli/tui.zig \
    src/os/open.zig \
    src/os/desktop.zig \
    src/os/homedir.zig
do
    perl -pi -e 's/\.ios, \.visionos(?=[ ,])/.ios, .visionos, .maccatalyst/g; s/\(builtin\.os\.tag == \.ios or builtin\.os\.tag == \.visionos\)/(builtin.os.tag == .ios or builtin.os.tag == .visionos or builtin.os.tag == .maccatalyst)/g; s/\(builtin\.os\.tag != \.ios and builtin\.os\.tag != \.visionos\)/(builtin.os.tag != .ios and builtin.os.tag != .visionos and builtin.os.tag != .maccatalyst)/g' "$f"
    grep -q 'maccatalyst' "$f" || { echo "[!] no maccatalyst arm landed in $f; upstream changed, update this patch"; exit 1; }
done
echo "[+] patched runtime switches: maccatalyst takes the iOS arm"

# 4. apple-sdk native link: macOS SDK, `-macabi` triple.
perl -pi -e 's/^(\s+)\.macos, \.ios => true,$/$1.macos, .ios, .maccatalyst => true,/; s/^(\s+)\.macos => "macosx",$/$1.macos, .maccatalyst => "macosx",/' pkg/apple-sdk/native_link.zig
perl -0pi -e 's/(        \.macos => b\.fmt\(\n            "\{s\}-apple-macosx\{f\}",\n            \.\{ arch, minimum\.semver \},\n        \),\n)/$1        .maccatalyst => b.fmt(\n            "{s}-apple-ios{f}-macabi",\n            .{ arch, minimum.semver },\n        ),\n/' pkg/apple-sdk/native_link.zig
grep -q 'apple-ios{f}-macabi' pkg/apple-sdk/native_link.zig || { echo "[!] native_link.zig maccatalyst patch failed"; exit 1; }
echo "[+] patched native_link.zig: maccatalyst"

echo "[+] all maccatalyst patches applied"
