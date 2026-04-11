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

# Which platforms to test: "all" (default), "ios", or "mac"
PLATFORM="${1:-all}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_ios() {
    echo "==> Testing iOS Simulator…"
    xcodebuild test "${COMMON_ARGS[@]}" \
        -derivedDataPath "$REPO_ROOT/.DerivedData-ios" \
        -scheme Moolah-iOS \
        -destination "platform=iOS Simulator,name=iPhone 17 Pro"
}

run_mac() {
    # Build the test bundle then run it directly with xcrun xctest.
    # This bypasses IDEInstallLocalMacService which adds ~2 minutes of
    # unnecessary acknowledgement overhead on macOS.
    echo "==> Testing macOS…"

    xcodebuild build-for-testing "${COMMON_ARGS[@]}" \
        -derivedDataPath "$REPO_ROOT/.DerivedData-mac" \
        -scheme Moolah-macOS \
        -destination "platform=macOS"

    PRODUCTS="$REPO_ROOT/.DerivedData-mac/Build/Products"
    APP_BUNDLE="$PRODUCTS/Debug/Moolah.app"
    TEST_BUNDLE="$APP_BUNDLE/Contents/PlugIns/MoolahTests_macOS.xctest"

    # The test bundle's @rpath looks for the debug dylib in its own
    # Contents/Frameworks/ — copy it there before running.
    DYLIB="$(find "$APP_BUNDLE/Contents/MacOS" -name "*.debug.dylib" | head -1)"
    if [[ -z "$DYLIB" ]]; then
        echo "error: Could not find debug dylib in $APP_BUNDLE/Contents/MacOS" >&2
        exit 1
    fi
    mkdir -p "$TEST_BUNDLE/Contents/Frameworks"
    cp "$DYLIB" "$TEST_BUNDLE/Contents/Frameworks/"

    xcrun xctest "$TEST_BUNDLE"
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
        echo "Usage: $0 [all|ios|mac]" >&2
        exit 1
        ;;
esac

echo ""
echo "==> All tests passed."
