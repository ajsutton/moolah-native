#!/usr/bin/env bash
# Shared config and helpers for CloudKit schema scripts. Sourced, not executed.

set -euo pipefail

# Must stay in sync with fastlane/Moolah.entitlements
#   (com.apple.developer.icloud-container-identifiers).
CLOUDKIT_CONTAINER_ID="iCloud.rocks.moolah.app.v2"

# Committed schema snapshot. Diffed on every PR, promoted to production on
# every release tag.
CLOUDKIT_SCHEMA_FILE="CloudKit/schema.ckdb"

cloudkit_fail() {
    echo "error: $*" >&2
    exit 1
}

cloudkit_require_env() {
    [ -n "${DEVELOPMENT_TEAM:-}" ] \
        || cloudkit_fail "DEVELOPMENT_TEAM is not set. Put it in .env or export it."
}

# Usage: cloudkit_cktool <subcommand> [extra args...]
# Fills in --team-id and --container-id. Passes --token when
# CKTOOL_MANAGEMENT_TOKEN is set (CI path); otherwise cktool falls back to the
# keychain entry written by `xcrun cktool save-token` (local-dev path).
cloudkit_cktool() {
    local sub="$1"
    shift
    local args=(
        "$sub"
        --team-id "$DEVELOPMENT_TEAM"
        --container-id "$CLOUDKIT_CONTAINER_ID"
    )
    if [ -n "${CKTOOL_MANAGEMENT_TOKEN:-}" ]; then
        args+=(--token "$CKTOOL_MANAGEMENT_TOKEN")
    fi
    args+=("$@")
    xcrun cktool "${args[@]}"
}
