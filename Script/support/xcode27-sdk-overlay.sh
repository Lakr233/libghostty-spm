#!/bin/zsh

# Local builds on a Mac with Xcode 27 (macOS 27 / 26.5 SDK): Zig 0.15.2 cannot
# link its own build runner there. The SDK's libSystem.tbd lists arm64e-macos
# but no arm64-macos target, Zig's tapi reader takes that literally, and
# `zig build` dies with `undefined symbol: __availability_version_check`
# before Ghostty is even configured. CI (macos-15 / Xcode 16) is unaffected.
#
# This stages an overlay SDK — every entry a symlink into the real one except
# usr/lib, a copy whose .tbd `targets:` lines also name arm64-macos — and an
# `xcrun` shim that answers `--sdk macosx --show-sdk-path` with it. Put the
# shim directory first on PATH for the build:
#
#   eval "$(./Script/support/xcode27-sdk-overlay.sh)"
#   ./build.sh --platforms visionos --source ../ghostty --skip-tests
#
# Nothing under /Applications is touched.

set -euo pipefail
setopt nullglob

cd "$(dirname "$0")/../.."

if [ ! -f .root ]; then
    echo "[-] repository root not found. Run this script from a libghostty-spm checkout." >&2
    exit 1
fi

REAL_SDK=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
OVERLAY_ROOT="$(pwd)/build/xcode-sdk-overlay"
OVERLAY_SDK="$OVERLAY_ROOT/$(basename "$REAL_SDK")"
SHIM_DIR="$OVERLAY_ROOT/bin"

# The umbrella's own `targets:` line is the one Zig's tapi reader consults.
if grep -m1 '^targets:' "$REAL_SDK/usr/lib/libSystem.tbd" 2>/dev/null | grep -q 'arm64-macos'; then
    echo "[+] $REAL_SDK already targets arm64-macos, no overlay needed" >&2
    exit 0
fi

if [ ! -f "$SHIM_DIR/xcrun" ] || [ ! -f "$OVERLAY_SDK/usr/lib/libSystem.tbd" ]; then
    rm -rf "$OVERLAY_ROOT"
    mkdir -p "$OVERLAY_SDK/usr" "$SHIM_DIR"
    for entry in "$REAL_SDK"/* "$REAL_SDK"/.[!.]*; do
        [ -e "$entry" ] || continue
        [ "$(basename "$entry")" = "usr" ] && continue
        ln -s "$entry" "$OVERLAY_SDK/$(basename "$entry")"
    done
    for entry in "$REAL_SDK"/usr/*; do
        [ "$(basename "$entry")" = "lib" ] && continue
        ln -s "$entry" "$OVERLAY_SDK/usr/$(basename "$entry")"
    done
    cp -R "$REAL_SDK/usr/lib" "$OVERLAY_SDK/usr/lib"
    find "$OVERLAY_SDK/usr/lib" -name '*.tbd' -type f -exec perl -pi -e '
        if (/^\s*targets:/ || /^\s*-\s+targets:/) {
            s/arm64e-macos(?![-\w])/arm64e-macos, arm64-macos/ unless /arm64-macos(?![-\w])/;
            s/arm64e-maccatalyst(?![-\w])/arm64e-maccatalyst, arm64-maccatalyst/ unless /arm64-maccatalyst(?![-\w])/;
        }' {} +
    cat >"$SHIM_DIR/xcrun" <<SHIM
#!/bin/bash
if [ "\$1" = "--sdk" ] && [ "\$2" = "macosx" ] && [ "\$3" = "--show-sdk-path" ]; then
    echo "$OVERLAY_SDK"
    exit 0
fi
exec /usr/bin/xcrun "\$@"
SHIM
    chmod +x "$SHIM_DIR/xcrun"
    echo "[+] staged SDK overlay: $OVERLAY_SDK" >&2
fi

echo "export PATH=\"$SHIM_DIR:\$PATH\""
