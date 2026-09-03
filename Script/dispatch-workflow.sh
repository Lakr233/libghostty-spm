#!/bin/bash

# Dispatch a workflow on main and wait for the run it starts, failing with
# it. `gh workflow run` returns before the run exists, so the new run is
# the first one listed after the dispatch that was not there before.
#
#   Script/dispatch-workflow.sh <workflow file> [-f key=value ...]

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[!] repository root not found. Run this script from a libghostty-spm checkout."
    exit 1
fi

WORKFLOW=${1:-}
if [ -z "$WORKFLOW" ]; then
    echo "Usage: $0 <workflow file> [-f key=value ...]"
    exit 1
fi
shift

latest_run() {
    gh run list --workflow "$WORKFLOW" --branch main --limit 1 --json databaseId --jq '.[0].databaseId // 0'
}

before=$(latest_run)
gh workflow run "$WORKFLOW" --ref main "$@"
echo "[*] dispatched $WORKFLOW"

run_id=$before
for _ in $(seq 1 60); do
    sleep 5
    run_id=$(latest_run)
    [ "$run_id" != "$before" ] && break
done
if [ "$run_id" = "$before" ]; then
    echo "[!] no new $WORKFLOW run appeared"
    exit 1
fi

echo "[*] watching run $run_id"
gh run watch "$run_id" --exit-status --interval 30
