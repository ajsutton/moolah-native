#!/usr/bin/env bash
set -euo pipefail

# Disable nested sandboxing when running inside sandvault.
# macOS does not support recursive sandboxes; swift and xcodebuild create
# their own sandboxes and fail when already running inside one.
export SWIFTPM_DISABLE_SANDBOX=1
export SWIFT_BUILD_USE_SANDBOX=0

COMMON_ARGS=(
    -scheme Moolah
    -IDEPackageSupportDisableManifestSandbox=1
    -IDEPackageSupportDisablePackageSandbox=1
    'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox'
)

# iOS Simulator: code signing not required
IOS_ARGS=(
    "${COMMON_ARGS[@]}"
    CODE_SIGN_IDENTITY=""
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGNING_ALLOWED=NO
)

# macOS: ad-hoc signing (-) required to launch the test bundle
MACOS_ARGS=(
    "${COMMON_ARGS[@]}"
    CODE_SIGN_IDENTITY="-"
    CODE_SIGNING_REQUIRED=NO
    AD_HOC_CODE_SIGNING_ALLOWED=YES
)

IOS_DEST="platform=iOS Simulator,name=iPhone 17 Pro"
MACOS_DEST="platform=macOS"

echo "==> Testing iOS Simulator…"
xcodebuild test "${IOS_ARGS[@]}" -destination "$IOS_DEST"

echo "==> Testing macOS…"
xcodebuild test "${MACOS_ARGS[@]}" -destination "$MACOS_DEST"

echo "==> All tests passed."
