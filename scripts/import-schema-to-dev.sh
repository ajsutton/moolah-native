#!/usr/bin/env bash
#
# Imports CloudKit/schema.ckdb to the Development environment of the
# release container (CLOUDKIT_CONTAINER_ID_RELEASE = iCloud.rocks.moolah.app.v2)
# as a staging step before a manual CloudKit Console "Deploy Schema Changes
# to Production" click.
#
# Resetting Dev first ensures the Console's diff view shows exactly what
# would be promoted, with no developer-side pollution. Per issue #495 the
# release container's Dev environment is touched only by this script and
# by the release pipeline — local dev runs and manual cktool experimentation
# use the separate test container (CLOUDKIT_CONTAINER_ID_TEST).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/cloudkit-config.sh
source "$HERE/cloudkit-config.sh"

cloudkit_require_env
CLOUDKIT_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID_RELEASE"

[ -f "$CLOUDKIT_SCHEMA_FILE" ] \
    || cloudkit_fail "$CLOUDKIT_SCHEMA_FILE is missing."

echo "Resetting Development schema to match Production…"
# cktool reset-schema only operates on the development environment by
# definition (per `cktool reset-schema --help`); passing --environment is
# rejected as an unknown option.
cloudkit_cktool reset-schema

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

✓ Development now mirrors $CLOUDKIT_SCHEMA_FILE on container
  $CLOUDKIT_CONTAINER_ID.

Open https://icloud.developer.apple.com/dashboard/ for container
$CLOUDKIT_CONTAINER_ID and click Schema → Deploy Schema Changes to
Production. Review the diff, confirm Deploy.
EOF
