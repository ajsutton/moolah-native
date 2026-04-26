#!/usr/bin/env bash
# Verifies the local repo is in a state suitable for cutting a release.
# Exits zero on success, non-zero with a descriptive message on failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/release-common.sh"

fail() {
    printf '✗ %s\n' "$1" >&2
    exit 1
}

# 1. On main branch.
branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$branch" != "main" ]]; then
    fail "must be on main (currently on '$branch')"
fi

# 2. Working tree is clean.
if ! git diff-index --quiet HEAD --; then
    fail "working tree has uncommitted changes"
fi
if [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    fail "working tree has untracked files"
fi

# 3. In sync with origin/main.
git fetch origin main --quiet
local_sha=$(git rev-parse HEAD)
remote_sha=$(git rev-parse origin/main)
if [[ "$local_sha" != "$remote_sha" ]]; then
    fail "local main ($local_sha) is not in sync with origin/main ($remote_sha)"
fi

# 4. gh authenticated.
if ! gh auth status >/dev/null 2>&1; then
    fail "gh CLI is not authenticated (run 'gh auth login')"
fi

# 5. Latest CI run on main passed.
ci_status=$(gh run list --branch main --limit 1 \
    --json status,conclusion --jq '.[0] | "\(.status):\(.conclusion)"')
case "$ci_status" in
    completed:success) ;;
    completed:*) fail "latest CI run on main concluded as ${ci_status#completed:}" ;;
    in_progress:*|queued:*) fail "CI is still running on main; wait for it to finish" ;;
    *) fail "unexpected CI status '$ci_status'" ;;
esac

printf '✓ release-preflight passed\n'
printf '  branch: %s\n' "$branch"
printf '  HEAD:   %s\n' "$local_sha"
