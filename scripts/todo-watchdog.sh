#!/usr/bin/env bash
# Daily reconciliation for TODO / FIXME references.
#
# Invariant maintained: the `has-todos` label is applied to exactly the set of
# issues (open or closed) that are referenced by at least one live
# `TODO(#N)` / `FIXME(#N)` comment in the checked-out tree.
#
# Side effects:
#   - Closed issues with live references are reopened and commented on.
#   - Open issues without the label gain it.
#   - Labeled issues without live references lose the label.
#
# Invoked from .github/workflows/todo-issue-watchdog.yml (cron, daily).
# Requires: gh (authenticated via GITHUB_TOKEN).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL='has-todos'

main() {
    local stream valid_lines
    stream=$(bash "$SCRIPT_DIR/lib/todo-extract.sh")
    valid_lines=$(grep '^VALID' <<< "$stream" || true)

    local referenced=""
    if [[ -n "$valid_lines" ]]; then
        referenced=$(cut -f2 <<< "$valid_lines" | sort -un)
    fi

    local labeled
    labeled=$(gh issue list \
        --label "$LABEL" \
        --state all \
        --limit 1000 \
        --json number \
        --jq '.[].number' 2>/dev/null | sort -un || true)

    if [[ -n "$referenced" ]]; then
        while IFS= read -r num; do
            [[ -z "$num" ]] && continue
            reconcile_referenced_issue "$num" "$valid_lines"
        done <<< "$referenced"
    fi

    if [[ -n "$labeled" ]]; then
        while IFS= read -r num; do
            [[ -z "$num" ]] && continue
            if ! grep -qx "$num" <<< "$referenced"; then
                echo "→ Removing '$LABEL' from #$num (no live TODO references)"
                gh issue edit "$num" --remove-label "$LABEL" >/dev/null 2>&1 || true
            fi
        done <<< "$labeled"
    fi

    echo "Watchdog done."
}

reconcile_referenced_issue() {
    local num=$1 valid_lines=$2
    local state
    if ! state=$(gh api "repos/{owner}/{repo}/issues/$num" --jq '.state' 2>/dev/null); then
        echo "::warning::TODO references point at missing issue #$num (skipping)"
        return 0
    fi

    local locations
    locations=$(awk -F'\t' -v n="$num" '
        $1 == "VALID" && $2 == n { print "  - " $3 }
    ' <<< "$valid_lines")

    if [[ "$state" == "closed" ]]; then
        echo "→ Reopening #$num (referenced by live TODOs)"
        gh issue reopen "$num" >/dev/null
        local body
        body=$(printf 'Reopened automatically: live `TODO(#%s)` / `FIXME(#%s)` comments still reference this issue.\n\nReferences on `main`:\n\n%s\n\nRemove the TODO(s), or if the work is still pending, leave the issue open. Closing while live references exist will be undone by the next run of the [TODO Issue Watchdog](.github/workflows/todo-issue-watchdog.yml).' "$num" "$num" "$locations")
        gh issue comment "$num" --body "$body" >/dev/null
        gh issue edit "$num" --add-label "$LABEL" >/dev/null
        return 0
    fi

    # Open issue: ensure label applied.
    local has_label
    has_label=$(gh issue view "$num" --json labels \
        --jq ".labels[] | select(.name==\"$LABEL\") | .name" 2>/dev/null || true)
    if [[ -z "$has_label" ]]; then
        echo "→ Adding '$LABEL' to open #$num"
        gh issue edit "$num" --add-label "$LABEL" >/dev/null
    fi
}

main "$@"
