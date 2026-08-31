#!/bin/bash

# Stage a patched copy of the Zig standard library for a target the pinned
# Zig does not fully know. Zig 0.15.2 knows the `visionos` OS tag but leaves
# it out of the Darwin arms of a handful of `native_os` switches (fs, Dir
# iteration, Child rusage, the DWARF unwinder), so a `-Dtarget=*-visionos`
# build stops at `@compileError("unimplemented")`. The patch under
# Patches/zig/ adds the tag to those arms and nothing else.
#
# The toolchain itself is never edited: the lib directory is copied under
# the build cache, the patch is applied there, and the copy's path is
# printed for the caller to export as ZIG_LIB_DIR (honoured by every zig
# subcommand, `zig build` and `zig cc` included). Idempotent — a copy whose
# patch already reverse-applies is reused as is.

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[!] repository root not found. Run this script from a libghostty-spm checkout." >&2
    exit 1
fi

CACHE_ROOT=${1:-}
PATCH_NAME=${2:-visionos-std}

if [ -z "$CACHE_ROOT" ]; then
    echo "Usage: $0 <cache_root> [patch_name]" >&2
    exit 1
fi

if ! command -v zig >/dev/null 2>&1; then
    echo "[!] Zig not found. Install it and try again." >&2
    exit 1
fi

ZIG_VERSION=$(zig version)
PATCH_FILE="Patches/zig/$ZIG_VERSION-$PATCH_NAME.patch"

if [ ! -f "$PATCH_FILE" ]; then
    echo "[!] no std patch for Zig $ZIG_VERSION: $PATCH_FILE" >&2
    echo "[!] port Patches/zig/*-$PATCH_NAME.patch to this Zig or pin the version CI uses" >&2
    exit 1
fi

# `zig env` prints ZON since 0.15 (JSON before); read the field either way.
SOURCE_LIB_DIR=$(zig env | sed -n -E 's/^ *"?\.?lib_dir"? *[=:] *"([^"]+)".*$/\1/p' | head -n 1)
if [ -z "$SOURCE_LIB_DIR" ] || [ ! -d "$SOURCE_LIB_DIR/std" ]; then
    echo "[!] could not locate the Zig lib directory (zig env lib_dir=$SOURCE_LIB_DIR)" >&2
    exit 1
fi

STAGED_LIB_DIR="$CACHE_ROOT/zig-lib/$ZIG_VERSION-$PATCH_NAME"
STAMP="$STAGED_LIB_DIR/.libghostty-spm-patch"

if [ -f "$STAMP" ] && cmp -s "$STAMP" "$PATCH_FILE"; then
    echo "[*] patched Zig lib already staged: $STAGED_LIB_DIR" >&2
    echo "$STAGED_LIB_DIR"
    exit 0
fi

rm -rf "$STAGED_LIB_DIR"
mkdir -p "$(dirname "$STAGED_LIB_DIR")"
cp -R "$SOURCE_LIB_DIR" "$STAGED_LIB_DIR"

if ! patch -p1 --dry-run -d "$STAGED_LIB_DIR" <"$PATCH_FILE" >/dev/null 2>&1; then
    echo "[!] failed to validate Zig std patch against $SOURCE_LIB_DIR: $PATCH_FILE" >&2
    rm -rf "$STAGED_LIB_DIR"
    exit 1
fi
patch -p1 -d "$STAGED_LIB_DIR" <"$PATCH_FILE" >/dev/null
cp "$PATCH_FILE" "$STAMP"

echo "[*] staged patched Zig $ZIG_VERSION lib: $STAGED_LIB_DIR" >&2
echo "$STAGED_LIB_DIR"
