#!/usr/bin/env bash
# Scan tracked files for TODO / FIXME references and classify them.
#
# A "real" TODO / FIXME is TODO or FIXME followed directly by `:` or `(`.
# (That matches Xcode's recognised form; prose like `"TODO"` or
# `TODO / FIXME hygiene` is not a real TODO and is ignored.)
#
# Markdown backtick-spans (`...`) are stripped before classification so
# documentation that mentions `TODO:` as an example isn't flagged.
#
# Output (tab-delimited, on stdout):
#   VALID <issue-number> <file>:<line> <matched-text>
#   BARE  <file>:<line> <matched-text>
#
# Scope: all tracked files except anything under plans/. See CODE_GUIDE §20.
#
# Usage:
#   bash scripts/lib/todo-extract.sh             # emit stream for the repo
#   bash scripts/lib/todo-extract.sh <file>...   # scan specific files (for tests)
#   bash scripts/lib/todo-extract.sh --self-test # run built-in fixture tests

set -euo pipefail

extract_todos() {
    local files=()
    if [[ $# -gt 0 ]]; then
        files=("$@")
    else
        while IFS= read -r -d '' f; do
            files+=("$f")
        done < <(git ls-files -z -- ':(exclude)plans/')
    fi

    if [[ ${#files[@]} -eq 0 ]]; then
        return 0
    fi

    # Candidate lines: TODO or FIXME followed by `:` or `(`.
    # -H: always print filename. -n: line numbers. -I: skip binary files.
    # -E: extended regex. -i: case-insensitive.
    local hits
    hits=$(grep -HnIEi '(TODO|FIXME)[(:]' -- "${files[@]}" 2>/dev/null || true)

    if [[ -z "$hits" ]]; then
        return 0
    fi

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Format: <file>:<lineno>:<text>. Text may contain colons.
        local text location cleaned
        text=${line#*:*:}
        location=${line%":$text"}

        # Markdown: skip hits inside triple-backtick fenced code blocks.
        # Teaching examples in fences are documentation, not references.
        local file_part line_part
        file_part=${location%:*}
        line_part=${location##*:}
        if [[ "$file_part" == *.md ]]; then
            local fence_count
            fence_count=$(head -n "$line_part" "$file_part" 2>/dev/null | grep -cE '^[[:space:]]*```' || true)
            if (( fence_count % 2 == 1 )); then
                continue
            fi
        fi

        # Strip single-backtick spans so documentation examples (`TODO:`,
        # `TODO(#N)`) don't false-positive. Paired backticks only.
        cleaned=$(sed 's/`[^`]*`//g' <<< "$text")

        local ref
        ref=$(grep -oEi '(TODO|FIXME)\(#[0-9]+\)' <<< "$cleaned" | head -n1 || true)
        if [[ -n "$ref" ]]; then
            local num
            num=$(grep -oE '[0-9]+' <<< "$ref")
            printf 'VALID\t%s\t%s\t%s\n' "$num" "$location" "$text"
        elif grep -qEi '(TODO|FIXME)[(:]' <<< "$cleaned"; then
            printf 'BARE\t%s\t%s\n' "$location" "$text"
        fi
        # Else: the only TODO/FIXME on this line was inside backticks; suppress.
    done <<< "$hits"
}

self_test() {
    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    cat > "$tmpdir/valid.swift" <<'SWIFT'
// TODO(#123): drop legacy sync path
// FIXME(#456): race condition
SWIFT

    cat > "$tmpdir/bare.swift" <<'SWIFT'
// TODO: needs rework
// FIXME: needs a ticket
SWIFT

    cat > "$tmpdir/innocuous.swift" <<'SWIFT'
let TODOsCount = 0
let statusBar = "task complete"
let nope = "TODO"
SWIFT

    cat > "$tmpdir/docs.md" <<'MARKDOWN'
Bare `TODO:` / `FIXME:` without a reference is disallowed.
Mentions of TODO / FIXME in prose should not trip the check.
Reference form: `TODO(#N)` format.
MARKDOWN

    local output valid_count bare_count
    output=$(extract_todos \
        "$tmpdir/valid.swift" \
        "$tmpdir/bare.swift" \
        "$tmpdir/innocuous.swift" \
        "$tmpdir/docs.md")
    valid_count=$(grep -c '^VALID' <<< "$output" || true)
    bare_count=$(grep -c '^BARE' <<< "$output" || true)

    local ok=1
    [[ "$valid_count" == "2" ]] || ok=0
    [[ "$bare_count" == "2" ]] || ok=0
    grep -q $'^VALID\t123\t' <<< "$output" || ok=0
    grep -q $'^VALID\t456\t' <<< "$output" || ok=0

    if [[ $ok -eq 1 ]]; then
        echo "todo-extract self-test PASS (2 VALID, 2 BARE, doc mentions suppressed)"
        return 0
    fi

    echo "todo-extract self-test FAIL" >&2
    echo "expected 2 VALID / 2 BARE; got $valid_count VALID / $bare_count BARE" >&2
    echo "--- output ---" >&2
    echo "$output" >&2
    return 1
}

case "${1:-}" in
    --self-test) self_test ;;
    *) extract_todos "$@" ;;
esac
