#!/usr/bin/env bash
#
# Imports CloudKit/schema.ckdb to the Development environment as a staging
# step before a manual CloudKit Console "Deploy Schema Changes to
# Production" click.
#
# The release pipeline runs this when verify-prod-deployed reports the
# Production schema is behind. Resetting Dev first ensures the Console's
# diff view shows exactly what would be promoted, with no developer-side
# pollution.
#
# DESTRUCTIVE side-effect on the team's Development CloudKit container —
# any pending dev experiments will be wiped. See plans/2026-04-26-release-
# process-design.md and issue for separating the test/dev container from
# the release-pipeline container.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/cloudkit-config.sh
source "$HERE/cloudkit-config.sh"

cloudkit_require_env

[ -f "$CLOUDKIT_SCHEMA_FILE" ] \
    || cloudkit_fail "$CLOUDKIT_SCHEMA_FILE is missing."

echo "Resetting Development schema to match Production…"
cloudkit_cktool reset-schema --environment development

echo "Validating $CLOUDKIT_SCHEMA_FILE against Development (dry-run)…"
cloudkit_cktool import-schema \
    --environment development \
    --validate \
    --file "$CLOUDKIT_SCHEMA_FILE"

echo "Importing $CLOUDKIT_SCHEMA_FILE to Development…"
cloudkit_cktool import-schema \
    --environment development \
    --file "$CLOUDKIT_SCHEMA_FILE"

cat <<EOF

✓ Development now mirrors $CLOUDKIT_SCHEMA_FILE.

Open https://icloud.developer.apple.com/dashboard/ for container
$CLOUDKIT_CONTAINER_ID and click Schema → Deploy Schema Changes to
Production. Review the diff, confirm Deploy.
EOF
