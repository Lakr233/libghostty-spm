#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/swiftpm-module-cache}"

format_output() {
    if command -v xcbeautify >/dev/null 2>&1; then
        xcbeautify
    else
        cat
    fi
}

# One derived-data root for every destination, so the binary target a remote
# manifest downloads can be inspected after the first build.
DERIVED_DATA="${LIBGHOSTTY_DERIVED_DATA:-$(pwd)/build/DerivedData}"

test_build() {
    local scheme="$1"
    local destination="$2"
    local command=(
        xcodebuild
        -scheme "$scheme"
        -destination "$destination"
        -derivedDataPath "$DERIVED_DATA"
    )

    command+=(build)

    echo "[*] build scheme=$scheme destination=$destination"
    "${command[@]}" 2>&1 | format_output
    local exit_code=${PIPESTATUS[0]}
    if [ "$exit_code" -ne 0 ]; then
        echo "[!] failed scheme=$scheme destination=$destination"
        exit "$exit_code"
    fi
}

test_build "GhosttyKit" "generic/platform=macOS"
test_build "GhosttyKit" "generic/platform=iOS"
test_build "GhosttyKit" "generic/platform=iOS Simulator"
test_build "GhosttyTerminal" "generic/platform=macOS"
test_build "GhosttyTerminal" "generic/platform=macOS,variant=Mac Catalyst"
test_build "GhosttyTerminal" "generic/platform=iOS"
test_build "GhosttyTerminal" "generic/platform=iOS Simulator"

# visionOS needs the xros SDK on the host (Xcode 15.2+ ships it; a trimmed
# install may not) and an xros slice in the binary target — assets from
# upstream.1.3.1-2 on carry one, older ones do not. Package.local.swift's
# binary target sits in BinaryTarget/; a downloaded one lands under the
# derived data's SourcePackages once the builds above have resolved it.
binary_target_has_xros_slice() {
    if grep -q 'path: "BinaryTarget/GhosttyKit.xcframework"' Package.swift; then
        [ -d BinaryTarget/GhosttyKit.xcframework/xros-arm64 ]
    else
        find "$DERIVED_DATA/SourcePackages/artifacts" -type d -name xros-arm64 -path "*GhosttyKit.xcframework*" 2>/dev/null | grep -q .
    fi
}

if ! xcodebuild -showsdks 2>/dev/null | grep -q -- "-sdk xros"; then
    echo "[*] visionOS SDK not installed, skipping visionOS destinations"
elif ! binary_target_has_xros_slice; then
    echo "[*] binary target has no xros slice, skipping visionOS destinations"
else
    test_build "GhosttyKit" "generic/platform=visionOS"
    test_build "GhosttyKit" "generic/platform=visionOS Simulator"
    test_build "GhosttyTerminal" "generic/platform=visionOS"
    test_build "GhosttyTerminal" "generic/platform=visionOS Simulator"
fi

echo "[*] all tests passed"
