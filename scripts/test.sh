#!/usr/bin/env bash
set -euo pipefail

# Disable nested sandboxing when running inside sandvault.
# macOS does not support recursive sandboxes; swift and xcodebuild create
# their own sandboxes and fail when already running inside one.
export SWIFTPM_DISABLE_SANDBOX=1
export SWIFT_BUILD_USE_SANDBOX=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

COMMON_ARGS=(
    -IDEPackageSupportDisableManifestSandbox=1
    -IDEPackageSupportDisablePackageSandbox=1
    'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox'
)

# Usage: test.sh [all|ios|mac] [FILTER ...]
# FILTERs are passed to xcodebuild as -only-testing: flags. Each filter may be:
#   - A class name or class/method, e.g. "TransactionStoreTests" or
#     "TransactionStoreTests/testFoo". The platform's test target prefix
#     ("MoolahTests_iOS" or "MoolahTests_macOS") is added automatically.
#   - A fully-qualified "TestTarget/Class[/method]" form (starting with
#     "MoolahTests_"), which is passed through unchanged. Use this to pin a
#     filter to a specific platform's target when running both platforms.
PLATFORM="${1:-all}"
shift || true
FILTERS=("$@")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

IOS_SIMULATOR="$(bash "$REPO_ROOT/scripts/find-simulator.sh")"

# Print the -only-testing: flags for the given platform's test target, one per
# line, honouring the global FILTERS array. Prints nothing when FILTERS is empty.
print_filter_flags() {
    local target="$1"
    local f
    for f in ${FILTERS[@]+"${FILTERS[@]}"}; do
        if [[ "$f" == MoolahTests_* ]]; then
            printf -- '-only-testing:%s\n' "$f"
        else
            printf -- '-only-testing:%s/%s\n' "$target" "$f"
        fi
    done
}

run_ios() {
    echo "==> Testing iOS Simulator ($IOS_SIMULATOR)…"
    local filter_flags=()
    while IFS= read -r line; do
        filter_flags+=("$line")
    done < <(print_filter_flags "MoolahTests_iOS")
    xcodebuild test "${COMMON_ARGS[@]}" \
        -derivedDataPath "$REPO_ROOT/.DerivedData-ios" \
        -scheme Moolah-iOS \
        -destination "platform=iOS Simulator,name=$IOS_SIMULATOR" \
        ${filter_flags[@]+"${filter_flags[@]}"}
    bash "$REPO_ROOT/scripts/assert-no-icloud-in-test-host.sh" \
        "$REPO_ROOT/.DerivedData-ios/Build/Products/Debug-Tests-iphonesimulator/Moolah.app/Moolah"
}

run_mac() {
    echo "==> Testing macOS…"
    local filter_flags=()
    while IFS= read -r line; do
        filter_flags+=("$line")
    done < <(print_filter_flags "MoolahTests_macOS")
    xcodebuild test "${COMMON_ARGS[@]}" \
        -derivedDataPath "$REPO_ROOT/.DerivedData-mac" \
        -scheme Moolah-macOS \
        -destination "platform=macOS" \
        ${filter_flags[@]+"${filter_flags[@]}"}
    bash "$REPO_ROOT/scripts/assert-no-icloud-in-test-host.sh" \
        "$REPO_ROOT/.DerivedData-mac/Build/Products/Debug-Tests/Moolah.app/Contents/MacOS/Moolah"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

case "$PLATFORM" in
    ios)
        run_ios
        ;;
    mac)
        run_mac
        ;;
    all)
        # Run both platforms in parallel, wait for both, fail if either fails.
        ios_log="$(mktemp)"
        mac_log="$(mktemp)"
        trap 'rm -f "$ios_log" "$mac_log"' EXIT

        run_ios >"$ios_log" 2>&1 &
        ios_pid=$!

        run_mac >"$mac_log" 2>&1 &
        mac_pid=$!

        failed=0

        if ! wait "$ios_pid"; then
            failed=1
        fi
        if ! wait "$mac_pid"; then
            failed=1
        fi

        # Always print both logs so failures are visible.
        echo ""
        echo "================= iOS Simulator output ================="
        cat "$ios_log"
        echo ""
        echo "==================== macOS output ======================"
        cat "$mac_log"

        if [[ "$failed" -ne 0 ]]; then
            echo ""
            echo "==> FAILED: one or more platforms had test failures."
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 [all|ios|mac] [FILTER ...]" >&2
        exit 1
        ;;
esac

echo ""
echo "==> All tests passed."
