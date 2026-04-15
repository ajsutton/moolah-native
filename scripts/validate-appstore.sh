#!/usr/bin/env bash
# Validate App Store requirements that can be checked without code signing.
# Runs against App/Info.plist and the asset catalog. Designed for CI.
set -euo pipefail

PLIST="App/Info.plist"
ICON_DIR="App/Assets.xcassets/AppIcon.appiconset"
PROJECT_YML="project.yml"

errors=0

fail() {
    echo "FAIL: $1"
    errors=$((errors + 1))
}

pass() {
    echo "  OK: $1"
}

echo "=== App Store Validation ==="
echo ""

# ── Info.plist checks ──────────────────────────────────────────────

if [ ! -f "$PLIST" ]; then
    fail "Info.plist not found at $PLIST"
    echo ""
    echo "$errors error(s) found."
    exit 1
fi

echo "--- Info.plist ---"

# UISupportedInterfaceOrientations must include all 4 orientations (iPad multitasking)
required_orientations=(
    UIInterfaceOrientationPortrait
    UIInterfaceOrientationPortraitUpsideDown
    UIInterfaceOrientationLandscapeLeft
    UIInterfaceOrientationLandscapeRight
)
for orient in "${required_orientations[@]}"; do
    if grep -q "<string>$orient</string>" "$PLIST"; then
        pass "Orientation: $orient"
    else
        fail "Missing orientation: $orient (required for iPad multitasking)"
    fi
done

# UILaunchScreen or UILaunchStoryboardName must be present
if grep -q "<key>UILaunchScreen</key>" "$PLIST" || grep -q "<key>UILaunchStoryboardName</key>" "$PLIST"; then
    pass "Launch screen key present"
else
    fail "Missing UILaunchScreen or UILaunchStoryboardName"
fi

# CFBundleShortVersionString should use build setting variable
if grep -q '<string>$(MARKETING_VERSION)</string>' "$PLIST"; then
    pass "CFBundleShortVersionString uses build setting variable"
else
    fail "CFBundleShortVersionString should use \$(MARKETING_VERSION)"
fi

# CFBundleVersion should use build setting variable
if grep -q '<string>$(CURRENT_PROJECT_VERSION)</string>' "$PLIST"; then
    pass "CFBundleVersion uses build setting variable"
else
    fail "CFBundleVersion should use \$(CURRENT_PROJECT_VERSION)"
fi

# ITSAppUsesNonExemptEncryption should be present (avoids export compliance dialog)
if grep -q "<key>ITSAppUsesNonExemptEncryption</key>" "$PLIST"; then
    pass "ITSAppUsesNonExemptEncryption present"
else
    fail "Missing ITSAppUsesNonExemptEncryption (causes export compliance dialog on each upload)"
fi

# Check for privacy usage descriptions if frameworks are linked
# NSCameraUsageDescription, NSPhotoLibraryUsageDescription
for key in NSCameraUsageDescription NSPhotoLibraryUsageDescription NSLocationWhenInUseUsageDescription; do
    # Only flag if the corresponding framework appears in project.yml
    framework=""
    case "$key" in
        NSCameraUsageDescription) framework="AVFoundation" ;;
        NSPhotoLibraryUsageDescription) framework="Photos" ;;
        NSLocationWhenInUseUsageDescription) framework="CoreLocation" ;;
    esac
    if [ -f "$PROJECT_YML" ] && grep -q "$framework" "$PROJECT_YML"; then
        if grep -q "<key>$key</key>" "$PLIST"; then
            pass "Privacy key $key present (required by $framework)"
        else
            fail "Missing $key but $framework is linked in project.yml"
        fi
    fi
done

echo ""

# ── App Icon checks ────────────────────────────────────────────────

echo "--- App Icons ---"

if [ ! -d "$ICON_DIR" ]; then
    fail "AppIcon.appiconset not found at $ICON_DIR"
else
    contents="$ICON_DIR/Contents.json"
    if [ ! -f "$contents" ]; then
        fail "Missing Contents.json in AppIcon.appiconset"
    else
        # Check that a 1024px icon exists (required for App Store)
        if ls "$ICON_DIR"/[Ii]con-1024* 1>/dev/null 2>&1 || ls "$ICON_DIR"/Icon-1024* 1>/dev/null 2>&1; then
            pass "1024px App Store icon present"
        else
            fail "Missing 1024px icon in AppIcon.appiconset (required for App Store)"
        fi

        # Check that Contents.json has no empty filename entries
        empty_slots=$(python3 -c "
import json, sys
with open('$contents') as f:
    data = json.load(f)
missing = [img for img in data.get('images', []) if 'filename' not in img]
print(len(missing))
" 2>/dev/null || echo "0")
        if [ "$empty_slots" -gt 0 ]; then
            fail "$empty_slots icon slot(s) in Contents.json have no filename assigned"
        else
            pass "All icon slots in Contents.json have filenames"
        fi
    fi
fi

echo ""

# ── Deployment target checks ───────────────────────────────────────

echo "--- Deployment Targets ---"

if [ -f "$PROJECT_YML" ]; then
    ios_target=$(grep -A1 'deploymentTarget' "$PROJECT_YML" | grep 'iOS:' | sed 's/.*iOS: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' || true)
    if [ -n "$ios_target" ]; then
        pass "iOS deployment target: $ios_target"
    else
        fail "Could not determine iOS deployment target from project.yml"
    fi
else
    fail "project.yml not found"
fi

echo ""

# ── Summary ────────────────────────────────────────────────────────

if [ "$errors" -gt 0 ]; then
    echo "FAILED: $errors error(s) found."
    exit 1
else
    echo "PASSED: All App Store validation checks passed."
    exit 0
fi
