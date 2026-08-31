#!/bin/zsh

# Audit every Swift package tag (bare semver, 1.4.0+) against the release
# track release.yml is supposed to produce: a GitHub release exists for the
# tag, the tag's Package.swift downloads from an `upstream.*` release, and
# that release's GhosttyKit.xcframework.zip has the checksum the manifest
# pins. A tag pushed by hand is not wrong as long as its manifest is —
# consumers resolve tags, not releases — but it is reported, since nothing
# but the workflow verifies a manifest before it is tagged.

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[-] repository root not found. Run this script from a libghostty-spm checkout."
    exit 1
fi

REPO=${REPO:-Lakr233/libghostty-spm}

git fetch -q --tags origin

releases=$(gh release list -R "$REPO" --limit 200 --json tagName --jq '.[].tagName')
typeset -A digests
failures=0

for tag in $(git tag --list | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V); do
    major=${tag%%.*}
    minor=${${tag#*.}%%.*}
    if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 4 ]; }; then
        continue
    fi

    manifest=$(git show "${tag}:Package.swift")
    url=$(printf '%s\n' "$manifest" | sed -n -E 's/.*url: *"([^"]+)".*/\1/p' | grep '/releases/download/' | head -n 1 || true)
    checksum=$(printf '%s\n' "$manifest" | sed -n -E 's/.*checksum: *"([0-9a-f]{64})".*/\1/p' | head -n 1)
    storage_tag=$(printf '%s' "$url" | sed -E 's#.*/download/([^/]+)/GhosttyKit\.xcframework\.zip$#\1#')

    if [ -z "$url" ] || [ -z "$checksum" ] || [ "$storage_tag" = "$url" ]; then
        echo "[-] $tag: Package.swift has no upstream release URL + checksum"
        failures=$((failures + 1))
        continue
    fi

    if [ -z "${digests[$storage_tag]:-}" ]; then
        digests[$storage_tag]=$(gh release view "$storage_tag" -R "$REPO" --json assets \
            --jq '.assets[] | select(.name == "GhosttyKit.xcframework.zip") | .digest' 2>/dev/null || true)
    fi
    digest=${digests[$storage_tag]}

    if [ -z "$digest" ]; then
        echo "[-] $tag: storage release $storage_tag has no GhosttyKit.xcframework.zip"
        failures=$((failures + 1))
        continue
    fi
    if [ "$digest" != "sha256:$checksum" ]; then
        echo "[-] $tag: checksum $checksum does not match $storage_tag asset ($digest)"
        failures=$((failures + 1))
        continue
    fi

    if ! printf '%s\n' "$releases" | grep -qx "$tag"; then
        echo "[-] $tag: manifest verified against $storage_tag, but the tag has no GitHub release"
        failures=$((failures + 1))
        continue
    fi

    echo "[+] $tag -> $storage_tag"
done

if [ "$failures" -ne 0 ]; then
    echo "[-] $failures package tag(s) need attention"
    exit 1
fi
echo "[+] every package tag has a release and a manifest matching its asset"
