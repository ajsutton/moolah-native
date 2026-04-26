#!/usr/bin/env bash
# Creates a GitHub pre-release at HEAD with the given notes file.
# Creating the GH release also creates the underlying tag, which fires
# release-rc.yml. Errors if a release with the requested tag already exists.
#
# Usage: release-create-rc VERSION NOTES_FILE
#   VERSION:    semver+rc form (e.g. "1.2.0-rc.1")
#   NOTES_FILE: path to a markdown file containing the release notes
set -euo pipefail

[[ "$#" -eq 2 ]] || {
    printf 'Usage: %s VERSION NOTES_FILE\n' "$(basename "$0")" >&2
    exit 2
}

version="$1"
notes_file="$2"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]] || {
    printf 'invalid RC version: %s (expected X.Y.Z-rc.N)\n' "$version" >&2
    exit 1
}

[[ -f "$notes_file" ]] || {
    printf 'notes file does not exist: %s\n' "$notes_file" >&2
    exit 1
}

tag="v${version}"

# Refuse if release already exists.
if gh release view "$tag" >/dev/null 2>&1; then
    printf 'release %s already exists\n' "$tag" >&2
    exit 1
fi

gh release create "$tag" \
    --target main \
    --title "$tag" \
    --notes-file "$notes_file" \
    --prerelease

printf '✓ created GH pre-release %s; release-rc.yml will fire shortly\n' "$tag"
printf '  watch: just release-wait %s\n' "$tag"
