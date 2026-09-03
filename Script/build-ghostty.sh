#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[!] repository root not found. Run this script from a libghostty-spm checkout."
    exit 1
fi

ROOT_DIR=$(pwd)
SOURCE_DIR=${1:-}
ZIG_TARGET=${2:-}
OUTPUT_DIR=${3:-}
ZIG_CPU=${ZIG_CPU:-}
ZIG_BUILD_EXTRA_ARGS=${ZIG_BUILD_EXTRA_ARGS:-}

if [ -z "$SOURCE_DIR" ] || [ -z "$ZIG_TARGET" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "Usage: $0 <source_dir> <zig_target> <output_dir>"
    exit 1
fi

if [ ! -d "$SOURCE_DIR" ]; then
    echo "[!] Ghostty source directory not found: $SOURCE_DIR"
    exit 1
fi

if [ ! -f "$SOURCE_DIR/include/ghostty.h" ]; then
    echo "[!] Ghostty header not found: $SOURCE_DIR/include/ghostty.h"
    exit 1
fi

if ! command -v zig >/dev/null 2>&1; then
    echo "[!] Zig not found. Install it and try again."
    exit 1
fi

CACHE_ROOT="${BUILD_CACHE_ROOT:-$ROOT_DIR/build/cache}"
GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$CACHE_ROOT/zig-global}"
LOCAL_CACHE_DIR="$CACHE_ROOT/$ZIG_TARGET/zig-local"
MODULE_CACHE_DIR="${CLANG_MODULE_CACHE_ROOT:-$CACHE_ROOT/clang-module-cache}/$ZIG_TARGET"

# A patch that has to fetch a Zig package (0017) shares the build's cache.
ZIG_GLOBAL_CACHE_DIR="$GLOBAL_CACHE_DIR" ./Script/apply-patches.sh "$SOURCE_DIR"

# visionOS is a target some Zigs only half know: 0.15.2's std left the
# `visionos` tag out of a few Darwin switches. When Patches/zig/ carries a
# std patch for the Zig on PATH, build those targets against a patched copy
# of the std (staged by prepare-zig-lib.sh) — the toolchain itself is left
# untouched, and every other target still uses it. With no patch for this
# Zig the stock std is used; a `@compileError("unimplemented")` there means
# the patch needs porting (see Patches/zig/README.md).
if [[ "$ZIG_TARGET" == *visionos* ]]; then
    if [ -f "$ROOT_DIR/Patches/zig/$(zig version)-visionos-std.patch" ]; then
        ZIG_LIB_DIR=$(./Script/prepare-zig-lib.sh "$CACHE_ROOT")
        export ZIG_LIB_DIR
        echo "[*] visionOS target: ZIG_LIB_DIR=$ZIG_LIB_DIR"
    else
        echo "[*] visionOS target: no std patch for Zig $(zig version), using the stock std"
    fi
fi

echo "[*] building Ghostty static library…"
echo "    target: $ZIG_TARGET"
echo "    source: $SOURCE_DIR"
echo "    output: $OUTPUT_DIR"

# Incremental by default. Zig's local and module caches are the whole point
# of having a cache -- wiping them on every invocation turns every build into
# a from-scratch compile, which for a Swift-only change upstream is pure waste.
#
# They are only invalidated when something that actually affects the compiled
# output changes: the Ghostty source revision, the patch set applied to it, or
# the zig version. Those are hashed into a stamp beside the cache; a mismatch
# (or no stamp -- first run, or a hand-cleared one) forces the clean rather
# than silently reusing a cache built from different inputs.
#
# Set GHOSTTY_FORCE_CLEAN=1 to clean regardless.
STAMP_FILE="$CACHE_ROOT/.build-inputs-stamp"
CURRENT_STAMP=$(
    {
        git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || echo "no-source-rev"
        zig version 2>/dev/null || echo "no-zig"
        echo "$ZIG_TARGET" "${ZIG_OPTIMIZE:-ReleaseFast}"
        # Patch *content*, not just names -- editing a patch in place must
        # invalidate, which a filename listing would miss.
        cat "$ROOT_DIR"/Patches/ghostty/* 2>/dev/null
    } | shasum -a 256 | cut -d' ' -f1
)

NEEDS_CLEAN=0
if [[ "${GHOSTTY_FORCE_CLEAN:-0}" == "1" ]]; then
    NEEDS_CLEAN=1
    echo "[*] GHOSTTY_FORCE_CLEAN=1 -- forcing a clean build"
elif [[ ! -f "$STAMP_FILE" ]] || [[ "$(<"$STAMP_FILE")" != "$CURRENT_STAMP" ]]; then
    NEEDS_CLEAN=1
    echo "[*] build inputs changed (source rev, patches, or zig) -- cleaning caches"
else
    echo "[*] build inputs unchanged -- reusing zig caches (incremental)"
fi

if (( NEEDS_CLEAN )); then
    rm -rf "$OUTPUT_DIR" "$LOCAL_CACHE_DIR" "$MODULE_CACHE_DIR" "$SOURCE_DIR/zig-out"
else
    # The output dir is cheap to rebuild and must not carry stale artifacts
    # from a previous run; the caches are what we are preserving.
    rm -rf "$OUTPUT_DIR"
fi

mkdir -p \
    "$OUTPUT_DIR/lib" \
    "$OUTPUT_DIR/include" \
    "$GLOBAL_CACHE_DIR" \
    "$LOCAL_CACHE_DIR" \
    "$MODULE_CACHE_DIR"

ZIG_BUILD_COMMAND=(
    zig build
    -Doptimize=${ZIG_OPTIMIZE:-ReleaseFast}
    -Dapp-runtime=none
    -Demit-exe=false
    -Demit-xcframework=false
    -Demit-macos-app=false
    -Demit-docs=false
    -Dsentry=false
    -Dcustom-shaders=false
    -Dinspector=false
    -Dtarget="$ZIG_TARGET"
)

if [ -n "$ZIG_CPU" ]; then
    ZIG_BUILD_COMMAND+=("-Dcpu=$ZIG_CPU")
fi

if [ -n "$ZIG_BUILD_EXTRA_ARGS" ]; then
    # shellcheck disable=SC2206
    EXTRA_ARGS=($ZIG_BUILD_EXTRA_ARGS)
    ZIG_BUILD_COMMAND+=("${EXTRA_ARGS[@]}")
fi

(
    cd "$SOURCE_DIR"
    env \
        CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
        ZIG_GLOBAL_CACHE_DIR="$GLOBAL_CACHE_DIR" \
        ZIG_LOCAL_CACHE_DIR="$LOCAL_CACHE_DIR" \
        "${ZIG_BUILD_COMMAND[@]}"
)

find_built_library() {
    local preferred_name="$1"
    find "$LOCAL_CACHE_DIR/o" -type f -name "$preferred_name" -print 2>/dev/null | sort | tail -n 1
}

LIBRARY_PATH=

if [ -f "$SOURCE_DIR/zig-out/lib/libghostty.a" ]; then
    LIBRARY_PATH="$SOURCE_DIR/zig-out/lib/libghostty.a"
fi

if [ -z "$LIBRARY_PATH" ]; then
    LIBRARY_PATH=$(find_built_library "libghostty-fat.a")
fi

if [ -z "$LIBRARY_PATH" ]; then
    LIBRARY_PATH=$(find_built_library "libghostty.a")
fi

if [ -z "$LIBRARY_PATH" ]; then
    echo "[!] failed to locate built libghostty archive in $LOCAL_CACHE_DIR"
    if [[ "$ZIG_TARGET" == *macos* || "$ZIG_TARGET" == *ios* || "$ZIG_TARGET" == *tvos* || "$ZIG_TARGET" == *visionos* || "$ZIG_TARGET" == *watchos* ]]; then
        echo "[!] upstream Ghostty does not build Darwin libghostty by default"
        echo "[!] retry with ZIG_BUILD_EXTRA_ARGS='-Demit-xcframework=true'"
    fi
    find "$LOCAL_CACHE_DIR" -maxdepth 3 -type f | sort | tail -n 50
    exit 1
fi

# Resolve std::__1::__libcpp_verbose_abort inside the archive: the Apple
# system libc++ only exports it since iOS 16.3 / macOS 13.3 / tvOS 16.3, and
# Zig's bundled libc++ headers reference it strongly (no availability markup),
# which crashes consumers at launch on older OS versions.
COMPAT_SOURCE="$ROOT_DIR/Script/support/libcxx-verbose-abort-compat.c"
COMPAT_OBJECT="$LOCAL_CACHE_DIR/libcxx-verbose-abort-compat.o"
zig cc -target "$ZIG_TARGET" -Os -fno-sanitize=undefined -c "$COMPAT_SOURCE" -o "$COMPAT_OBJECT"
xcrun libtool -static -no_warning_for_no_symbols \
    -o "$OUTPUT_DIR/lib/libghostty.a" \
    "$LIBRARY_PATH" \
    "$COMPAT_OBJECT"
echo "[*] added libc++ compatibility for older Apple OS versions"

mkdir -p "$OUTPUT_DIR/include/libghostty"
cp "$SOURCE_DIR/include/ghostty.h" "$OUTPUT_DIR/include/libghostty/ghostty.h"
cat >"$OUTPUT_DIR/include/libghostty/module.modulemap" <<'EOF'
module libghostty {
    umbrella header "ghostty.h"
    export *
}
EOF

echo "[*] built archive: $OUTPUT_DIR/lib/libghostty.a"

# Record the inputs this cache was built from (success path only).
printf "%s" "$CURRENT_STAMP" > "$STAMP_FILE"
