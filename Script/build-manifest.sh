#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[!] repository root not found. Run this script from a libghostty-spm checkout."
    exit 1
fi

XCFRAMEWORK_PATH_ZIP=${1:-}
DOWNLOAD_URL=${2:-}

if [ -z "$XCFRAMEWORK_PATH_ZIP" ] || [ -z "$DOWNLOAD_URL" ]; then
    echo "Usage: $0 <xcframework_zip> <download_url>"
    exit 1
fi

if [ ! -f "$XCFRAMEWORK_PATH_ZIP" ]; then
    echo "[!] xcframework zip not found: $XCFRAMEWORK_PATH_ZIP"
    exit 1
fi

SHA256SUM=$(shasum -a 256 "$XCFRAMEWORK_PATH_ZIP" | awk '{print $1}')
echo "[*] SHA256: $SHA256SUM"

PACKAGE_MANIFEST=$(cat Package.swift.template)
PACKAGE_MANIFEST=${PACKAGE_MANIFEST/__DOWNLOAD_URL__/$DOWNLOAD_URL}
PACKAGE_MANIFEST=${PACKAGE_MANIFEST/__CHECKSUM__/$SHA256SUM}

echo "$PACKAGE_MANIFEST" >Package.swift
