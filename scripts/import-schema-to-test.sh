#!/usr/bin/env bash
#
# Imports CloudKit/schema.ckdb to the Development environment of the test
# container (CLOUDKIT_CONTAINER_ID_TEST = iCloud.rocks.moolah.app.test).
#
# Run this once after creating the test container in App Store Connect to
# bootstrap its Development schema. Re-run any time you want to wipe the
# test container's Dev environment back to the committed schema.
#
# DESTRUCTIVE: cktool reset-schema wipes any schema and data in the test
# container's Development environment. Set CKTOOL_ALLOW_DEV_RESET=1 to
# confirm — same gate as dryrun-promote-schema.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/cloudkit-config.sh
source "$HERE/cloudkit-config.sh"

cloudkit_require_env
CLOUDKIT_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID_TEST"

[ -f "$CLOUDKIT_SCHEMA_FILE" ] \
    || cloudkit_fail "$CLOUDKIT_SCHEMA_FILE is missing."

if [ "${CKTOOL_ALLOW_DEV_RESET:-}" != "1" ]; then
    cat >&2 <<EOF
error: import-schema-to-test resets the $CLOUDKIT_CONTAINER_ID Development
       environment, which wipes any data and schema changes you've made
       there.

       Set CKTOOL_ALLOW_DEV_RESET=1 to confirm.
EOF
    exit 1
fi

echo "Resetting Development schema on $CLOUDKIT_CONTAINER_ID…"
cloudkit_cktool reset-schema

echo "Validating $CLOUDKIT_SCHEMA_FILE against $CLOUDKIT_CONTAINER_ID Development (dry-run)…"
cloudkit_cktool import-schema \
    --environment development \
    --validate \
    --file "$CLOUDKIT_SCHEMA_FILE"

echo "Importing $CLOUDKIT_SCHEMA_FILE to $CLOUDKIT_CONTAINER_ID Development…"
cloudkit_cktool import-schema \
    --environment development \
    --file "$CLOUDKIT_SCHEMA_FILE"

echo "✓ $CLOUDKIT_CONTAINER_ID Development now mirrors $CLOUDKIT_SCHEMA_FILE."
