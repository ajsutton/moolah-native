#!/usr/bin/env bash
# Shared config and helpers for CloudKit schema scripts. Sourced, not executed.
#
# Two CloudKit containers are in play (issue #495):
#
# - CLOUDKIT_CONTAINER_ID_RELEASE: production users + the release pipeline's
#   schema-staging step. Anything that targets this container can affect what
#   gets promoted to live Production. Touched by:
#     verify-prod-deployed.sh, verify-prod-matches-baseline.sh,
#     refresh-prod-baseline.sh, import-schema-to-dev.sh.
#
# - CLOUDKIT_CONTAINER_ID_TEST: local dev runs, manual cktool experimentation,
#   anything not part of the release flow. Touched by:
#     export-schema.sh, verify-schema.sh, dryrun-promote-schema.sh,
#     import-schema-to-test.sh.
#
# Every caller of cloudkit_cktool MUST set CLOUDKIT_CONTAINER_ID to one of the
# two constants above before invoking cloudkit_cktool — there is no default,
# to make the choice explicit at every call site.

set -euo pipefail

# Must stay in sync with the Release-config CLOUDKIT_CONTAINER_ID in project.yml
# and with com.apple.developer.icloud-container-identifiers in
# fastlane/Moolah.entitlements / fastlane/Moolah-mac.entitlements.
CLOUDKIT_CONTAINER_ID_RELEASE="iCloud.rocks.moolah.app.v2"

# Must stay in sync with the Debug- and Debug-Tests-config CLOUDKIT_CONTAINER_ID
# in project.yml and with com.apple.developer.icloud-container-identifiers in
# the entitlements file written by scripts/inject-entitlements.sh.
CLOUDKIT_CONTAINER_ID_TEST="iCloud.rocks.moolah.app.test"

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

cloudkit_require_container_id() {
    [ -n "${CLOUDKIT_CONTAINER_ID:-}" ] \
        || cloudkit_fail "CLOUDKIT_CONTAINER_ID is not set. The caller must pin it to either CLOUDKIT_CONTAINER_ID_RELEASE or CLOUDKIT_CONTAINER_ID_TEST before calling cloudkit_cktool."
    case "$CLOUDKIT_CONTAINER_ID" in
        "$CLOUDKIT_CONTAINER_ID_RELEASE"|"$CLOUDKIT_CONTAINER_ID_TEST") ;;
        *)
            cloudkit_fail "CLOUDKIT_CONTAINER_ID=$CLOUDKIT_CONTAINER_ID is not one of the known constants ($CLOUDKIT_CONTAINER_ID_RELEASE, $CLOUDKIT_CONTAINER_ID_TEST)."
            ;;
    esac
}

# Usage: cloudkit_cktool <subcommand> [extra args...]
# Fills in --team-id and --container-id (from CLOUDKIT_CONTAINER_ID, which the
# caller must set). Passes --token when CKTOOL_MANAGEMENT_TOKEN is set (CI
# path); otherwise cktool falls back to the keychain entry written by
# `xcrun cktool save-token` (local-dev path).
cloudkit_cktool() {
    cloudkit_require_container_id
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
