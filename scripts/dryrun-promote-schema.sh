#!/usr/bin/env bash
#
# Manual local convenience: Apple's recommended Production-equivalent dry-run.
# Resets your personal Development container to match Production, then
# imports the proposed schema with --validate. If this fails, the same
# import would fail on Production.
#
# DESTRUCTIVE: cktool reset-schema wipes any data in your personal Dev.
# Set CKTOOL_ALLOW_DEV_RESET=1 to confirm.
#
# Not run in CI.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/cloudkit-config.sh
source "$HERE/cloudkit-config.sh"

cloudkit_require_env

[ -f "$CLOUDKIT_SCHEMA_FILE" ] \
    || cloudkit_fail "$CLOUDKIT_SCHEMA_FILE is missing."

if [ "${CKTOOL_ALLOW_DEV_RESET:-}" != "1" ]; then
    cat >&2 <<EOF
error: dryrun-promote-schema resets your CloudKit Development environment,
       which wipes any data and schema changes you've made there.

       Set CKTOOL_ALLOW_DEV_RESET=1 to confirm.
EOF
    exit 1
fi

cloudkit_cktool reset-schema
cloudkit_cktool import-schema \
    --environment development \
    --validate \
    --file "$CLOUDKIT_SCHEMA_FILE"

echo "Dry-run promotion succeeded — $CLOUDKIT_SCHEMA_FILE is promotable to Production."
