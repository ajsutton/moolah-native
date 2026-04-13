#!/usr/bin/env bash
set -euo pipefail

# Disable nested sandboxing (same as test.sh)
export SWIFTPM_DISABLE_SANDBOX=1
export SWIFT_BUILD_USE_SANDBOX=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

COMMON_ARGS=(
    -IDEPackageSupportDisableManifestSandbox=1
    -IDEPackageSupportDisablePackageSandbox=1
    'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox'
)

# Optional filter: class name or class/method
FILTER="${1:-}"

echo "==> Building benchmarks…"
xcodebuild build-for-testing "${COMMON_ARGS[@]}" \
    -derivedDataPath "$REPO_ROOT/.DerivedData-bench" \
    -scheme Moolah-Benchmarks \
    -destination "platform=macOS"

PRODUCTS="$REPO_ROOT/.DerivedData-bench/Build/Products"
APP_BUNDLE="$PRODUCTS/Debug/Moolah.app"
TEST_BUNDLE="$APP_BUNDLE/Contents/PlugIns/MoolahBenchmarks_macOS.xctest"

# Copy debug dylib (same fix as test.sh)
DYLIB="$(find "$APP_BUNDLE/Contents/MacOS" -name "*.debug.dylib" | head -1)"
if [[ -n "$DYLIB" ]]; then
    mkdir -p "$TEST_BUNDLE/Contents/Frameworks"
    cp "$DYLIB" "$TEST_BUNDLE/Contents/Frameworks/"
fi

if [[ -n "$FILTER" ]]; then
    echo "==> Running benchmarks matching: $FILTER"
    xcrun xctest -XCTest "$FILTER" "$TEST_BUNDLE"
else
    echo "==> Running all benchmarks…"
    xcrun xctest "$TEST_BUNDLE"
fi
