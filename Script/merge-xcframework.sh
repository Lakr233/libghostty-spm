#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."
if [ ! -f .root ]; then
    echo "[*] malformed project structure"
    exit 1
fi

ARTIFACTS_DIR=${1:-}
OUTPUT_XCFRAMEWORK=${2:-}
OUTPUT_ZIP=${3:-}

if [ -z "$ARTIFACTS_DIR" ] || [ -z "$OUTPUT_XCFRAMEWORK" ]; then
    echo "Usage: $0 <artifacts_dir> <output_xcframework> [output_zip]"
    exit 1
fi

if [ ! -d "$ARTIFACTS_DIR" ]; then
    echo "[!] artifacts directory not found: $ARTIFACTS_DIR"
    exit 1
fi

XCFRAMEWORK_COMMAND=()
FOUND_VARIANTS=0
FRAMEWORK_NAME="libghostty"
FRAMEWORK_STAGE_DIR="$ARTIFACTS_DIR/.framework-staging"

plist_platform_for_variant() {
    case "$1" in
        macosx) echo "MacOSX" ;;
        maccatalyst) echo "MacOSX" ;;
        iphoneos) echo "iPhoneOS" ;;
        iphonesimulator) echo "iPhoneSimulator" ;;
        *)
            echo "[!] unknown variant: $1" >&2
            exit 1
            ;;
    esac
}

version_framework_for_variant() {
    local variant="$1"
    local framework_path="$2"
    local version_dir="$framework_path/Versions/A"

    case "$variant" in
        macosx | maccatalyst) ;;
        *) return 0 ;;
    esac

    mkdir -p "$version_dir/Resources"
    mv "$framework_path/$FRAMEWORK_NAME" "$version_dir/$FRAMEWORK_NAME"
    mv "$framework_path/Headers" "$version_dir/Headers"
    mv "$framework_path/Modules" "$version_dir/Modules"
    mv "$framework_path/Info.plist" "$version_dir/Resources/Info.plist"

    ln -s A "$framework_path/Versions/Current"
    ln -s Versions/Current/$FRAMEWORK_NAME "$framework_path/$FRAMEWORK_NAME"
    ln -s Versions/Current/Headers "$framework_path/Headers"
    ln -s Versions/Current/Modules "$framework_path/Modules"
    ln -s Versions/Current/Resources "$framework_path/Resources"
}

verify_deep_framework_layout() {
    local xcframework_path="$1"
    local framework_path

    while IFS= read -r -d '' framework_path; do
        if [ ! -L "$framework_path/$FRAMEWORK_NAME" ] ||
            [ ! -L "$framework_path/Headers" ] ||
            [ ! -L "$framework_path/Modules" ] ||
            [ ! -L "$framework_path/Resources" ] ||
            [ ! -L "$framework_path/Versions/Current" ] ||
            [ ! -f "$framework_path/Versions/A/Resources/Info.plist" ]; then
            echo "[!] invalid deep framework layout: $framework_path"
            exit 1
        fi
    done < <(find "$xcframework_path" \( -path "*/macos-*/$FRAMEWORK_NAME.framework" -o -path "*-maccatalyst/$FRAMEWORK_NAME.framework" \) -type d -print0)
}

verify_xcframework_zip() {
    local zip_path="$1"
    local xcframework_name="$2"
    local unpack_dir

    unpack_dir=$(mktemp -d)
    ditto -x -k "$zip_path" "$unpack_dir"
    verify_deep_framework_layout "$unpack_dir/$xcframework_name"
    rm -rf "$unpack_dir"
}

stage_framework() {
    local variant_dir="$1"
    local variant
    local library_path
    local header_dir
    local framework_path
    local modules_dir
    local headers_dir
    local platform

    variant=$(basename "$variant_dir")
    library_path="$variant_dir/lib/libghostty.a"
    header_dir="$variant_dir/include"
    framework_path="$FRAMEWORK_STAGE_DIR/$variant/$FRAMEWORK_NAME.framework"
    platform=$(plist_platform_for_variant "$variant")

    rm -rf "$framework_path"

    # macOS requires the versioned bundle layout (Versions/A/…) — shallow bundles
    # are rejected by Xcode's embed-frameworks validation with:
    #   "Framework contains Info.plist, expected Versions/Current/Resources/Info.plist
    #    since the platform does not use shallow bundles"
    # iOS, Catalyst, and simulator slices use the shallow layout and are unaffected.
    if [ "$variant" = "macosx" ]; then
        modules_dir="$framework_path/Versions/A/Modules"
        headers_dir="$framework_path/Versions/A/Headers"
        mkdir -p "$headers_dir" "$modules_dir" "$framework_path/Versions/A/Resources"
        cp "$library_path" "$framework_path/Versions/A/$FRAMEWORK_NAME"
        cp -R "$header_dir/." "$headers_dir/"
        mv "$headers_dir/module.modulemap" "$modules_dir/module.modulemap"
        sed -i '' "1s/^module $FRAMEWORK_NAME/framework module $FRAMEWORK_NAME/" "$modules_dir/module.modulemap"
        (cd "$framework_path/Versions" && ln -s A Current)
        ln -s "Versions/Current/$FRAMEWORK_NAME" "$framework_path/$FRAMEWORK_NAME"
        ln -s "Versions/Current/Headers"          "$framework_path/Headers"
        ln -s "Versions/Current/Modules"          "$framework_path/Modules"
        ln -s "Versions/Current/Resources"        "$framework_path/Resources"

        cat >"$framework_path/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$FRAMEWORK_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>wiki.qaq.libghostty-spm.$FRAMEWORK_NAME</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$FRAMEWORK_NAME</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>$platform</string>
    </array>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
EOF
    else
        modules_dir="$framework_path/Modules"
        headers_dir="$framework_path/Headers"
        mkdir -p "$headers_dir" "$modules_dir"
        cp "$library_path" "$framework_path/$FRAMEWORK_NAME"
        cp -R "$header_dir/." "$headers_dir/"
        mv "$headers_dir/module.modulemap" "$modules_dir/module.modulemap"
        sed -i '' "1s/^module $FRAMEWORK_NAME/framework module $FRAMEWORK_NAME/" "$modules_dir/module.modulemap"

        cat >"$framework_path/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$FRAMEWORK_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.lakr233.libghostty-spm.$FRAMEWORK_NAME</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$FRAMEWORK_NAME</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>$platform</string>
    </array>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
EOF
    fi

    version_framework_for_variant "$variant" "$framework_path"

    XCFRAMEWORK_COMMAND+=("-framework" "$framework_path")
}

rm -rf "$FRAMEWORK_STAGE_DIR"

add_library() {
    local variant_dir="$1"
    local library_path="$variant_dir/lib/libghostty.a"
    local header_dir="$variant_dir/include"

    if [ ! -f "$library_path" ]; then
        echo "[!] missing library: $library_path"
        exit 1
    fi

    if [ ! -d "$header_dir" ]; then
        echo "[!] missing headers: $header_dir"
        exit 1
    fi

    stage_framework "$variant_dir"
    FOUND_VARIANTS=$((FOUND_VARIANTS + 1))
}

for variant_dir in "$ARTIFACTS_DIR"/*; do
    [ -d "$variant_dir" ] || continue
    [ "$(basename "$variant_dir")" = ".intermediates" ] && continue
    add_library "$variant_dir"
done

if [ "$FOUND_VARIANTS" -eq 0 ]; then
    echo "[!] no staged variants found in $ARTIFACTS_DIR"
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_XCFRAMEWORK")"
rm -rf "$OUTPUT_XCFRAMEWORK"

echo "[*] creating xcframework: $OUTPUT_XCFRAMEWORK"
xcodebuild -create-xcframework \
    -output "$OUTPUT_XCFRAMEWORK" \
    "${XCFRAMEWORK_COMMAND[@]}"

verify_deep_framework_layout "$OUTPUT_XCFRAMEWORK"

if [ -n "$OUTPUT_ZIP" ]; then
    mkdir -p "$(dirname "$OUTPUT_ZIP")"
    rm -f "$OUTPUT_ZIP"
    (
        cd "$(dirname "$OUTPUT_XCFRAMEWORK")"
        ditto -c -k --sequesterRsrc --keepParent "$(basename "$OUTPUT_XCFRAMEWORK")" "$(basename "$OUTPUT_ZIP")"
    )
    mv "$(dirname "$OUTPUT_XCFRAMEWORK")/$(basename "$OUTPUT_ZIP")" "$OUTPUT_ZIP"
    verify_xcframework_zip "$OUTPUT_ZIP" "$(basename "$OUTPUT_XCFRAMEWORK")"
    echo "[*] packed xcframework zip: $OUTPUT_ZIP"
fi
