#!/bin/bash

# Runs the MobileGhosttyApp UI tests on a fresh, pinned simulator.
#
#   Script/test-ui-simulator.sh <iPhone|iPad> <result-bundle-prefix>
#
# The simulator is created for the run and deleted after it, and its system
# settings are pinned before the first test: English language and region, the
# US QWERTY keyboard alone, and no autocorrection, prediction, smart
# punctuation or slide-to-type tip, and the app may paste from other apps
# without asking. A host in another language (a Chinese
# system localizes the edit menu and the keyboard's keys) or a simulator left
# with a Pinyin keyboard would otherwise change what the tests type and tap.
#
# The suite runs twice, inline selection off and on. Tests that press keys on
# XCTest's simulated hardware keyboard run last, each on a fresh boot: once a
# hardware key has been pressed the software keyboard stays hidden for the
# rest of the boot, and the software-keyboard tests would find no keys.
#
# A failure does not collect a sysdiagnose: `simctl diagnose` takes many
# minutes, holds the result bundle open meanwhile, and adds nothing the
# bundle's screenshots and logs do not already show.

set -euo pipefail

cd "$(dirname "$0")/.."

LABEL=${1:?Usage: test-ui-simulator.sh <iPhone|iPad> <result-bundle-prefix>}
RESULT_PREFIX=${2:?Usage: test-ui-simulator.sh <iPhone|iPad> <result-bundle-prefix>}
TEST_CLASS=MobileGhosttyAppUITests/MobileGhosttyAppUITests
DERIVED_DATA="${LIBGHOSTTY_DERIVED_DATA:-$(pwd)/build/UITestDerivedData}"
HARDWARE_KEY_TESTS=(
    testInlineLongPressSelectionCopiesWithKeyboard
    testInlineSelectionSwitchesBetweenTouchPointerAndKeyboard
)

case "$LABEL" in
iPhone) PATTERNS=("iPhone Air" "iPhone 16" "iPhone") ;;
iPad) PATTERNS=("iPad Air 13-inch (M3)" "iPad Air 13-inch" "iPad Pro 13-inch" "iPad") ;;
*)
    echo "[!] unknown device label: $LABEL"
    exit 1
    ;;
esac

# LIBGHOSTTY_SIM_IOS=18 picks the newest iOS 18.x runtime; the default is the
# newest installed.
RUNTIME=$(xcrun simctl list runtimes available | awk -v version="${LIBGHOSTTY_SIM_IOS:-}" '
    /^iOS .*com\.apple\.CoreSimulator\.SimRuntime\.iOS/ && index($2, version) == 1 { runtime=$NF }
    END { print runtime }')
[ -n "$RUNTIME" ] || { echo "[!] no available iOS ${LIBGHOSTTY_SIM_IOS:-} simulator runtime"; exit 1; }
# The first device type the runtime accepts: an older runtime cannot create
# the newest models.
UDID=
for pattern in "${PATTERNS[@]}"; do
    DEVICE=$(xcrun simctl list devicetypes | sed -n "/$pattern/s/.*(\(com\.apple\.CoreSimulator\.SimDeviceType\.[^)]*\)).*/\1/p" | head -1)
    [ -n "$DEVICE" ] || continue
    UDID=$(xcrun simctl create "libghostty-ui-$LABEL-$$" "$DEVICE" "$RUNTIME" 2>/dev/null) && break
done
[ -n "$UDID" ] || { echo "[!] no $LABEL simulator device type runs $RUNTIME"; exit 1; }
trap 'xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true; xcrun simctl delete "$UDID" >/dev/null 2>&1 || true' EXIT
echo "[*] $LABEL simulator $UDID ($DEVICE, $RUNTIME)"

boot_fresh() {
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    xcrun simctl boot "$UDID"
    xcrun simctl bootstatus "$UDID" -b >/dev/null
}

pin_settings() {
    local defaults=(xcrun simctl spawn "$UDID" defaults write)
    "${defaults[@]}" -g AppleLanguages -array en
    "${defaults[@]}" -g AppleLocale -string en_US
    "${defaults[@]}" -g AppleKeyboards -array "en_US@sw=QWERTY;hw=Automatic"
    "${defaults[@]}" -g AppleKeyboardsExpanded -int 1
    for key in KeyboardAutocorrection KeyboardPrediction KeyboardAutocapitalization \
        KeyboardCheckSpelling KeyboardPeriodShortcut SmartQuotesEnabled SmartDashesEnabled \
        KeyboardContinuousPathEnabled; do
        "${defaults[@]}" com.apple.Preferences "$key" -bool NO
    done
    "${defaults[@]}" com.apple.Preferences DidShowContinuousPathIntroduction -bool YES
}

# The suite pastes what XCTest's typing left on the pasteboard, and a paste
# from another app asks first, in a remote alert XCTest cannot reach. Grant
# the app "Paste from Other Apps" (Settings stores it in TCC) while shut down.
allow_paste() {
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    sqlite3 "$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Library/TCC/TCC.db" \
        "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags)
         VALUES ('kTCCServicePasteboard', 'wiki.qaq.MobileGhosttyApp', 0, 2, 2, 1, 0);"
}

STATUS=0
run_tests() {
    local name="$1" inline="$2"
    shift 2
    echo "[*] $LABEL $name (inline selection $inline)"
    rm -rf "$RESULT_PREFIX-$name.xcresult"
    TEST_RUNNER_LIBGHOSTTY_INLINE_SELECTION="$inline" xcodebuild "${XCODEBUILD[@]}" \
        test-without-building \
        -testLanguage en \
        -testRegion US \
        -collect-test-diagnostics never \
        -resultBundlePath "$RESULT_PREFIX-$name.xcresult" \
        "$@" || { echo "[!] $LABEL $name failed"; STATUS=1; }
}

XCODEBUILD=(
    -project Example/MobileGhosttyApp.xcodeproj
    -scheme MobileGhosttyApp
    -destination "id=$UDID"
    -derivedDataPath "$DERIVED_DATA"
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=
)
echo "[*] build for testing"
xcodebuild "${XCODEBUILD[@]}" build-for-testing

boot_fresh
pin_settings
allow_paste

SKIP=()
for test in "${HARDWARE_KEY_TESTS[@]}"; do
    SKIP+=("-skip-testing:$TEST_CLASS/$test")
done
for inline in 0 1; do
    boot_fresh
    run_tests "inline-$inline" "$inline" "${SKIP[@]}"
done
for test in "${HARDWARE_KEY_TESTS[@]}"; do
    boot_fresh
    run_tests "$test" 1 "-only-testing:$TEST_CLASS/$test"
done

exit "$STATUS"
