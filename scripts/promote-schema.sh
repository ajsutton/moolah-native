#!/usr/bin/env bash
#
# Release-tag CI: validates CloudKit/schema.ckdb against Development, then
# imports it to Production. Exports the resulting Production schema into
# the baseline file and opens a follow-up PR that commits the refreshed
# baseline.
#
# Apple's cktool `--validate` flag is dry-run-only; the API rejects it
# against the `production` environment ("BadRequestException: endpoint
# not applicable in the environment 'production'"). So we --validate
# against Development as a sanity check on the schema file's internal
# validity, then do the real import against Production.
#
# We deliberately do NOT reset Dev to Production state first. Dev is
# sandboxed: whatever state it's in doesn't affect Production's import.
# Production safety comes from two additivity invariants that hold
# before this script runs:
#   - `just check-schema-additive` (per-PR) — proposed schema is
#     additive over the committed baseline file.
#   - `just verify-prod-matches-baseline` (release-time, runs
#     immediately before this script) — live Production matches the
#     committed baseline.
# Together: live Production ≤ proposed schema, so the Prod import is
# mathematically safe regardless of Dev's state. The Dev validate is a
# best-effort sanity check that catches malformed schema files cheaply
# before we touch Prod.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/cloudkit-config.sh
source "$HERE/cloudkit-config.sh"

cloudkit_require_env

[ -f "$CLOUDKIT_SCHEMA_FILE" ] \
    || cloudkit_fail "$CLOUDKIT_SCHEMA_FILE is missing."

baseline="CloudKit/schema-prod-baseline.ckdb"

# Step 1: dry-run validation against Development (sanity check only).
# We don't reset Dev first — its state is uncontrolled and irrelevant to
# Prod's import. This catches malformed schema files cheaply; the real
# safety net for Prod is the additivity invariants documented above.
echo "Step 1/2: validating $CLOUDKIT_SCHEMA_FILE against Development."
cloudkit_cktool import-schema \
    --environment development \
    --validate \
    --file "$CLOUDKIT_SCHEMA_FILE"
echo "Dev-side validation passed."

# Step 2: actually import to Production.
echo "Step 2/2: importing $CLOUDKIT_SCHEMA_FILE to Production."
cloudkit_cktool import-schema \
    --environment production \
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
