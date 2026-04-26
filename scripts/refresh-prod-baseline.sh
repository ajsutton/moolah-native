#!/usr/bin/env bash
#
# Exports the live CloudKit Production schema into
# CloudKit/schema-prod-baseline.ckdb. If the file changed, opens a follow-up
# PR. Run by release-rc.yml after a successful release so that
# `just check-schema-additive` on subsequent PRs runs against an
# up-to-date baseline.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/cloudkit-config.sh
source "$HERE/cloudkit-config.sh"

cloudkit_require_env

baseline="CloudKit/schema-prod-baseline.ckdb"

cloudkit_cktool export-schema \
    --environment production \
    --output-file "$baseline"
echo "Exported live Production schema to $baseline."

if git -C "$(pwd)" diff --quiet -- "$baseline"; then
    echo "$baseline unchanged; nothing to commit."
    exit 0
fi

git -C "$(pwd)" config user.name "github-actions[bot]"
git -C "$(pwd)" config user.email "41898282+github-actions[bot]@users.noreply.github.com"

branch="cloudkit-baseline-refresh-$(date -u +%Y%m%d-%H%M%S)"
git -C "$(pwd)" checkout -b "$branch"
git -C "$(pwd)" add "$baseline"
git -C "$(pwd)" commit -m "chore(cloudkit): refresh schema-prod-baseline after deploy"
git -C "$(pwd)" push -u origin "$branch"

gh pr create \
    --title "chore(cloudkit): refresh schema-prod-baseline after deploy" \
    --body "$(cat <<EOF
Auto-generated after a successful CloudKit Production schema deploy.
Refreshes \`CloudKit/schema-prod-baseline.ckdb\` to match the new live
Production schema. Subsequent PRs run \`just check-schema-additive\`
against this updated baseline.
EOF
)"
