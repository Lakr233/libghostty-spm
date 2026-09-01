#!/bin/zsh
# Refuses GPL-family license text anywhere in the tracked tree.
#
# This package is MIT and ships its resource bundle into every host app, so a
# GPL file here becomes a GPL redistribution obligation for every downstream.
# Ghostty's bash and zsh shell integration (derived from Kitty) is GPLv3 and
# was merged twice by accident (PR #40 was refused for it; PR #43 brought it
# back under another title and it shipped in 1.4.0 through 1.5.0). The
# integration under Resources/Ghostty/shell-integration is our own MIT
# rewrite; this script is what keeps the upstream files from coming back.
#
# Runs in pr.yml and release.yml. Exit 1 on any hit.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .root ]] || { echo "[-] run from the repository"; exit 1; }

# Markers, case-insensitive. Kept to license *text* and SPDX identifiers so
# that prose about the policy (this file, AGENTS.md) does not trip it; a
# license header always carries one of these. The bracketed letter keeps the
# license name itself out of this file, so a plain grep of the tree — and of
# its history, which was rewritten to drop the upstream scripts — finds
# nothing.
patterns=(
    'GNU (Lesser |Affero )?General Public Licen[s]e'
    'SPDX-License-Identifier: *[AL]?GPL'
    'distributed under (the )?(GNU )?[AL]?GPL'
    'licensed under (the )?(GNU )?[AL]?GPL'
    'under the terms of the GN[U]'
    'www\.gnu\.org/licenses/(a|l)?gpl'
)

failed=0
for pattern in "${patterns[@]}"; do
    hits="$(git grep -I -n -i -E -- "$pattern" -- . ':(exclude)Script/check-licenses.sh' || true)"
    if [[ -n "$hits" ]]; then
        echo "[-] GPL license text matched /$pattern/:"
        print -r -- "$hits" | sed 's/^/    /'
        failed=1
    fi
done

# The resource bundle may hold exactly the files we wrote or vendored under
# MIT — nothing from upstream's shell-integration tree.
expected_integration=(
    bash/LICENSE-bash-preexec.md
    bash/bash-preexec.sh
    bash/ghostty.bash
    zsh/.zshenv
    zsh/ghostty-integration
)
integration_dir=Sources/GhosttyTerminal/Resources/Ghostty/shell-integration
if ! diff_output="$(diff \
    <(print -l -- "${expected_integration[@]}" | LC_ALL=C sort) \
    <(git ls-files "$integration_dir" | sed "s|^$integration_dir/||" | LC_ALL=C sort))"; then
    echo "[-] $integration_dir holds files other than the MIT set (< expected, > found):"
    print -r -- "$diff_output" | sed 's/^/    /'
    failed=1
fi

if (( failed == 0 )); then
    echo "[+] no GPL license text; shell-integration holds only the MIT files"
fi
exit $failed
