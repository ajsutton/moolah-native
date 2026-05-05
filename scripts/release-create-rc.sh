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

# Refuse if HEAD isn't on main — guards against tagging a stray local branch.
branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$branch" != "main" ]]; then
    printf 'must be on main to cut an RC; HEAD is on %s\n' "$branch" >&2
    exit 1
fi

# Pin to local HEAD instead of `--target main`. `--target main` resolves
# server-side at API-call time, so a PR that lands between preflight and now
# would silently bump the release commit. Tagging the SHA gives the operator
# the same commit they preflighted.
target_sha=$(git rev-parse HEAD)

gh release create "$tag" \
    --target "$target_sha" \
    --title "$tag" \
    --notes-file "$notes_file" \
    --prerelease

printf '✓ created GH pre-release %s at %s; release-rc.yml will fire shortly\n' "$tag" "$target_sha"
printf '  watch: just release-wait %s\n' "$tag"
