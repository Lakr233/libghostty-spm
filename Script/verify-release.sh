#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[!] repository root not found. Run this script from a libghostty-spm checkout."
    exit 1
fi

PACKAGE_TAG=${1:-}
STORAGE_TAG=${2:-}
ASSET_NAME=${3:-GhosttyKit.xcframework.zip}

if [ -z "$PACKAGE_TAG" ] || [ -z "$STORAGE_TAG" ]; then
    echo "Usage: $0 <package_tag> <storage_tag> [asset_name]"
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "[!] GitHub CLI not found. Install it and try again."
    exit 1
fi

git fetch --tags origin

# The package tag and the upstream.* tag are cut at different times on
# purpose (an XCFramework build vs a Swift-only release), so they need not
# share a commit — the binding verified here is the manifest's URL/checksum
# against the asset the storage tag actually serves.
manifest=$(git show "$PACKAGE_TAG:Package.swift")
download_url=$(printf '%s\n' "$manifest" | python3 -c 'import re, sys; text=sys.stdin.read(); urls=re.findall(r"url:\s*\"([^\"]+)\"", text); matches=[url for url in urls if "/releases/download/" in url and url.endswith("/GhosttyKit.xcframework.zip")]; print(matches[0] if matches else "", end="")')
checksum=$(printf '%s\n' "$manifest" | python3 -c 'import re, sys; text=sys.stdin.read(); match=re.search(r"checksum:\s*\"([0-9a-f]{64})\"", text); print(match.group(1) if match else "", end="")')

if [ -z "$download_url" ] || [ -z "$checksum" ]; then
    echo "[!] failed to read binary target URL/checksum from Package.swift at $PACKAGE_TAG"
    exit 1
fi

expected_url="https://github.com/Lakr233/libghostty-spm/releases/download/$STORAGE_TAG/$ASSET_NAME"
if [ "$download_url" != "$expected_url" ]; then
    echo "[!] Package.swift download URL does not match storage release"
    echo "    expected: $expected_url"
    echo "    actual:   $download_url"
    exit 1
fi

asset_digest=$(
    gh release view "$STORAGE_TAG" \
        --json assets \
        --jq ".assets[] | select(.name == \"$ASSET_NAME\") | .digest"
)

if [ -z "$asset_digest" ]; then
    echo "[!] release asset not found: $STORAGE_TAG/$ASSET_NAME"
    exit 1
fi

if [ "$asset_digest" != "sha256:$checksum" ]; then
    echo "[!] release asset digest does not match Package.swift checksum"
    echo "    asset:    $asset_digest"
    echo "    manifest: sha256:$checksum"
    exit 1
fi

echo "[*] release verified: $PACKAGE_TAG -> $STORAGE_TAG/$ASSET_NAME"
