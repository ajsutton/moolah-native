#!/usr/bin/env bash
#
# Verifies that the live Production schema matches CloudKit/schema.ckdb (the
# committed source of truth). Used by release-rc.yml as the gate that proves
# a Console-deploy has been performed.
#
# Apple's API does not expose a way to write schema to Production via cktool
# — the only path is the CloudKit Console's "Deploy Schema Changes to
# Production" button. This script is the verification half of that handoff:
# after a developer clicks Deploy in the Console, this script confirms the
# bytes landed.
#
# Exits 0 if Production matches schema.ckdb; non-zero with a descriptive
# message and the diff if it doesn't.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/cloudkit-config.sh
source "$HERE/cloudkit-config.sh"

cloudkit_require_env

[ -f "$CLOUDKIT_SCHEMA_FILE" ] \
    || cloudkit_fail "$CLOUDKIT_SCHEMA_FILE is missing."

live=$(mktemp)
trap 'rm -f "$live"' EXIT

cloudkit_cktool export-schema \
    --environment production \
    --output-file "$live" >/dev/null

if cmp -s "$live" "$CLOUDKIT_SCHEMA_FILE"; then
    echo "✓ live Production schema matches $CLOUDKIT_SCHEMA_FILE"
    exit 0
fi

cat >&2 <<EOF
✗ live Production schema does not match $CLOUDKIT_SCHEMA_FILE.

The proposed schema has not been deployed to Production. Apple's API does
not expose a CLI path for production schema deploys — the only way to
deploy is the CloudKit Console:

  1. Open https://icloud.developer.apple.com/dashboard/ for container
     $CLOUDKIT_CONTAINER_ID.
  2. Schema → Deploy Schema Changes to Production.
  3. Review the diff (Dev should already match schema.ckdb if this script
     ran via the release pipeline; if not, run 'just import-schema-to-dev'
     first).
  4. Confirm Deploy.

Diff (live Production vs. proposed schema.ckdb):
EOF
diff -u "$live" "$CLOUDKIT_SCHEMA_FILE" >&2 || true
exit 1
