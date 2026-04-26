#!/usr/bin/env bash
# Polls the workflow run associated with a tag until terminal.
# Exits zero on success; the workflow's conclusion code otherwise.
#
# Usage: release-wait TAG
set -euo pipefail

[[ "$#" -eq 1 ]] || {
    printf 'Usage: %s TAG\n' "$(basename "$0")" >&2
    exit 2
}

tag="$1"

# Determine which workflow file matches the tag pattern.
if [[ "$tag" == *-rc.* ]]; then
    workflow="release-rc.yml"
else
    workflow="release-final.yml"
fi

# Find the most recent run on this tag's ref.
# (`gh run list --branch <tag>` matches workflow runs whose head_branch
# equals the tag name — the case for tag-triggered workflows.)
run_id=""
for _ in {1..30}; do
    run_id=$(gh run list --workflow="$workflow" --branch="$tag" \
        --limit 1 --json databaseId --jq '.[0].databaseId // empty')
    [[ -n "$run_id" ]] && break
    sleep 2
done

if [[ -z "$run_id" ]]; then
    printf 'no workflow run found for %s on %s after 60s\n' "$workflow" "$tag" >&2
    exit 1
fi

printf 'watching %s run %s for tag %s\n' "$workflow" "$run_id" "$tag"
gh run watch "$run_id" --exit-status
