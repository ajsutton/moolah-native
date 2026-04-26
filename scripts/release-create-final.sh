#!/usr/bin/env bash
# Creates a GitHub release at the same commit as the named RC tag.
# Creating the GH release also creates the final tag at that commit,
# which fires release-final.yml.
#
# Usage: release-create-final VERSION RC_TAG NOTES_FILE
#   VERSION:    semver form (e.g. "1.2.0")
#   RC_TAG:     the RC tag to promote (e.g. "v1.2.0-rc.3")
#   NOTES_FILE: path to a markdown file with end-user release notes
set -euo pipefail

[[ "$#" -eq 3 ]] || {
    printf 'Usage: %s VERSION RC_TAG NOTES_FILE\n' "$(basename "$0")" >&2
    exit 2
}

version="$1"
rc_tag="$2"
notes_file="$3"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'invalid final version: %s (expected X.Y.Z)\n' "$version" >&2
    exit 1
}

[[ "$rc_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]] || {
    printf 'invalid RC tag: %s (expected vX.Y.Z-rc.N)\n' "$rc_tag" >&2
    exit 1
}

[[ -f "$notes_file" ]] || {
    printf 'notes file does not exist: %s\n' "$notes_file" >&2
    exit 1
}

# Ensure the supplied RC is the latest for this marketing version.
# The release-final.yml workflow looks up the latest RC and verifies the
# final tag points at the same commit; promoting an older RC would fail
# in CI. Catch it locally with a clearer error.
latest_rc=$(git tag -l "v${version}-rc.*" | sort -V | tail -1)
if [[ -z "$latest_rc" ]]; then
    printf 'no RC tag exists for marketing version %s — cut an RC first\n' \
        "$version" >&2
    exit 1
fi
if [[ "$rc_tag" != "$latest_rc" ]]; then
    printf 'cannot promote %s: latest RC for %s is %s. Either smoke-test the latest RC or cut a fresh one.\n' \
        "$rc_tag" "$version" "$latest_rc" >&2
    exit 1
fi

# Resolve the RC's commit. git rev-list errors if the tag is unknown.
rc_commit=$(git rev-list -n 1 "$rc_tag")

final_tag="v${version}"

if gh release view "$final_tag" >/dev/null 2>&1; then
    printf 'release %s already exists\n' "$final_tag" >&2
    exit 1
fi

gh release create "$final_tag" \
    --target "$rc_commit" \
    --title "$final_tag" \
    --notes-file "$notes_file"

printf '✓ created GH release %s at commit %s (same commit as %s)\n' \
    "$final_tag" "$rc_commit" "$rc_tag"
printf '  watch: just release-wait %s\n' "$final_tag"
