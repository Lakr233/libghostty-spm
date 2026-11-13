#!/bin/zsh

set -euo pipefail
cd "$(dirname "$0")/.."
source=${1:?pinned Ghostty checkout required}
source=${source:A}
revision=$(tr -d '[:space:]' < Ghostty.ref)
[[ $(git -C "$source" rev-parse HEAD) == "$revision" ]]

temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
[[ -d "$source/.git" ]]
mkdir "$temporary/source"
cp -R "$source/.git" "$temporary/source/.git"
git -C "$temporary/source" remote set-url origin https://github.com/ghostty-org/ghostty
git -C "$temporary/source" sparse-checkout set --no-cone /LICENSE /NOTICE\* /include/ghostty.h
git -C "$temporary/source" checkout -q --detach "$revision"
git -C "$temporary/source" checkout-index -a
source="$temporary/source"

refuses() {
    if "$@" > "$temporary/refusal.log" 2>&1; then
        echo "[-] expected refusal: $*"; exit 1
    fi
}

# Published assets are held to the strict rules whatever runs this test.
export SOURCE_NOTICES_STRICT=1

./Script/stage-source-notices.sh "$source" "$temporary/original"
./Script/stage-source-notices.sh --verify-source "$source" "$temporary/original"
cmp "$source/LICENSE" "$temporary/original/ghostty/LICENSE"
cmp LICENSE "$temporary/original/libghostty-spm/LICENSE"
[[ $(jq -r '.components[] | select(.name == "ghostty") | .revision' "$temporary/original/manifest.json") == "$revision" ]]

# A patch must reconstruct both tracked edits and added source files.
print '\nfixture notice change' >> "$source/LICENSE"
mkdir -p "$source/fixture"
print 'fixture source addition' > "$source/fixture/new.txt"
printf '\000\001\377ghostty\000' > "$source/fixture/new.bin"
cp "$source/fixture/new.bin" "$temporary/binary-expected"
./Script/stage-source-notices.sh "$source" "$temporary/changed"
refuses ./Script/stage-source-notices.sh --verify-source "$source" "$temporary/original"
git -C "$source" show HEAD:LICENSE > "$source/LICENSE"
rm -r "$source/fixture"
git -C "$source" apply "$temporary/changed/ghostty/source.patch"
cmp "$source/LICENSE" "$temporary/changed/ghostty/LICENSE"
[[ $(cat "$source/fixture/new.txt") == 'fixture source addition' ]]
cmp "$source/fixture/new.bin" "$temporary/binary-expected"
./Script/stage-source-notices.sh --verify-source "$source" "$temporary/changed"
refuses ./Script/stage-source-notices.sh --compare "$temporary/original" "$temporary/changed"

cp -R "$temporary/original" "$temporary/corrupt"
print changed >> "$temporary/corrupt/ghostty/LICENSE"
refuses ./Script/stage-source-notices.sh --check "$temporary/corrupt"
cp -R "$temporary/original" "$temporary/missing"
rm "$temporary/missing/ghostty/LICENSE"
refuses ./Script/stage-source-notices.sh --check "$temporary/missing"
cp -R "$temporary/original" "$temporary/extra"
print unrecorded > "$temporary/extra/unrecorded.txt"
refuses ./Script/stage-source-notices.sh --check "$temporary/extra"

# The wrapper is named by its commit alone. What a build leaves in the
# checkout (Zig's cache lands at .zig-cache in CI) or a developer keeps there
# must neither reach the archive nor fail the post-build check.
wrapper="$temporary/wrapper"
mkdir -p "$wrapper/Script"
cp .root LICENSE "$wrapper/"
cp Script/stage-source-notices.sh "$wrapper/Script/"
git -C "$wrapper" init -q
git -C "$wrapper" add -A
git -C "$wrapper" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m fixture
git -C "$wrapper" remote add origin https://github.com/Lakr233/libghostty-spm
"$wrapper/Script/stage-source-notices.sh" "$source" "$temporary/wrapper-clean"
mkdir -p "$wrapper/.zig-cache/p"
print 'private build byproduct' > "$wrapper/.zig-cache/p/a.bin"
print 'private note' > "$wrapper/untracked-note.txt"
print 'uncommitted edit' >> "$wrapper/.root"
"$wrapper/Script/stage-source-notices.sh" --verify-source "$source" "$temporary/wrapper-clean"
"$wrapper/Script/stage-source-notices.sh" "$source" "$temporary/wrapper-dirty"
diff -r "$temporary/wrapper-clean" "$temporary/wrapper-dirty"
[[ ! -e "$temporary/wrapper-dirty/libghostty-spm/source.patch" ]]
if grep -rq 'private' "$temporary/wrapper-dirty"; then
    echo "[-] wrapper checkout contents reached the notices"; exit 1
fi

# A local build takes a mirror, a local clone or an extracted tarball and
# records what it knows; none of them may pass as a published asset.
mirror="$temporary/mirror"
cp -R "$source" "$mirror"
git -C "$mirror" remote set-url origin https://builder:secret@git.example.com/mirror/ghostty.git
refuses ./Script/stage-source-notices.sh "$mirror" "$temporary/mirror-strict"
SOURCE_NOTICES_STRICT=0 ./Script/stage-source-notices.sh "$mirror" "$temporary/mirror-notices"
SOURCE_NOTICES_STRICT=0 ./Script/stage-source-notices.sh --verify-source "$mirror" "$temporary/mirror-notices"
[[ $(jq -r '.components[0].origin' "$temporary/mirror-notices/manifest.json") == https://git.example.com/mirror/ghostty ]]
if grep -rq 'secret' "$temporary/mirror-notices"; then
    echo "[-] origin credentials reached the notices"; exit 1
fi
refuses ./Script/stage-source-notices.sh --check "$temporary/mirror-notices"
git -C "$mirror" remote set-url origin "$source"
SOURCE_NOTICES_STRICT=0 ./Script/stage-source-notices.sh "$mirror" "$temporary/local-notices"
[[ $(jq -r '.components[0].origin' "$temporary/local-notices/manifest.json") == null ]]
git -C "$mirror" remote remove origin
SOURCE_NOTICES_STRICT=0 ./Script/stage-source-notices.sh "$mirror" "$temporary/no-origin-notices"
[[ $(jq -r '.components[0].origin' "$temporary/no-origin-notices/manifest.json") == null ]]
mkdir -p "$temporary/tarball/include"
cp "$source/LICENSE" "$temporary/tarball/"
cp "$source/include/ghostty.h" "$temporary/tarball/include/"
refuses ./Script/stage-source-notices.sh "$temporary/tarball" "$temporary/tarball-strict"
GIT_CEILING_DIRECTORIES="$temporary" SOURCE_NOTICES_STRICT=0 \
    ./Script/stage-source-notices.sh "$temporary/tarball" "$temporary/tarball-notices"
GIT_CEILING_DIRECTORIES="$temporary" SOURCE_NOTICES_STRICT=0 \
    ./Script/stage-source-notices.sh --verify-source "$temporary/tarball" "$temporary/tarball-notices"
[[ $(jq -c '.components[0] | [.origin, .revision, .tree]' "$temporary/tarball-notices/manifest.json") == '[null,null,null]' ]]
cmp "$source/LICENSE" "$temporary/tarball-notices/ghostty/LICENSE"
refuses ./Script/stage-source-notices.sh --check "$temporary/tarball-notices"

# Exercise the production merge and final zip checks with synthetic archives.
mkdir -p "$temporary/tools" "$temporary/variants/iphoneos/lib" "$temporary/variants/iphoneos/include/libghostty"
print 'synthetic archive' > "$temporary/variants/iphoneos/lib/libghostty.a"
print 'fixture header' > "$temporary/variants/iphoneos/include/libghostty/ghostty.h"
print 'module libghostty {}' > "$temporary/variants/iphoneos/include/libghostty/module.modulemap"
cp -R "$temporary/original" "$temporary/variants/iphoneos/include/Licenses"
cat > "$temporary/tools/xcodebuild" <<'SH'
#!/bin/bash
set -euo pipefail
while (( $# )); do
    case "$1" in
        -output) output=$2; shift 2 ;;
        -library) library=$2; shift 2 ;;
        -headers) headers=$2; shift 2 ;;
        *) shift ;;
    esac
done
mkdir -p "$output/ios-arm64/Headers"
cp "$library" "$output/ios-arm64/libghostty.a"
cp -R "$headers/." "$output/ios-arm64/Headers/"
cat > "$output/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>AvailableLibraries</key><array><dict>
<key>LibraryIdentifier</key><string>ios-arm64</string>
<key>LibraryPath</key><string>libghostty.a</string>
<key>BinaryPath</key><string>libghostty.a</string>
<key>HeadersPath</key><string>Headers</string>
<key>SupportedPlatform</key><string>ios</string>
<key>SupportedArchitectures</key><array><string>arm64</string></array>
</dict></array></dict></plist>
PLIST
SH
cat > "$temporary/tools/ditto" <<'SH'
#!/bin/zsh
set -euo pipefail
if [[ $1 == -x ]]; then
    unzip -q "$3" -d "$4"
else
    zip -qr "${argv[-1]}" "${argv[-2]}"
fi
SH
printf '#!/bin/sh\necho arm64\n' > "$temporary/tools/lipo"
printf '#!/bin/sh\nexit 0\n' > "$temporary/tools/nm"
chmod +x "$temporary/tools/"*
export PATH="$temporary/tools:$PATH"
./Script/merge-xcframework.sh "$temporary/variants" \
    "$temporary/BinaryTarget/GhosttyKit.xcframework" "$temporary/releases/GhosttyKit.xcframework.zip"
unzip -p "$temporary/releases/GhosttyKit.xcframework.zip" \
    GhosttyKit.xcframework/ios-arm64/Headers/Licenses/ghostty/LICENSE | cmp - "$temporary/original/ghostty/LICENSE"

python3 - "$temporary/releases/GhosttyKit.xcframework.zip" "$temporary" <<'PY'
import copy
from pathlib import Path
import stat
import sys
import zipfile

root = Path(sys.argv[2])
framework = "GhosttyKit.xcframework"
headers = framework + "/ios-arm64/Headers"
target = root / "BinaryTarget" / framework

def link(archive, name, destination):
    entry = zipfile.ZipInfo(name)
    entry.create_system = 3
    entry.external_attr = (stat.S_IFLNK | 0o777) << 16
    archive.writestr(entry, str(destination))

with zipfile.ZipFile(sys.argv[1]) as original:
    with zipfile.ZipFile(root / "symlink-notice.zip", "w") as malformed:
        for entry in original.infolist():
            changed = copy.copy(entry)
            if entry.filename == headers + "/Licenses/ghostty/LICENSE":
                changed.create_system = 3
                changed.external_attr = (stat.S_IFLNK | 0o777) << 16
            malformed.writestr(changed, original.read(entry))
    with zipfile.ZipFile(root / "external-headers.zip", "w") as malformed:
        for entry in original.infolist():
            if not entry.filename.startswith(headers + "/"):
                malformed.writestr(copy.copy(entry), original.read(entry))
        link(malformed, headers, target / "ios-arm64/Headers")
        assert not any("/Licenses/" in entry.filename for entry in malformed.infolist())
    with zipfile.ZipFile(root / "external-framework.zip", "w") as malformed:
        link(malformed, framework, target)
    with zipfile.ZipFile(root / "internal-headers.zip", "w") as contained:
        for entry in original.infolist():
            changed = copy.copy(entry)
            if entry.filename.startswith(headers + "/"):
                changed.filename = headers + "Internal/" + entry.filename[len(headers)+1:]
            contained.writestr(changed, original.read(entry))
        link(contained, headers, "HeadersInternal")
PY
./Script/verify-xcframework.sh "$temporary/internal-headers.zip"
refuses ./Script/verify-xcframework.sh "$temporary/symlink-notice.zip"
refuses ./Script/verify-xcframework.sh "$temporary/external-framework.zip"
refuses ./Script/verify-xcframework.sh "$temporary/external-headers.zip"

cp -R "$temporary/variants/iphoneos" "$temporary/variants/mismatched"
rm -r "$temporary/variants/mismatched/include/Licenses"
cp -R "$temporary/changed" "$temporary/variants/mismatched/include/Licenses"
refuses ./Script/merge-xcframework.sh "$temporary/variants" "$temporary/refused.xcframework"
echo '[+] source notices survive staging and packaging; changed, missing and mixed contexts are refused; a wrapper checkout adds nothing; local sources are recorded as such'
