#!/bin/zsh

set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."
[[ -f .root ]] || { echo "[-] run from the repository"; exit 1; }

# Stage, check and compare the notices an XCFramework slice carries in
# Headers/Licenses: each component's LICENSE and NOTICE files, a manifest
# naming the origin and commit it was built from, and for Ghostty the patch
# that turns that commit into the tree that was compiled.
#
#   stage-source-notices.sh <ghostty source> <destination>
#   stage-source-notices.sh --verify-source <ghostty source> <staged>
#   stage-source-notices.sh --check <staged>
#   stage-source-notices.sh --compare <staged> <staged>
#
# A published asset must name a public GitHub origin and a commit for every
# component; GitHub Actions holds every run to that. A local build may use a
# mirror, a local clone or an extracted tarball (Patches/ghostty/README.md)
# and records null for what it cannot know. SOURCE_NOTICES_STRICT=1 or 0
# overrides the default either way.
if [[ -z ${SOURCE_NOTICES_STRICT:-} ]]; then
    SOURCE_NOTICES_STRICT=0
    [[ ${GITHUB_ACTIONS:-} != true ]] || SOURCE_NOTICES_STRICT=1
fi
[[ $SOURCE_NOTICES_STRICT == [01] ]] || { echo "[-] SOURCE_NOTICES_STRICT must be 0 or 1"; exit 1; }

check_notices() {
    local directory=$1 relative digest
    [[ -d "$directory" && ! -L "$directory" ]] || {
        echo "[-] notice directory is missing or a link: $directory"; return 1;
    }
    [[ -z $(find "$directory" -type l -print) ]] || {
        echo "[-] notice directory holds a link: $directory"; return 1;
    }
    [[ -f "$directory/manifest.json" ]] || {
        echo "[-] notice manifest is missing: $directory"; return 1;
    }
    jq -e --argjson strict "$SOURCE_NOTICES_STRICT" '
        def relative: type == "string" and test("^[A-Za-z0-9_. /-]+$")
            and (startswith("/") | not) and (split("/") | all(. != ".." and . != "." and . != ""));
        def hash: type == "string" and test("^[0-9a-f]{64}$");
        def revision: type == "string" and test("^[0-9a-f]{40}$");
        def origin: type == "string" and test("^[a-z][a-z0-9+.-]*://[^@\\s]+$");
        def known(check): if $strict == 1 then check else . == null or check end;
        .schema_version == 1 and (.components | type == "array" and length > 0)
        and ([.components[].name] | unique | length) == (.components | length)
        and all(.components[];
            (.name | test("^[A-Za-z0-9_.-]+$")) and
            (.origin | known(origin)) and
            ($strict == 0 or (.origin | startswith("https://github.com/"))) and
            (.revision | known(revision)) and (.tree | known(revision)) and
            ((.revision == null) == (.tree == null)) and
            (.notices | type == "array" and length > 0) and
            all(.notices[]; (.source_path | relative) and (.path | relative) and (.sha256 | hash)) and
            ((has("source_patch") | not) or
                ((.source_patch.path | relative) and (.source_patch.sha256 | hash))))
    ' "$directory/manifest.json" >/dev/null || {
        if (( SOURCE_NOTICES_STRICT )); then
            echo "[-] notice manifest is malformed, or does not name a public GitHub origin and a commit for every component: $directory"
        else
            echo "[-] notice manifest is malformed: $directory"
        fi
        return 1
    }
    [[ $(jq -Sc . "$directory/manifest.json") == $(cat "$directory/manifest.json") ]] || {
        echo "[-] notice manifest is not canonical"; return 1;
    }
    while IFS=$'\t' read -r relative digest; do
        [[ -f "$directory/$relative" && ! -L "$directory/$relative" && -s "$directory/$relative" ]] || {
            echo "[-] missing or changed notice: $relative"; return 1;
        }
        [[ $(shasum -a 256 "$directory/$relative" | awk '{print $1}') == "$digest" ]] || {
            echo "[-] missing or changed notice: $relative"; return 1;
        }
    done < <(jq -r '.components[] | (.notices[], .source_patch? // empty) | [.path, .sha256] | @tsv' "$directory/manifest.json")
    diff \
        <({ print manifest.json; jq -r '.components[] | (.notices[], .source_patch? // empty) | .path' "$directory/manifest.json"; } | LC_ALL=C sort) \
        <(cd "$directory"; find . -type f -print | sed 's|^./||' | LC_ALL=C sort) || {
        echo "[-] notice directory and its manifest list different files: $directory"; return 1;
    }
}

# The origin as a manifest may carry it: a URL with any credentials removed.
# A path on this machine names nothing a reader could fetch and is nobody
# else's business, so it is recorded as unknown, like a source with no origin.
public_origin() {
    local origin=${1%.git}
    origin=${origin/#git@github.com:/https:\/\/github.com\/}
    [[ "$origin" =~ '^([a-z][a-z0-9+.-]*://)([^/@]*@)?([^@[:space:]]+)$' ]] || return 0
    [[ ${match[1]} != file:// ]] || return 0
    print -r -- "${match[1]}${match[3]}"
}

# One component's notices and its manifest record. With `patch`, what the
# checkout holds on top of its commit — tracked edits and added files that
# are not ignored — is kept as source.patch: for Ghostty that is our patch
# stack as applied. The wrapper is named by its commit alone: what it does to
# the binary is that patch stack, already recorded, and its checkout is where
# a build leaves its caches and a developer keeps unrelated files.
component() {
    local source=$1 name=$2 destination=$3 contents=$4
    local revision= tree= origin= notice relative digest patch diff_status is_git=0
    if [[ $(git -C "$source" rev-parse --show-toplevel 2>/dev/null) == "${source:A}" ]]; then
        is_git=1
        revision=$(git -C "$source" rev-parse --verify HEAD)
        tree=$(git -C "$source" rev-parse --verify 'HEAD^{tree}')
        origin=$(public_origin "$(git -C "$source" remote get-url origin 2>/dev/null || true)")
    fi
    if (( SOURCE_NOTICES_STRICT )); then
        (( is_git )) || { echo "[-] source is not a git checkout: $source"; return 1; }
        [[ "$origin" == https://github.com/* ]] || {
            echo "[-] source origin must be a public GitHub URL: $source"; return 1;
        }
    fi
    mkdir "$destination/$name"
    local notices='[]'
    [[ -s "$source/LICENSE" && ! -L "$source/LICENSE" ]] || {
        echo "[-] source LICENSE is missing: $source"; return 1;
    }
    for notice in "$source"/LICENSE "$source"/NOTICE*(N); do
        relative=${notice:t}
        if (( is_git )); then
            git -C "$source" ls-files --error-unmatch -- "$relative" >/dev/null 2>&1 || {
                echo "[-] notice is not tracked by its source: $relative"; return 1;
            }
        fi
        [[ -f "$notice" && ! -L "$notice" && -s "$notice" ]] || {
            echo "[-] notice is empty or a link: $notice"; return 1;
        }
        cp "$notice" "$destination/$name/$relative"
        digest=$(shasum -a 256 "$notice" | awk '{print $1}')
        notices=$(jq -c --arg source "$relative" --arg path "$name/$relative" --arg hash "$digest" \
            '. + [{source_path:$source,path:$path,sha256:$hash}]' <<<"$notices")
    done
    local record
    record=$(jq -nc --arg name "$name" --arg origin "$origin" --arg revision "$revision" \
        --arg tree "$tree" --argjson notices "$notices" \
        'def known: if . == "" then null else . end;
        {name:$name,origin:($origin|known),revision:($revision|known),tree:($tree|known),notices:$notices}')
    if [[ $contents == patch ]] && (( is_git )); then
        patch="$destination/$name/source.patch"
        git -C "$source" diff --no-ext-diff --no-textconv --binary HEAD -- > "$patch"
        while IFS= read -r -d '' relative; do
            (cd "$source"; git diff --no-index --no-ext-diff --no-textconv --binary -- /dev/null "$relative") >> "$patch" || {
                diff_status=$?; (( diff_status == 1 )) || return "$diff_status";
            }
        done < <(git -C "$source" ls-files --others --exclude-standard -z)
        if [[ -s "$patch" ]]; then
            digest=$(shasum -a 256 "$patch" | awk '{print $1}')
            record=$(jq -c --arg path "$name/source.patch" --arg hash "$digest" \
                '. + {source_patch:{path:$path,sha256:$hash}}' <<<"$record")
        else
            rm "$patch"
        fi
    fi
    print -r -- "$record"
}

stage() {
    local source=${1:A} destination=${2:A} ghostty wrapper
    mkdir "$destination"
    ghostty=$(component "$source" ghostty "$destination" patch)
    wrapper=$(component "$PWD" libghostty-spm "$destination" commit)
    jq -nSc --argjson ghostty "$ghostty" --argjson wrapper "$wrapper" \
        '{schema_version:1,components:[$ghostty,$wrapper]}' > "$destination/manifest.json"
    check_notices "$destination"
}

case ${1:-} in
    --check) check_notices "${2:?notice directory required}" ;;
    --compare)
        check_notices "${2:?first notice directory required}"
        check_notices "${3:?second notice directory required}"
        diff -r "$2" "$3" || { echo "[-] notices differ: $2 $3"; exit 1; }
        ;;
    --verify-source)
        temporary=$(mktemp -d)
        trap 'rm -rf "$temporary"' EXIT
        stage "${2:?source required}" "$temporary/Licenses"
        diff -r "${3:?staged notice directory required}" "$temporary/Licenses" || {
            echo "[-] the source changed since its notices were staged: $2"; exit 1;
        }
        ;;
    *) stage "${1:?source required}" "${2:?destination required}" ;;
esac
