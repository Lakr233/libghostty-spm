#!/bin/bash
# Zig packages Ghostty pulls in that predate one of our Apple targets:
#
# - libxev (the event loop) picks its backend by OS tag and has no arm for
#   Zig 0.16's `.maccatalyst`, so a Catalyst build stops at "no default
#   backend for this target".
# - aro (the C frontend behind 0.16's translate-c) writes the Apple
#   `__ENVIRONMENT_*_VERSION_MIN_REQUIRED__` macro from a switch with no
#   `.visionos` arm and aborts on `unreachable`.
#
# Zig 0.16 unpacks packages under <source>/zig-pkg/<name-version-hash>/
# (gitignored upstream), so they are patched there: fetched first when the
# tree is fresh, edited in place after. A later build never re-unpacks a
# package that is already there, so the edits survive.
set -euo pipefail
SOURCE_DIR=${1:?usage: $0 <ghostty_source_dir>}
cd "$SOURCE_DIR"

if ! ls -d zig-pkg/libxev-* zig-pkg/aro-* >/dev/null 2>&1; then
    # The same -D set build-ghostty.sh builds with, so the lazy dependencies
    # are part of what gets fetched. Cache dirs come from the environment
    # when the caller exported them.
    zig build --fetch \
        -Dapp-runtime=none \
        -Demit-exe=false \
        -Demit-xcframework=false \
        -Dsentry=false \
        -Dcustom-shaders=false \
        -Dinspector=false \
        -Dtarget=aarch64-maccatalyst >/dev/null
fi

for dir in zig-pkg/libxev-*; do
    [ -d "$dir" ] || { echo "[!] no libxev package under zig-pkg/ after fetch"; exit 1; }
    if grep -q '\.maccatalyst' "$dir/src/backend.zig"; then
        echo "[+] libxev maccatalyst patch already applied: $(basename "$dir")"
        continue
    fi
    perl -pi -e 's/\.ios, \.macos, \.visionos =>/.ios, .maccatalyst, .macos, .visionos =>/g' \
        "$dir/src/backend.zig" "$dir/src/backend/kqueue.zig"
    perl -pi -e 's/\.macos, \.ios, \.watchos, \.tvos, \.visionos =>/.macos, .ios, .maccatalyst, .watchos, .tvos, .visionos =>/g' \
        "$dir/src/posix.zig"
    grep -q '\.maccatalyst' "$dir/src/backend.zig" && grep -q '\.maccatalyst' "$dir/src/backend/kqueue.zig" || {
        echo "[!] libxev maccatalyst patch failed in $dir; libxev changed, update this patch"
        exit 1
    }
    echo "[+] patched libxev: maccatalyst takes the Darwin arms ($(basename "$dir"))"
done

for dir in zig-pkg/aro-*; do
    [ -d "$dir" ] || { echo "[!] no aro package under zig-pkg/ after fetch"; exit 1; }
    f="$dir/src/aro/Compilation.zig"
    if grep -q '\.visionos => "__ENVIRONMENT_OS_VERSION_MIN_REQUIRED__"' "$f"; then
        echo "[+] aro visionos patch already applied: $(basename "$dir")"
        continue
    fi
    perl -pi -e 's/^(\s+)\.macos => "__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__",$/$1.macos => "__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__",\n$1.visionos => "__ENVIRONMENT_OS_VERSION_MIN_REQUIRED__",/' "$f"
    grep -q '\.visionos => "__ENVIRONMENT_OS_VERSION_MIN_REQUIRED__"' "$f" || {
        echo "[!] aro visionos patch failed in $dir; aro changed, update this patch"
        exit 1
    }
    echo "[+] patched aro: visionos version macro ($(basename "$dir"))"
done

echo "[+] all zig-pkg Apple target patches applied"
