#!/usr/bin/env bash
# Computes the proposed version for the next RC or final tag.
# Usage: release-next-version (rc|final)
# Output: JSON on stdout. See compute_next_rc_version / compute_final_version
# in lib/release-common.sh for the schema.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/release-common.sh"

usage() {
    printf 'Usage: %s (rc|final)\n' "$(basename "$0")" >&2
    exit 2
}

[[ "$#" -eq 1 ]] || usage

kind="$1"
mv=$(read_marketing_version_from_project_yml)
[[ -n "$mv" ]] || { echo "could not read MARKETING_VERSION from project.yml" >&2; exit 1; }

tags=$(read_all_tags)

case "$kind" in
    rc)
        compute_next_rc_version "$mv" "$tags"
        ;;
    final)
        # Find the latest RC for this marketing version to resolve the commit SHA.
        last_rc=$(printf '%s\n' "$tags" \
            | grep -E "^v${mv//./\\.}-rc\\.[0-9]+$" \
            | sort -V \
            | tail -1 \
            || true)
        if [[ -z "$last_rc" ]]; then
            printf 'no RC tag exists for marketing version %s — cut an RC first\n' \
                "$mv" >&2
            exit 1
        fi
        rc_commit=$(git rev-list -n 1 "$last_rc")
        compute_final_version "$mv" "$tags" "$rc_commit"
        ;;
    *)
        usage
        ;;
esac
