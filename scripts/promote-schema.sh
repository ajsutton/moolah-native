#!/usr/bin/env bash
#
# Release-tag CI: imports CloudKit/schema.ckdb to Production with --validate,
# exports the resulting Production schema into the baseline file, and opens
# a follow-up PR that commits the refreshed baseline.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/cloudkit-config.sh
source "$HERE/cloudkit-config.sh"

cloudkit_require_env

[ -f "$CLOUDKIT_SCHEMA_FILE" ] \
    || cloudkit_fail "$CLOUDKIT_SCHEMA_FILE is missing."

baseline="CloudKit/schema-prod-baseline.ckdb"

cloudkit_cktool import-schema \
    --environment production \
    --validate \
    --file "$CLOUDKIT_SCHEMA_FILE"
echo "Promoted $CLOUDKIT_SCHEMA_FILE to CloudKit Production."

cloudkit_cktool export-schema \
    --environment production \
    --output-file "$baseline"
echo "Refreshed $baseline from live Production."

# If the export changed the baseline, open a follow-up PR. The baseline
# only needs to be updated when the schema actually changed.
if git -C "$(pwd)" diff --quiet -- "$baseline"; then
    echo "$baseline unchanged; nothing to commit."
    exit 0
fi

# Configure git for the bot commit (CI context — no global identity).
git -C "$(pwd)" config user.name "github-actions[bot]"
git -C "$(pwd)" config user.email "41898282+github-actions[bot]@users.noreply.github.com"

branch="cloudkit-baseline-refresh-$(date -u +%Y%m%d-%H%M%S)"
git -C "$(pwd)" checkout -b "$branch"
git -C "$(pwd)" add "$baseline"
git -C "$(pwd)" commit -m "chore(cloudkit): refresh schema-prod-baseline after promote"
git -C "$(pwd)" push -u origin "$branch"

gh pr create \
    --title "chore(cloudkit): refresh schema-prod-baseline after promote" \
    --body "$(cat <<EOF
Auto-generated after a successful CloudKit Production schema promote.
Refreshes \`CloudKit/schema-prod-baseline.ckdb\` to match the new live
Production schema. Subsequent PRs run \`just check-schema-additive\`
against this updated baseline.
EOF
)"
