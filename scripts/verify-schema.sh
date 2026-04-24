#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/cloudkit-config.sh
source "$HERE/cloudkit-config.sh"

cloudkit_require_env

[ -f "$CLOUDKIT_SCHEMA_FILE" ] \
    || cloudkit_fail "$CLOUDKIT_SCHEMA_FILE is missing. Run 'just export-schema' to create it."

tmp="$(mktemp -t cloudkit-schema)"
trap 'rm -f "$tmp"' EXIT

cloudkit_cktool export-schema \
    --environment development \
    --output-file "$tmp"

if diff -u "$CLOUDKIT_SCHEMA_FILE" "$tmp"; then
    echo "CloudKit development schema matches $CLOUDKIT_SCHEMA_FILE"
    exit 0
fi

cat >&2 <<EOF

error: CloudKit development schema has drifted from $CLOUDKIT_SCHEMA_FILE.

Run 'just export-schema' and commit the updated file. If the drift was caused
by experimentation in CloudKit Console, use 'Reset Development Environment'
there and re-run.
EOF
exit 1
