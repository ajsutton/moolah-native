#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/cloudkit-config.sh
source "$HERE/cloudkit-config.sh"

cloudkit_require_env

[ -f "$CLOUDKIT_SCHEMA_FILE" ] \
    || cloudkit_fail "$CLOUDKIT_SCHEMA_FILE is missing."

cloudkit_cktool import-schema \
    --environment production \
    --file "$CLOUDKIT_SCHEMA_FILE" \
    --validate
echo "Promoted $CLOUDKIT_SCHEMA_FILE to CloudKit production."
