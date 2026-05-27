#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[*] malformed project structure"
    exit 1
fi

RELEASE_TAG=${1:-}
STORAGE_RELEASE_TAG=${2:-}
ASSET_NAME=${3:-GhosttyKit.xcframework.zip}

if [ -z "$RELEASE_TAG" ] || [ -z "$STORAGE_RELEASE_TAG" ]; then
    echo "Usage: $0 <release_tag> <storage_release_tag> [asset_name]"
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "[!] gh not found"
    exit 1
fi

git fetch --tags origin

release_commit=$(git rev-parse "refs/tags/$RELEASE_TAG")
storage_commit=$(git rev-parse "refs/tags/$STORAGE_RELEASE_TAG")

if [ "$release_commit" != "$storage_commit" ]; then
    echo "[!] release tag and storage tag point at different commits"
    echo "    $RELEASE_TAG: $release_commit"
    echo "    $STORAGE_RELEASE_TAG: $storage_commit"
    exit 1
fi

manifest=$(git show "$RELEASE_TAG:Package.swift")
download_url=$(printf '%s\n' "$manifest" | python3 -c 'import re, sys; text=sys.stdin.read(); match=re.search(r"url:\s*\"([^\"]+)\"", text); print(match.group(1) if match else "", end="")')
checksum=$(printf '%s\n' "$manifest" | python3 -c 'import re, sys; text=sys.stdin.read(); match=re.search(r"checksum:\s*\"([0-9a-f]{64})\"", text); print(match.group(1) if match else "", end="")')

if [ -z "$download_url" ] || [ -z "$checksum" ]; then
    echo "[!] failed to read binary target URL/checksum from Package.swift at $RELEASE_TAG"
    exit 1
fi

expected_url="https://github.com/Lakr233/libghostty-spm/releases/download/$STORAGE_RELEASE_TAG/$ASSET_NAME"
if [ "$download_url" != "$expected_url" ]; then
    echo "[!] Package.swift download URL does not match storage release"
    echo "    expected: $expected_url"
    echo "    actual:   $download_url"
    exit 1
fi

asset_digest=$(
    gh release view "$STORAGE_RELEASE_TAG" \
        --json assets \
        --jq ".assets[] | select(.name == \"$ASSET_NAME\") | .digest"
)

if [ -z "$asset_digest" ]; then
    echo "[!] release asset not found: $STORAGE_RELEASE_TAG/$ASSET_NAME"
    exit 1
fi

if [ "$asset_digest" != "sha256:$checksum" ]; then
    echo "[!] release asset digest does not match Package.swift checksum"
    echo "    asset:    $asset_digest"
    echo "    manifest: sha256:$checksum"
    exit 1
fi

echo "[*] release verified: $RELEASE_TAG -> $STORAGE_RELEASE_TAG/$ASSET_NAME"
