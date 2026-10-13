#!/bin/zsh
# Compiles Localization/Localizable.xcstrings into the .lproj string tables
# GhosttyTerminal ships.
#
# The package ships the compiled tables, not the catalog: SwiftPM compiles an
# .xcstrings resource with xcstringstool, which only Xcode.app carries, so a
# catalog in the target fails every build on the Command Line Tools (#81).
# Edit the catalog, run this, commit both. `--check` regenerates into a
# temporary directory and fails when the committed tables differ (pr.yml).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .root ]] || { echo "[-] run from the repository"; exit 1; }

CATALOG="Localization/Localizable.xcstrings"
OUTPUT_DIR="Sources/GhosttyTerminal/Resources/Localization"

if [[ "${1:-}" == "--check" ]]; then
    TEMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TEMP_DIR"' EXIT
    xcrun xcstringstool compile "$CATALOG" --output-directory "$TEMP_DIR"
    if ! diff -r "$TEMP_DIR" "$OUTPUT_DIR"; then
        echo "[-] $OUTPUT_DIR is out of date; run Script/generate-localizations.sh"
        exit 1
    fi
    echo "[+] string tables match $CATALOG"
    exit 0
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
xcrun xcstringstool compile "$CATALOG" --output-directory "$OUTPUT_DIR"
echo "[+] compiled $(ls -d "$OUTPUT_DIR"/*.lproj | wc -l | tr -d ' ') languages into $OUTPUT_DIR"
