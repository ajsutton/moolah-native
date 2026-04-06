#!/usr/bin/env bash
set -euo pipefail

# Disable nested sandboxing when running inside sandvault.
# macOS does not support recursive sandboxes; swift and xcodebuild create
# their own sandboxes and fail when already running inside one.
export SWIFTPM_DISABLE_SANDBOX=1
export SWIFT_BUILD_USE_SANDBOX=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

COMMON_ARGS=(
    -derivedDataPath "$REPO_ROOT/.DerivedData"
    -IDEPackageSupportDisableManifestSandbox=1
    -IDEPackageSupportDisablePackageSandbox=1
    'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox'
)

# ---------------------------------------------------------------------------
# iOS Simulator
# ---------------------------------------------------------------------------
echo "==> Testing iOS Simulator…"
xcodebuild test "${COMMON_ARGS[@]}" \
    -scheme Moolah-iOS \
    -destination "platform=iOS Simulator,name=iPhone 17 Pro"

# ---------------------------------------------------------------------------
# macOS
#
# Normally: xcodebuild test works directly — the macOS targets are ad-hoc
# signed (CODE_SIGN_IDENTITY="-"), which satisfies Gatekeeper.
#
# Inside sandvault: IDEInstallLocalMacService, the XPC service xcodebuild
# uses to install the test bundle before running, cannot communicate across
# the sandbox boundary. Work around it by building the test bundle then
# running it directly with xcrun xctest, which needs no install service.
# ---------------------------------------------------------------------------
echo "==> Testing macOS…"

if [[ -n "${SV_SESSION_ID:-}" || -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "    (sandvault/CI detected — using xcrun xctest workaround)"

    xcodebuild build-for-testing "${COMMON_ARGS[@]}" \
        -scheme Moolah-macOS \
        -destination "platform=macOS"

    PRODUCTS="$REPO_ROOT/.DerivedData/Build/Products"
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
else
    xcodebuild test "${COMMON_ARGS[@]}" \
        -scheme Moolah-macOS \
        -destination "platform=macOS"
fi

echo "==> All tests passed."
