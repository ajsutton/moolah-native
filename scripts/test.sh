#!/usr/bin/env bash
set -euo pipefail

# Disable nested sandboxing when running inside sandvault.
# macOS does not support recursive sandboxes; swift and xcodebuild create
# their own sandboxes and fail when already running inside one.
export SWIFTPM_DISABLE_SANDBOX=1
export SWIFT_BUILD_USE_SANDBOX=0

XCODE_ARGS=(
    -scheme Moolah
    -IDEPackageSupportDisableManifestSandbox=1
    -IDEPackageSupportDisablePackageSandbox=1
    'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox'
    # Skip code signing — not needed for tests
    CODE_SIGN_IDENTITY=""
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGNING_ALLOWED=NO
)

IOS_DEST="platform=iOS Simulator,name=iPhone 16 Pro"
MACOS_DEST="platform=macOS"

echo "==> Testing iOS Simulator…"
xcodebuild test "${XCODE_ARGS[@]}" -destination "$IOS_DEST"

echo "==> Testing macOS…"
xcodebuild test "${XCODE_ARGS[@]}" -destination "$MACOS_DEST"

echo "==> All tests passed."
