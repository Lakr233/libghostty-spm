#!/bin/bash

# Print the release tag that stores the XCFramework for the pinned Ghostty.
# `upstream.<Ghostty.version>` for the first asset built from a release;
# `upstream.<Ghostty.version>-<Ghostty.build>` when the patch stack or the
# target set changed without a Ghostty bump (Ghostty.build counts from 2 —
# a missing file or a 1 is the bare tag). build.yml and release.yml both
# read it from here so the two can never disagree.

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[!] repository root not found. Run this script from a libghostty-spm checkout." >&2
    exit 1
fi

GHOSTTY_VERSION=$(tr -d '[:space:]' < Ghostty.version)
if ! echo "$GHOSTTY_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "[!] Ghostty.version must be semantic, for example 1.3.1: $GHOSTTY_VERSION" >&2
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

if [ "$GHOSTTY_BUILD" -eq 1 ]; then
    echo "upstream.$GHOSTTY_VERSION"
else
    echo "upstream.$GHOSTTY_VERSION-$GHOSTTY_BUILD"
fi
