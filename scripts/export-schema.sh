#!/usr/bin/env bash
#
# Exports the developer's personal CloudKit Development schema (from the
# test container, CLOUDKIT_CONTAINER_ID_TEST) into CloudKit/schema.ckdb.
# This is how a developer captures schema changes they made in cktool / the
# Console for committing back into the repo. Per issue #495 the test
# container is the one local developers experiment against.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/cloudkit-config.sh
source "$HERE/cloudkit-config.sh"

cloudkit_require_env
CLOUDKIT_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID_TEST"

mkdir -p "$(dirname "$CLOUDKIT_SCHEMA_FILE")"
cloudkit_cktool export-schema \
    --environment development \
    --output-file "$CLOUDKIT_SCHEMA_FILE"
echo "Wrote $CLOUDKIT_SCHEMA_FILE (from $CLOUDKIT_CONTAINER_ID Development)."
