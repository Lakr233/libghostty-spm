#!/bin/zsh

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[-] malformed project structure"
    exit 1
fi

SOURCE_DIR=${1:-}
PATCH_DIR=${2:-"$(pwd)/Patches/ghostty"}

if [ -z "$SOURCE_DIR" ]; then
    echo "Usage: $0 <source_dir> [patch_dir]"
    exit 1
fi

if [ ! -d "$SOURCE_DIR" ]; then
    echo "[-] ghostty source directory not found: $SOURCE_DIR"
    exit 1
fi

if [ ! -d "$PATCH_DIR" ]; then
    echo "[+] no patches directory found: $PATCH_DIR"
    exit 0
fi

apply_unified_patch() {
    local patch_file="$1"

    if [ -d "$SOURCE_DIR/.git" ] && command -v git >/dev/null 2>&1; then
        if git -C "$SOURCE_DIR" apply --check --reverse "$patch_file" >/dev/null 2>&1; then
            echo "[+] patch already applied: $(basename "$patch_file")"
            return
        fi

        if ! git -C "$SOURCE_DIR" apply --check "$patch_file" >/dev/null 2>&1; then
            echo "[-] failed to validate patch: $patch_file"
            exit 1
        fi

        git -C "$SOURCE_DIR" apply "$patch_file"
        echo "[+] applied patch: $(basename "$patch_file")"
        return
    fi

    if patch -p1 -R --dry-run -d "$SOURCE_DIR" < "$patch_file" >/dev/null 2>&1; then
        echo "[+] patch already applied: $(basename "$patch_file")"
        return
    fi

    if ! patch -p1 --dry-run -d "$SOURCE_DIR" < "$patch_file" >/dev/null 2>&1; then
        echo "[-] failed to validate patch: $patch_file"
        exit 1
    fi

    patch -p1 -d "$SOURCE_DIR" < "$patch_file" >/dev/null
    echo "[+] applied patch: $(basename "$patch_file")"
}

for patch_file in "$PATCH_DIR"/*; do
    [ -e "$patch_file" ] || continue

    case "$patch_file" in
    *.md)
        ;;
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
