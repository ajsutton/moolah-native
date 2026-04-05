#!/usr/bin/env bash
set -euo pipefail

# Disable nested sandboxing when running inside sandvault.
# macOS does not support recursive sandboxes; swift and xcodebuild create
# their own sandboxes and fail when already running inside one.
export SWIFTPM_DISABLE_SANDBOX=1
export SWIFT_BUILD_USE_SANDBOX=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$REPO_ROOT/.DerivedData"

COMMON_ARGS=(
    -scheme Moolah
    -derivedDataPath "$DERIVED_DATA"
    -IDEPackageSupportDisableManifestSandbox=1
    -IDEPackageSupportDisablePackageSandbox=1
    'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox'
)

# ---------------------------------------------------------------------------
# iOS Simulator — xcodebuild test works directly (no install service needed)
# ---------------------------------------------------------------------------
echo "==> Testing iOS Simulator…"
xcodebuild test \
    "${COMMON_ARGS[@]}" \
    -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO

# ---------------------------------------------------------------------------
# macOS — IDEInstallLocalMacService is blocked in sandvault, so we build the
# test bundle separately and run it directly via xcrun xctest.
# ---------------------------------------------------------------------------
echo "==> Building macOS tests…"
xcodebuild build-for-testing \
    "${COMMON_ARGS[@]}" \
    -destination "platform=macOS" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    AD_HOC_CODE_SIGNING_ALLOWED=YES

PRODUCTS="$DERIVED_DATA/Moolah/Build/Products"
APP_BUNDLE="$PRODUCTS/Debug/Moolah_macOS.app"
TEST_BUNDLE="$APP_BUNDLE/Contents/PlugIns/MoolahTests_macOS.xctest"
DYLIB="$APP_BUNDLE/Contents/MacOS/Moolah_macOS.debug.dylib"

# The test bundle's @rpath resolves Moolah_macOS.debug.dylib relative to its
# own Contents/Frameworks/ — copy it there before running.
mkdir -p "$TEST_BUNDLE/Contents/Frameworks"
cp "$DYLIB" "$TEST_BUNDLE/Contents/Frameworks/"

echo "==> Running macOS tests…"
xcrun xctest "$TEST_BUNDLE"

echo "==> All tests passed."
