#!/bin/zsh

set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."
[[ -f .root ]] || { echo "[-] run from the repository"; exit 1; }

check_notices() {
    local directory=$1 relative digest
    [[ -d "$directory" && ! -L "$directory" && -z $(find "$directory" -type l -print) ]]
    jq -e '
        def relative: type == "string" and test("^[A-Za-z0-9_. /-]+$")
            and (startswith("/") | not) and (split("/") | all(. != ".." and . != "." and . != ""));
        def hash: type == "string" and test("^[0-9a-f]{64}$");
        def revision: type == "string" and test("^[0-9a-f]{40}$");
        .schema_version == 1 and (.components | type == "array" and length > 0)
        and ([.components[].name] | unique | length) == (.components | length)
        and all(.components[];
            (.name | test("^[A-Za-z0-9_.-]+$")) and
            (.origin | type == "string" and startswith("https://github.com/")) and
            (.revision | revision) and (.tree | revision) and
            (.notices | type == "array" and length > 0) and
            all(.notices[]; (.source_path | relative) and (.path | relative) and (.sha256 | hash)) and
            ((has("source_patch") | not) or
                ((.source_patch.path | relative) and (.source_patch.sha256 | hash))))
    ' "$directory/manifest.json" >/dev/null
    [[ $(jq -Sc . "$directory/manifest.json") == $(cat "$directory/manifest.json") ]] || {
        echo "[-] notice manifest is not canonical"; return 1;
    }
    while IFS=$'\t' read -r relative digest; do
        [[ -f "$directory/$relative" && ! -L "$directory/$relative" && -s "$directory/$relative" ]]
        [[ $(shasum -a 256 "$directory/$relative" | awk '{print $1}') == "$digest" ]] || {
            echo "[-] missing or changed notice: $relative"; return 1;
        }
    done < <(jq -r '.components[] | (.notices[], .source_patch? // empty) | [.path, .sha256] | @tsv' "$directory/manifest.json")
    diff \
        <({ print manifest.json; jq -r '.components[] | (.notices[], .source_patch? // empty) | .path' "$directory/manifest.json"; } | LC_ALL=C sort) \
        <(cd "$directory"; find . -type f -print | sed 's|^./||' | LC_ALL=C sort)
}

component() {
    local source=$1 name=$2 destination=$3 revision tree origin notice relative digest patch diff_status
    revision=$(git -C "$source" rev-parse --verify HEAD)
    tree=$(git -C "$source" rev-parse --verify 'HEAD^{tree}')
    origin=$(git -C "$source" remote get-url origin)
    origin=${origin%.git}
    origin=${origin/git@github.com:/https:\/\/github.com\/}
    [[ "$origin" == https://github.com/* && "$origin" != *'@'* ]] || {
        echo "[-] source origin must be a public GitHub URL"; return 1;
    }
    mkdir "$destination/$name"
    local notices='[]'
    [[ -s "$source/LICENSE" && ! -L "$source/LICENSE" ]] || {
        echo "[-] source LICENSE is missing: $source"; return 1;
    }
    for notice in "$source"/LICENSE "$source"/NOTICE*(N); do
        relative=${notice:t}
        git -C "$source" ls-files --error-unmatch -- "$relative" >/dev/null
        [[ -f "$notice" && ! -L "$notice" && -s "$notice" ]]
        cp "$notice" "$destination/$name/$relative"
        digest=$(shasum -a 256 "$notice" | awk '{print $1}')
        notices=$(jq -c --arg source "$relative" --arg path "$name/$relative" --arg hash "$digest" \
            '. + [{source_path:$source,path:$path,sha256:$hash}]' <<<"$notices")
    done
    patch="$destination/$name/source.patch"
    git -C "$source" diff --no-ext-diff --no-textconv --binary HEAD -- > "$patch"
    while IFS= read -r -d '' relative; do
        (cd "$source"; git diff --no-index --no-ext-diff --no-textconv --binary -- /dev/null "$relative") >> "$patch" || {
            diff_status=$?; (( diff_status == 1 )) || return "$diff_status";
        }
    done < <(git -C "$source" ls-files --others --exclude-standard -z)
    local record
    record=$(jq -nc --arg name "$name" --arg origin "$origin" --arg revision "$revision" \
        --arg tree "$tree" --argjson notices "$notices" \
        '{name:$name,origin:$origin,revision:$revision,tree:$tree,notices:$notices}')
    if [[ -s "$patch" ]]; then
        digest=$(shasum -a 256 "$patch" | awk '{print $1}')
        record=$(jq -c --arg path "$name/source.patch" --arg hash "$digest" \
            '. + {source_patch:{path:$path,sha256:$hash}}' <<<"$record")
    else
        rm "$patch"
    fi
    print -r -- "$record"
}

stage() {
    local source=${1:A} destination=${2:A} ghostty wrapper
    mkdir "$destination"
    ghostty=$(component "$source" ghostty "$destination")
    wrapper=$(component "$PWD" libghostty-spm "$destination")
    jq -nSc --argjson ghostty "$ghostty" --argjson wrapper "$wrapper" \
        '{schema_version:1,components:[$ghostty,$wrapper]}' > "$destination/manifest.json"
    check_notices "$destination"
}

case ${1:-} in
    --check) check_notices "${2:?notice directory required}" ;;
    --compare)
        check_notices "${2:?first notice directory required}"
        check_notices "${3:?second notice directory required}"
        diff -r "$2" "$3"
        ;;
    --verify-source)
        temporary=$(mktemp -d)
        trap 'rm -rf "$temporary"' EXIT
        stage "${2:?source required}" "$temporary/Licenses"
        diff -r "${3:?staged notice directory required}" "$temporary/Licenses"
        ;;
    *) stage "${1:?source required}" "${2:?destination required}" ;;
esac
