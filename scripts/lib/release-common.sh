#!/usr/bin/env bash
# Shared helpers for release-* scripts. Pure functions where possible.
# Sourced by scripts/release-*.sh and tests/test-release-common.sh.

set -euo pipefail

# json_escape: escape a string for safe JSON inclusion (basic — handles
# the chars a tag or commit might contain).
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# compute_next_rc_version <marketing_version> <newline_separated_tags>
# Emits JSON: {"version":"<MV>-rc.<N>","confirm_marketing":<bool>,"notes_base":"<tag>"}
compute_next_rc_version() {
    local marketing_version="$1"
    local tags="$2"

    local rc_tags last_rc last_num next_rc_num
    rc_tags=$(printf '%s\n' "$tags" \
        | grep -E "^v${marketing_version//./\\.}-rc\\.[0-9]+$" \
        | sort -V \
        || true)

    local confirm_marketing="false"
    local notes_base=""

    if [[ -z "$rc_tags" ]]; then
        next_rc_num=1
        local prev_final
        prev_final=$(printf '%s\n' "$tags" \
            | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
            | sort -V \
            | tail -1 \
            || true)
        if [[ -n "$prev_final" ]]; then
            confirm_marketing="true"
            notes_base="$prev_final"
        fi
    else
        last_rc=$(printf '%s\n' "$rc_tags" | tail -1)
        last_num="${last_rc##*-rc.}"
        next_rc_num=$((last_num + 1))
        notes_base="$last_rc"
    fi

    printf '{"version":"%s-rc.%s","confirm_marketing":%s,"notes_base":"%s"}\n' \
        "$(json_escape "$marketing_version")" \
        "$next_rc_num" \
        "$confirm_marketing" \
        "$(json_escape "$notes_base")"
}

# compute_final_version <marketing_version> <newline_separated_tags> <rc_commit_sha>
# Emits JSON: {"version":"<MV>","rc_tag":"<tag>","commit":"<sha>","notes_base":"<tag>"}
# Errors (exits non-zero) if no RC exists for the marketing version.
compute_final_version() {
    local marketing_version="$1"
    local tags="$2"
    local rc_commit="$3"

    local rc_tags last_rc
    rc_tags=$(printf '%s\n' "$tags" \
        | grep -E "^v${marketing_version//./\\.}-rc\\.[0-9]+$" \
        | sort -V \
        || true)

    if [[ -z "$rc_tags" ]]; then
        printf 'compute_final_version: no RC tag exists for marketing version %s\n' \
            "$marketing_version" >&2
        return 1
    fi
    last_rc=$(printf '%s\n' "$rc_tags" | tail -1)

    local prev_final
    prev_final=$(printf '%s\n' "$tags" \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -V \
        | tail -1 \
        || true)

    printf '{"version":"%s","rc_tag":"%s","commit":"%s","notes_base":"%s"}\n' \
        "$(json_escape "$marketing_version")" \
        "$(json_escape "$last_rc")" \
        "$(json_escape "$rc_commit")" \
        "$(json_escape "$prev_final")"
}

# read_marketing_version_from_project_yml [path]
# Reads MARKETING_VERSION from project.yml. Path defaults to ./project.yml.
read_marketing_version_from_project_yml() {
    local path="${1:-project.yml}"
    grep -E '^[[:space:]]*MARKETING_VERSION:' "$path" | head -1 | sed 's/.*"\([^"]*\)".*/\1/'
}

# read_all_tags
# Returns newline-separated list of all tags in the current repo.
read_all_tags() {
    git tag -l
}
