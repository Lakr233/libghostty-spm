#!/bin/bash

# Print the release tag that stores the XCFramework for the pinned Ghostty
# commit: `upstream.<first 12 hex of Ghostty.ref>`, with `-<Ghostty.build>`
# appended when the patch stack or the target set changed without a Ghostty
# bump (Ghostty.build counts from 2 — a missing file or a 1 is the bare
# tag). build.yml and release.yml both read it from here so the two can
# never disagree. Ghostty is pinned to a commit, not a release: upstream
# tags rarely, and main carries the fixes we need.

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[!] repository root not found. Run this script from a libghostty-spm checkout." >&2
    exit 1
fi

GHOSTTY_REF=$(tr -d '[:space:]' < Ghostty.ref)
if ! echo "$GHOSTTY_REF" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "[!] Ghostty.ref must contain one full lowercase commit sha: $GHOSTTY_REF" >&2
    exit 1
fi

GHOSTTY_BUILD=1
if [ -f Ghostty.build ]; then
    GHOSTTY_BUILD=$(tr -d '[:space:]' < Ghostty.build)
    if ! echo "$GHOSTTY_BUILD" | grep -Eq '^[1-9][0-9]*$'; then
        echo "[!] Ghostty.build must be a positive integer: $GHOSTTY_BUILD" >&2
        exit 1
    fi
fi

STORAGE_TAG="upstream.${GHOSTTY_REF:0:12}"
if [ "$GHOSTTY_BUILD" -eq 1 ]; then
    echo "$STORAGE_TAG"
else
    echo "$STORAGE_TAG-$GHOSTTY_BUILD"
fi
