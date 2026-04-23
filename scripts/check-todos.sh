#!/usr/bin/env bash
# Pre-merge gate for TODO / FIXME comments.
#
# Fails if:
#   1. Any tracked file (outside plans/) contains a bare `TODO` / `FIXME`
#      without a `(#N)` issue reference.
#   2. Any `TODO(#N)` / `FIXME(#N)` reference points at a closed or
#      non-existent GitHub issue. (Skipped when gh is not authenticated —
#      typical on fork PRs where the token is intentionally withheld.)
#
# Flags:
#   --format-only   Skip the liveness check even if gh is authenticated.
#                   Used on fork-PR events where we don't want the token
#                   exposed to untrusted code paths at all.
#
# See guides/CODE_GUIDE.md §20. Enforcement closes #249.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

main() {
    local format_only=0
    if [[ "${1:-}" == "--format-only" ]]; then
        format_only=1
    fi

    local stream
    stream=$(bash "$SCRIPT_DIR/lib/todo-extract.sh")

    local bare_lines valid_lines
    bare_lines=$(grep '^BARE' <<< "$stream" || true)
    valid_lines=$(grep '^VALID' <<< "$stream" || true)

    local failed=0

    if [[ -n "$bare_lines" ]]; then
        echo "✗ Bare TODO / FIXME found (must reference an open GitHub issue; see CODE_GUIDE §20):"
        while IFS=$'\t' read -r _kind location text; do
            printf '    %s\n        %s\n' "$location" "$text"
        done <<< "$bare_lines"
        echo
        echo "  Fix: add an open GitHub issue reference in the form described in CODE_GUIDE §20."
        echo
        failed=1
    fi

    if [[ -n "$valid_lines" && $format_only -eq 0 ]] && gh auth status >/dev/null 2>&1; then
        local unique_issues
        unique_issues=$(cut -f2 <<< "$valid_lines" | sort -un)

        # Query each referenced issue once; cache "<num> <state>" pairs.
        local states_file
        states_file=$(mktemp)
        # shellcheck disable=SC2064
        trap "rm -f '$states_file'" EXIT

        while IFS= read -r num; do
            [[ -z "$num" ]] && continue
            local state
            if state=$(gh api "repos/{owner}/{repo}/issues/$num" --jq '.state' 2>/dev/null); then
                echo "$num $state" >> "$states_file"
            else
                echo "$num missing" >> "$states_file"
            fi
        done <<< "$unique_issues"

        local bad_issues
        bad_issues=$(awk '$2 != "open" { print $1 }' "$states_file")

        if [[ -n "$bad_issues" ]]; then
            echo "✗ TODO references point at closed or missing GitHub issue(s):"
            while IFS= read -r num; do
                [[ -z "$num" ]] && continue
                local state
                state=$(awk -v n="$num" '$1 == n { print $2 }' "$states_file")
                printf '  #%s (%s):\n' "$num" "$state"
                awk -F'\t' -v n="$num" '
                    $1 == "VALID" && $2 == n { print "    " $3 }
                ' <<< "$stream"
            done <<< "$bad_issues"
            echo
            echo "  Fix: reopen the issue if the work is still pending, or remove the TODO."
            echo
            failed=1
        fi
    fi

    if [[ $failed -eq 1 ]]; then
        exit 1
    fi

    local live_count
    live_count=$(grep -c '^VALID' <<< "$stream" || true)
    local mode_note=""
    if [[ -n "$valid_lines" ]]; then
        if [[ $format_only -eq 1 ]]; then
            mode_note=" (format only — liveness check skipped on this event)"
        elif ! gh auth status >/dev/null 2>&1; then
            mode_note=" (format only — gh unauthenticated, liveness skipped)"
        fi
    fi
    echo "✓ TODO references clean (${live_count:-0} live reference(s))${mode_note}."
}

main "$@"
