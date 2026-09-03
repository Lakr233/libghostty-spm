#!/bin/zsh

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[-] repository root not found. Run this script from a libghostty-spm checkout."
    exit 1
fi

SOURCE_DIR=${1:-}
PATCH_DIR=${2:-"$(pwd)/Patches/ghostty"}

if [ -z "$SOURCE_DIR" ]; then
    echo "Usage: $0 <source_dir> [patch_dir]"
    exit 1
fi

if [ ! -d "$SOURCE_DIR" ]; then
    echo "[-] Ghostty source directory not found: $SOURCE_DIR"
    exit 1
fi

if [ ! -d "$PATCH_DIR" ]; then
    echo "[+] no patches directory found: $PATCH_DIR"
    exit 0
fi

if ! command -v git >/dev/null 2>&1; then
    echo "[-] git not found. The patch stack carries git binary patches that patch(1) cannot apply."
    exit 1
fi

apply_unified_patch() {
    local patch_file="$1"

    if git -C "$SOURCE_DIR" apply --check --reverse "$patch_file" >/dev/null 2>&1; then
        echo "[+] patch already applied: $(basename "$patch_file")"
        return
    fi

    if git -C "$SOURCE_DIR" apply --check "$patch_file" >/dev/null 2>&1; then
        git -C "$SOURCE_DIR" apply "$patch_file"
        echo "[+] applied patch: $(basename "$patch_file")"
        return
    fi

    # Context drifted. A patch with `index` lines names the blobs it was
    # cut against, and upstream's clone has them, so git can merge the hunks
    # three-way instead of matching context byte for byte; a hunk that
    # really conflicts leaves markers and fails here.
    if git -C "$SOURCE_DIR" apply --3way "$patch_file" >/dev/null 2>&1; then
        echo "[+] applied patch with a 3-way merge (context drifted; regenerate it): $(basename "$patch_file")"
        return
    fi

    echo "[-] failed to validate patch: $patch_file"
    exit 1
}

modern_host_io=false
if grep -q "ghostty_surface_foreground_pid" "$SOURCE_DIR/include/ghostty.h"; then
    modern_host_io=true
fi

host_io_applied=false
if grep -q "GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED" "$SOURCE_DIR/include/ghostty.h"; then
    host_io_applied=true
fi

# Upstream renamed the global-state env accessors sometime after 35e1a01
# (internal_os.getEnvMap/std.process.EnvMap/global_state.resources_dir ->
# global.environMap()/std.process.Environ.Map/global.resourcesDir()). The
# host-managed-io patch's Surface.zig hunk touches that exact code, so it
# needs a context-updated variant once the rename has landed.
global_env_refactored=false
if grep -q "pub fn environMap" "$SOURCE_DIR/src/global.zig" 2>/dev/null; then
    global_env_refactored=true
fi

# Zig 0.16 moved addCSourceFile/linkSystemLibrary/linkLibrary/linkLibC off
# std.Build.Step.Compile onto its root_module, and dropped linkSystemLibrary2
# in favor of linkSystemLibrary. GhosttyFrameData.zig's framegen build step
# uses these, so the prebuilt-framedata patch needs a context-updated variant
# once the source has moved. Keyed off the code the patch touches, not the
# Zig version string, so 0.17 does not fall back to the 0.15 variant.
zig_build_api_v2=true
if grep -q "linkSystemLibrary2" "$SOURCE_DIR/src/build/GhosttyFrameData.zig" 2>/dev/null; then
    zig_build_api_v2=false
fi

for patch_file in "$PATCH_DIR"/*; do
    [ -e "$patch_file" ] || continue

    patch_name=$(basename "$patch_file")
    case "$patch_name" in
        0002-host-managed-io.patch)
            [ "$modern_host_io" = false ] || continue
            if [ "$host_io_applied" = true ]; then
                echo "[+] patch already applied: $patch_name"
                continue
            fi
            apply_unified_patch "$patch_file"
            ;;
        0002-host-managed-io-modern.patch)
            [ "$modern_host_io" = true ] || continue
            [ "$global_env_refactored" = false ] || continue
            if [ "$host_io_applied" = true ]; then
                echo "[+] patch already applied: $patch_name"
                continue
            fi
            apply_unified_patch "$patch_file"
            ;;
        0002-host-managed-io-modern-v2.patch)
            [ "$modern_host_io" = true ] || continue
            [ "$global_env_refactored" = true ] || continue
            if [ "$host_io_applied" = true ]; then
                echo "[+] patch already applied: $patch_name"
                continue
            fi
            apply_unified_patch "$patch_file"
            ;;
        0003-prebuilt-framedata.patch)
            [ "$zig_build_api_v2" = false ] || continue
            apply_unified_patch "$patch_file"
            ;;
        0003-prebuilt-framedata-v2.patch)
            [ "$zig_build_api_v2" = true ] || continue
            apply_unified_patch "$patch_file"
            ;;
        0005-ios-metal-rendering.sh)
            [ "$global_env_refactored" = false ] || continue
            "$patch_file" "$SOURCE_DIR"
            ;;
        0005-ios-metal-rendering-v2.sh)
            [ "$global_env_refactored" = true ] || continue
            "$patch_file" "$SOURCE_DIR"
            ;;
        0006-disable-custom-shaders.sh)
            [ "$zig_build_api_v2" = false ] || continue
            "$patch_file" "$SOURCE_DIR"
            ;;
        0006-disable-custom-shaders-v2.sh)
            [ "$zig_build_api_v2" = true ] || continue
            "$patch_file" "$SOURCE_DIR"
            ;;
        *.md) ;;
        *.patch)
            apply_unified_patch "$patch_file"
            ;;
        *.sh)
            "$patch_file" "$SOURCE_DIR"
            ;;
        *)
            echo "[-] unsupported patch file: $patch_file"
            exit 1
            ;;
    esac
done
