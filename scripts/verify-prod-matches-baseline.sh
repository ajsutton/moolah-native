#!/usr/bin/env bash
#
# Release-tag CI gate: exports the live CloudKit Production schema and
# compares it byte-for-byte against the committed
# CloudKit/schema-prod-baseline.ckdb. Halts the release on mismatch
# (manual dashboard edit, partial prior promote, etc.) so a human can
# investigate before promote-schema runs.
#
# Targets the release container (CLOUDKIT_CONTAINER_ID_RELEASE) — see issue
# #495.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/cloudkit-config.sh
source "$HERE/cloudkit-config.sh"

cloudkit_require_env
CLOUDKIT_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID_RELEASE"

baseline="CloudKit/schema-prod-baseline.ckdb"
[ -f "$baseline" ] || cloudkit_fail "$baseline is missing."

tmp="$(mktemp -t cloudkit-prod-schema)"
trap 'rm -f "$tmp"' EXIT

cloudkit_cktool export-schema \
    --environment production \
    --output-file "$tmp"

if diff -u "$baseline" "$tmp"; then
    echo "Production schema matches $baseline."
    exit 0
fi

cat >&2 <<EOF

error: live Production schema does not match $baseline.

The release pipeline halts here. Investigate the divergence (manual
dashboard edit, partial prior promote, etc.) and update the baseline
via a follow-up PR before retrying the release.
EOF
exit 1
