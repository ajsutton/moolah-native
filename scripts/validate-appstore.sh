#!/usr/bin/env bash
# Validate App Store requirements that can be checked without code signing.
# Runs against App/Info-iOS.plist, App/Info-macOS.plist and the asset catalog.
# Designed for CI.
set -euo pipefail

IOS_PLIST="App/Info-iOS.plist"
MACOS_PLIST="App/Info-macOS.plist"
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

for plist in "$IOS_PLIST" "$MACOS_PLIST"; do
    if [ ! -f "$plist" ]; then
        fail "Info.plist not found at $plist"
    fi
done

if [ "$errors" -gt 0 ]; then
    echo ""
    echo "$errors error(s) found."
    exit 1
fi

echo "--- $IOS_PLIST ---"

# UISupportedInterfaceOrientations must include all 4 orientations (iPad multitasking)
required_orientations=(
    UIInterfaceOrientationPortrait
    UIInterfaceOrientationPortraitUpsideDown
    UIInterfaceOrientationLandscapeLeft
    UIInterfaceOrientationLandscapeRight
)
for orient in "${required_orientations[@]}"; do
    if grep -q "<string>$orient</string>" "$IOS_PLIST"; then
        pass "Orientation: $orient"
    else
        fail "Missing orientation in $IOS_PLIST: $orient (required for iPad multitasking)"
    fi
done

# UILaunchScreen or UILaunchStoryboardName must be present
if grep -q "<key>UILaunchScreen</key>" "$IOS_PLIST" || grep -q "<key>UILaunchStoryboardName</key>" "$IOS_PLIST"; then
    pass "Launch screen key present"
else
    fail "Missing UILaunchScreen or UILaunchStoryboardName in $IOS_PLIST"
fi

# iOS plist must NOT contain macOS-only keys
for macos_only_key in NSAppleScriptEnabled OSAScriptingDefinition LSMinimumSystemVersion; do
    if grep -q "<key>$macos_only_key</key>" "$IOS_PLIST"; then
        fail "$IOS_PLIST contains macOS-only key: $macos_only_key"
    else
        pass "$IOS_PLIST has no macOS-only key: $macos_only_key"
    fi
done

echo ""
echo "--- $MACOS_PLIST ---"

# macOS plist must NOT contain iOS-only keys
for ios_only_key in UILaunchScreen UIBackgroundModes UISupportedInterfaceOrientations; do
    if grep -q "<key>$ios_only_key</key>" "$MACOS_PLIST"; then
        fail "$MACOS_PLIST contains iOS-only key: $ios_only_key"
    else
        pass "$MACOS_PLIST has no iOS-only key: $ios_only_key"
    fi
done

# ── Shared checks on both plists ────────────────────────────────────

for plist in "$IOS_PLIST" "$MACOS_PLIST"; do
    echo ""
    echo "--- Shared checks: $plist ---"

    # CFBundleShortVersionString should use build setting variable
    if grep -q '<string>$(MARKETING_VERSION)</string>' "$plist"; then
        pass "CFBundleShortVersionString uses build setting variable"
    else
        fail "CFBundleShortVersionString should use \$(MARKETING_VERSION) in $plist"
    fi

    # CFBundleVersion should use build setting variable
    if grep -q '<string>$(CURRENT_PROJECT_VERSION)</string>' "$plist"; then
        pass "CFBundleVersion uses build setting variable"
    else
        fail "CFBundleVersion should use \$(CURRENT_PROJECT_VERSION) in $plist"
    fi

    # ITSAppUsesNonExemptEncryption should be present (avoids export compliance dialog)
    if grep -q "<key>ITSAppUsesNonExemptEncryption</key>" "$plist"; then
        pass "ITSAppUsesNonExemptEncryption present"
    else
        fail "Missing ITSAppUsesNonExemptEncryption in $plist (causes export compliance dialog on each upload)"
    fi

    # Check for privacy usage descriptions if frameworks are linked
    for key in NSCameraUsageDescription NSPhotoLibraryUsageDescription NSLocationWhenInUseUsageDescription; do
        framework=""
        case "$key" in
            NSCameraUsageDescription) framework="AVFoundation" ;;
            NSPhotoLibraryUsageDescription) framework="Photos" ;;
            NSLocationWhenInUseUsageDescription) framework="CoreLocation" ;;
        esac
        if [ -f "$PROJECT_YML" ] && grep -q "$framework" "$PROJECT_YML"; then
            if grep -q "<key>$key</key>" "$plist"; then
                pass "Privacy key $key present (required by $framework)"
            else
                fail "Missing $key in $plist but $framework is linked in project.yml"
            fi
        fi
    done
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
