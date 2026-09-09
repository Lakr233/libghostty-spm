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

# Upstream carries the host-managed IO backend itself once the enum reaches
# its header, and 0002 is then a no-op rather than a conflict.
host_io_applied=false
if grep -q "GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED" "$SOURCE_DIR/include/ghostty.h"; then
    host_io_applied=true
fi

for patch_file in "$PATCH_DIR"/*; do
    [ -e "$patch_file" ] || continue

    patch_name=$(basename "$patch_file")
    case "$patch_name" in
        0002-host-managed-io.patch)
            if [ "$host_io_applied" = true ]; then
                echo "[+] patch already applied: $patch_name"
                continue
            fi
            apply_unified_patch "$patch_file"
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
