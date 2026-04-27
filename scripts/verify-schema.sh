#!/usr/bin/env bash
#
# Manual local convenience: imports CloudKit/schema.ckdb to the developer's
# test container Development environment (CLOUDKIT_CONTAINER_ID_TEST) with
# --validate. Not run in CI.
#
# Use this when you want belt-and-braces verification before opening a PR
# that touches the schema. It will surface any cktool import-side issues
# (syntax, conflicts with what your test container's Dev currently has)
# that the static additivity check cannot catch.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/cloudkit-config.sh
source "$HERE/cloudkit-config.sh"

cloudkit_require_env
CLOUDKIT_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID_TEST"

[ -f "$CLOUDKIT_SCHEMA_FILE" ] \
    || cloudkit_fail "$CLOUDKIT_SCHEMA_FILE is missing."

cloudkit_cktool import-schema \
    --environment development \
    --validate \
    --file "$CLOUDKIT_SCHEMA_FILE"

echo "$CLOUDKIT_SCHEMA_FILE imported into the $CLOUDKIT_CONTAINER_ID Development environment."
