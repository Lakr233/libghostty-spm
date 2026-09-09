#!/bin/bash
# libxev (the event loop Ghostty pulls in) picks its backend by OS tag and
# has no arm for Zig 0.16's `.maccatalyst`, so a Catalyst build stops at
# "no default backend for this target".
#
# aro (the C frontend behind 0.16's translate-c) used to need the same kind
# of help — its Apple `__ENVIRONMENT_*_VERSION_MIN_REQUIRED__` switch had no
# `.visionos` arm and hit `unreachable`. aro f97cdfc3, pulled in by
# translate-c 4e879eb8 which the pinned Ghostty carries, has its own arm now
# (a labelled break, since visionOS has no platform-specific define), so
# that half is gone. Restore it from history if a pin ever moves back.
#
# Zig 0.16 unpacks packages under <source>/zig-pkg/<name-version-hash>/
# (gitignored upstream), so they are patched there: fetched first when the
# tree is fresh, edited in place after. A later build never re-unpacks a
# package that is already there, so the edits survive.
set -euo pipefail
SOURCE_DIR=${1:?usage: $0 <ghostty_source_dir>}
cd "$SOURCE_DIR"

if ! ls -d zig-pkg/libxev-* >/dev/null 2>&1; then
    # libxev is a lazy dependency, and the default `--fetch` (`needed`)
    # unpacks only the eager ones — on a fresh clone it returned in under a
    # second without it. `all` fetches the whole tree (about 110 MB, a
    # minute on CI). Cache dirs come from the environment when the caller
    # exported them.
    zig build --fetch=all >/dev/null
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

echo "[+] all zig-pkg Apple target patches applied"
