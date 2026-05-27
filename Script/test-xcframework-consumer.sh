#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."
if [ ! -f .root ]; then
    echo "[*] malformed project structure"
    exit 1
fi

XCFRAMEWORK_PATH=${1:-BinaryTarget/GhosttyKit.xcframework}

if [ ! -d "$XCFRAMEWORK_PATH" ]; then
    echo "[!] xcframework not found: $XCFRAMEWORK_PATH"
    exit 1
fi

format_output() {
    if command -v xcbeautify >/dev/null 2>&1; then
        xcbeautify
    else
        cat
    fi
}

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/Consumer/BinaryTarget" "$WORK_DIR/Consumer/Sources/Consumer"
ditto "$XCFRAMEWORK_PATH" "$WORK_DIR/Consumer/BinaryTarget/GhosttyKit.xcframework"

cat >"$WORK_DIR/Consumer/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Consumer",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
        .macCatalyst(.v15),
    ],
    products: [
        .library(name: "Consumer", targets: ["Consumer"]),
    ],
    targets: [
        .binaryTarget(
            name: "libghostty",
            path: "BinaryTarget/GhosttyKit.xcframework"
        ),
        .target(
            name: "Consumer",
            dependencies: ["libghostty"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
            ]
        ),
    ]
)
EOF

cat >"$WORK_DIR/Consumer/Sources/Consumer/Consumer.swift" <<'EOF'
import libghostty

public func passThroughPlatform(_ platform: ghostty_platform_e) -> ghostty_platform_e {
    platform
}
EOF

test_build() {
    local destination="$1"

    echo "[*] consumer build destination=$destination"
    xcodebuild \
        -scheme Consumer \
        -destination "$destination" \
        -derivedDataPath "$WORK_DIR/DerivedData" \
        -packageCachePath "$WORK_DIR/PackageCache" \
        build 2>&1 | format_output
    local exit_code=${PIPESTATUS[0]}
    if [ "$exit_code" -ne 0 ]; then
        echo "[!] consumer build failed destination=$destination"
        exit "$exit_code"
    fi
}

(
    cd "$WORK_DIR/Consumer"
    test_build "generic/platform=macOS"
    test_build "generic/platform=macOS,variant=Mac Catalyst"
    test_build "generic/platform=iOS"
    test_build "generic/platform=iOS Simulator"
)

echo "[*] xcframework consumer tests passed"
