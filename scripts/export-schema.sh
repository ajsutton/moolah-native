#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/cloudkit-config.sh
source "$HERE/cloudkit-config.sh"

cloudkit_require_env

mkdir -p "$(dirname "$CLOUDKIT_SCHEMA_FILE")"
cloudkit_cktool export-schema \
    --environment development \
    --output-file "$CLOUDKIT_SCHEMA_FILE"
echo "Wrote $CLOUDKIT_SCHEMA_FILE"
