#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[*] malformed project structure"
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
    echo "[!] ghostty source directory not found: $SOURCE_DIR"
    exit 1
fi

if [ ! -f "$SOURCE_DIR/include/ghostty.h" ]; then
    echo "[!] ghostty header not found: $SOURCE_DIR/include/ghostty.h"
    exit 1
fi

if ! command -v zig >/dev/null 2>&1; then
    echo "[!] zig not found"
    exit 1
fi

./Script/apply-patches.sh "$SOURCE_DIR"

CACHE_ROOT="${BUILD_CACHE_ROOT:-$ROOT_DIR/build/cache}"
GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$CACHE_ROOT/zig-global}"
LOCAL_CACHE_DIR="$CACHE_ROOT/$ZIG_TARGET/zig-local"
MODULE_CACHE_DIR="${CLANG_MODULE_CACHE_ROOT:-$CACHE_ROOT/clang-module-cache}/$ZIG_TARGET"

echo "[*] building ghostty static library"
echo "    target: $ZIG_TARGET"
echo "    source: $SOURCE_DIR"
echo "    output: $OUTPUT_DIR"

rm -rf "$OUTPUT_DIR" "$LOCAL_CACHE_DIR" "$MODULE_CACHE_DIR"
mkdir -p \
    "$OUTPUT_DIR/lib" \
    "$OUTPUT_DIR/include" \
    "$GLOBAL_CACHE_DIR" \
    "$LOCAL_CACHE_DIR" \
    "$MODULE_CACHE_DIR"

rm -rf "$SOURCE_DIR/zig-out"

ZIG_BUILD_COMMAND=(
    zig build
    -Doptimize=ReleaseFast
    -Dapp-runtime=none
    -Demit-exe=false
    -Demit-xcframework=false
    -Demit-macos-app=false
    -Demit-docs=false
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
        echo "[!] note: upstream Ghostty does not install Darwin libghostty for app-runtime=none unless extra build wiring is triggered"
        echo "[!] try again with ZIG_BUILD_EXTRA_ARGS='-Demit-xcframework=true' if you want to force Darwin libghostty build graph execution"
    fi
    find "$LOCAL_CACHE_DIR" -maxdepth 3 -type f | sort | tail -n 50
    exit 1
fi

cp "$LIBRARY_PATH" "$OUTPUT_DIR/lib/libghostty.a"
cp "$SOURCE_DIR/include/ghostty.h" "$OUTPUT_DIR/include/ghostty.h"
cat >"$OUTPUT_DIR/include/module.modulemap" <<'EOF'
module libghostty {
    umbrella header "ghostty.h"
    export *
}
EOF

echo "[*] built archive: $LIBRARY_PATH"
