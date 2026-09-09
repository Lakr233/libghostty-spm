#!/bin/bash
# libxev (the event loop Ghostty pulls in) picks its backend by OS tag and
# has no arm for Zig 0.16's `.maccatalyst`, so a Catalyst build stops at
# "no default backend for this target".
#
# aro (the C frontend behind 0.16's translate-c) needs the Apple
# `TARGET_OS_*` conditionals to match what the SDK's own
# TargetConditionals.h would define. It gets two of them wrong:
# `TARGET_OS_IPHONE` covers only `.ios`/`.tvos`/`.watchos`, and
# `TARGET_OS_IOS` only `.ios`. Apple sets TARGET_OS_IPHONE=1 for Catalyst
# *and* visionOS, and TARGET_OS_IOS=1 for Catalyst. With them 0,
# CoreFoundation never declares CFTypeRef / CFAttributedStringRef, so every
# CoreText prototype fails to parse and aro panics on the invalid type
# (`TypeStore.zig` `.invalid => unreachable`) — the maccatalyst, xros and
# xrsimulator targets all died at CTLine.h:140 that way, while macos, ios
# and the ios simulator built fine.
#
# aro's `__ENVIRONMENT_*_VERSION_MIN_REQUIRED__` switch used to need the
# same kind of help for `.visionos`; aro f97cdfc3, pulled in by translate-c
# 4e879eb8 which the pinned Ghostty carries, has its own arm now, so that
# half is gone. Restore it from history if a pin ever moves back. Both
# edits below are anchored to the macro name and skipped when the arm is
# already there, so an aro that grows its own does not get a duplicate —
# a bare `.visionos` insert is exactly how the previous version of this
# patch produced `duplicate switch value` on all ten targets.
#
# Zig 0.16 unpacks packages under <source>/zig-pkg/<name-version-hash>/
# (gitignored upstream), so they are patched there: fetched first when the
# tree is fresh, edited in place after. A later build never re-unpacks a
# package that is already there, so the edits survive.
set -euo pipefail
SOURCE_DIR=${1:?usage: $0 <ghostty_source_dir>}
cd "$SOURCE_DIR"

if ! ls -d zig-pkg/libxev-* >/dev/null 2>&1 || ! ls -d zig-pkg/aro-* >/dev/null 2>&1; then
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

for dir in zig-pkg/aro-*; do
    [ -d "$dir" ] || { echo "[!] no aro package under zig-pkg/ after fetch"; exit 1; }
    comp="$dir/src/aro/Compilation.zig"

    # TARGET_OS_IPHONE: Catalyst and visionOS are iPhone-family to Apple.
    if perl -0ne 'exit(/"TARGET_OS_IPHONE",\s*\n\s*switch \(target\.os\.tag\) \{\s*\n\s*[^\n]*\.maccatalyst/ ? 0 : 1)' "$comp"; then
        echo "[+] aro TARGET_OS_IPHONE already covers maccatalyst: $(basename "$dir")"
    else
        perl -0pi -e 's/("TARGET_OS_IPHONE",\s*\n\s*switch \(target\.os\.tag\) \{\s*\n\s*)\.ios, \.tvos, \.watchos =>/${1}.ios, .maccatalyst, .tvos, .visionos, .watchos =>/' "$comp"
        perl -0ne 'exit(/"TARGET_OS_IPHONE",\s*\n\s*switch \(target\.os\.tag\) \{\s*\n\s*\.ios, \.maccatalyst, \.tvos, \.visionos, \.watchos =>/ ? 0 : 1)' "$comp" || {
            echo "[!] aro TARGET_OS_IPHONE patch failed in $dir; aro changed, update this patch"
            exit 1
        }
        echo "[+] patched aro: TARGET_OS_IPHONE covers maccatalyst and visionos ($(basename "$dir"))"
    fi

    # TARGET_OS_IOS: Apple sets it for Catalyst too (but not for visionOS).
    if grep -q '"TARGET_OS_IOS", target\.os\.tag == \.ios or target\.os\.tag == \.maccatalyst' "$comp"; then
        echo "[+] aro TARGET_OS_IOS already covers maccatalyst: $(basename "$dir")"
        continue
    fi
    perl -pi -e 's/("TARGET_OS_IOS", target\.os\.tag == \.ios)\)/${1} or target.os.tag == .maccatalyst)/' "$comp"
    grep -q '"TARGET_OS_IOS", target\.os\.tag == \.ios or target\.os\.tag == \.maccatalyst' "$comp" || {
        echo "[!] aro TARGET_OS_IOS patch failed in $dir; aro changed, update this patch"
        exit 1
    }
    echo "[+] patched aro: TARGET_OS_IOS covers maccatalyst ($(basename "$dir"))"
done

echo "[+] all zig-pkg Apple target patches applied"
