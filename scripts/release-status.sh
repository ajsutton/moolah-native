#!/usr/bin/env bash
# Prints a human-readable summary of a release: workflow status, GH
# release assets, and (for final tags) App Store submission state.
#
# Usage: release-status TAG
set -euo pipefail

[[ "$#" -eq 1 ]] || {
    printf 'Usage: %s TAG\n' "$(basename "$0")" >&2
    exit 2
}

tag="$1"

if [[ "$tag" == *-rc.* ]]; then
    workflow="release-rc.yml"
else
    workflow="release-final.yml"
fi

printf '== Release %s ==\n' "$tag"

# GH release.
if gh release view "$tag" >/dev/null 2>&1; then
    printf '\nGitHub release:\n'
    gh release view "$tag" --json tagName,isPrerelease,createdAt,assets \
        --jq '"  tag:        \(.tagName)\n  prerelease: \(.isPrerelease)\n  created:    \(.createdAt)\n  assets:     \([.assets[].name] | join(", "))"'
else
    printf '\nGitHub release: NOT FOUND\n'
fi

# Workflow run.
printf '\nWorkflow:\n'
run_status=$(gh run list --workflow="$workflow" --branch="$tag" \
    --limit 1 --json status,conclusion,databaseId,createdAt --jq '.[0]' 2>/dev/null || true)
if [[ -z "$run_status" || "$run_status" == "null" ]]; then
    printf '  no run found for %s\n' "$workflow"
else
    printf '%s' "$run_status" \
        | jq -r '"  workflow:   '"$workflow"'\n  run id:     \(.databaseId)\n  status:     \(.status)\n  conclusion: \(.conclusion // "-")\n  created:    \(.createdAt)"'
fi
