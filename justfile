# Moolah native app — common development tasks.
# Install just: brew install just

# Load .env if present (code signing settings, etc.)
set dotenv-load := true

# List available recipes
default:
    @just --list

# Run swift-format style lint (prints warnings; does not exit non-zero for
# pre-existing advisory violations). Use `format-check` in CI and pre-commit
# to enforce actual formatting.
lint:
    swift-format lint -r . --configuration .swift-format

# Apply swift-format formatting in place across the repo. Run this before
# committing; CI rejects changes that are not in formatted form.
format:
    swift-format format -i -r . --configuration .swift-format

# Back-compat alias for `format`.
lint-fix: format

# Verify that every tracked Swift file is already in formatted form.
# Non-destructive: does not modify any files. Exits non-zero on any diff.
# Used by CI; run locally before committing if you want to preview failures
# without applying changes.
format-check:
    #!/usr/bin/env bash
    set -euo pipefail
    fail=0
    while IFS= read -r file; do
        if ! cmp -s "$file" <(swift-format format --configuration .swift-format "$file"); then
            echo "::error file=$file::Not formatted; run 'just format' to fix"
            diff -u --label "$file" --label "$file (formatted)" \
                "$file" <(swift-format format --configuration .swift-format "$file") || true
            fail=1
        fi
    done < <(git ls-files '*.swift')
    if [ "$fail" -ne 0 ]; then
        echo
        echo "One or more files are not formatted correctly."
        echo "Run 'just format' and commit the result."
        exit 1
    fi
    echo "All Swift files are correctly formatted."

# FILTERS restrict the run to specific tests: each is a class (e.g.
# TransactionStoreTests) or class/method (e.g. TransactionStoreTests/testFoo);
# the platform's test target prefix (MoolahTests_iOS or MoolahTests_macOS) is
# added automatically. Pass a fully-qualified TestTarget/Class form to pin a
# filter to one platform's target.
# Run the test suite on iOS Simulator and macOS in parallel (optional FILTERS).
test *FILTERS: generate
    bash scripts/test.sh all {{ FILTERS }}

# Run tests on macOS only. See `test` for FILTERS syntax.
test-mac *FILTERS: generate
    bash scripts/test.sh mac {{ FILTERS }}

# Run tests on iOS Simulator only. See `test` for FILTERS syntax.
test-ios *FILTERS: generate
    bash scripts/test.sh ios {{ FILTERS }}

# Run performance benchmarks (macOS only)
benchmark *FILTER: generate
    bash scripts/benchmark.sh {{ FILTER }}

# Run UI tests on native macOS (no simulator). FILTERS work like `test`:
# pass a class name (e.g. `UITestingLaunchSmokeTests`) or class/method to
# narrow the run. The MoolahUITests_macOS prefix is added automatically.
test-ui *FILTERS: generate
    bash scripts/test-ui.sh {{ FILTERS }}

# Build the app for macOS
build-mac: generate
    #!/usr/bin/env bash
    set -euo pipefail
    args=(-scheme Moolah-macOS -destination 'platform=macOS' -derivedDataPath .build)
    if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
        args+=(CODE_SIGN_IDENTITY="-" ENABLE_HARDENED_RUNTIME=NO)
    fi
    xcodebuild build "${args[@]}"

# Build and launch the macOS app
run-mac: generate
    #!/usr/bin/env bash
    set -euo pipefail
    args=(-scheme Moolah-macOS -destination 'platform=macOS' -derivedDataPath .build)
    if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
        args+=(CODE_SIGN_IDENTITY="-" ENABLE_HARDENED_RUNTIME=NO)
    fi
    xcodebuild build "${args[@]}"
    open .build/Build/Products/Debug/Moolah.app

# Build a Release macOS app and install to /Applications.
# Forces ENABLE_ENTITLEMENTS=1 for the regenerate: Release bakes in
# CLOUDKIT_ENABLED, so an un-entitled binary is killed silently at launch
# by the hardened runtime when it calls CKContainer.default().
install-mac:
    #!/usr/bin/env bash
    set -euo pipefail
    ENABLE_ENTITLEMENTS=1 just generate
    xcodebuild build \
        -scheme Moolah-macOS \
        -destination 'platform=macOS' \
        -configuration Release \
        -derivedDataPath .build
    rm -rf /Applications/Moolah.app
    cp -R .build/Build/Products/Release/Moolah.app /Applications/Moolah.app
    echo "Installed Moolah.app to /Applications"

# Build the app for the iOS Simulator
build-ios: generate
    #!/usr/bin/env bash
    set -euo pipefail
    SIM="$(bash scripts/find-simulator.sh)"
    echo "==> Building for iOS Simulator ($SIM)…"
    xcodebuild build \
        -scheme Moolah-iOS \
        -destination "platform=iOS Simulator,name=$SIM" \
        CODE_SIGNING_ALLOWED=NO

# Regenerate Moolah.xcodeproj from project.yml (run after editing project.yml)
generate:
    #!/usr/bin/env bash
    set -euo pipefail

    # Provide default
    export CODE_SIGN_STYLE="${CODE_SIGN_STYLE:-Automatic}"

    # Optionally inject entitlements for local CloudKit development
    if [ "${ENABLE_ENTITLEMENTS:-}" = "1" ]; then
        SPEC=$(bash scripts/inject-entitlements.sh)
        trap "rm -f $SPEC" EXIT
        xcodegen generate --spec "$SPEC"
    else
        xcodegen generate
    fi

# Sync code signing certificates (runs Match)
certificates:
    bundle exec fastlane ios certificates

# Build and install macOS app, then upload iOS app to TestFlight
test-release: install-mac testflight

# Check App Store requirements without signing (Info.plist, icons, etc.)
validate-appstore:
    bash scripts/validate-appstore.sh

# Validate an iOS archive against App Store rules (requires signing)
validate-ios: generate
    bundle exec fastlane ios validate

# Build and upload to TestFlight
testflight: generate
    bundle exec fastlane ios beta

# Bump marketing version (usage: just bump-version 1.2.0)
bump-version version:
    sed -i '' 's/MARKETING_VERSION: .*/MARKETING_VERSION: "{{version}}"/' project.yml
    just generate

# Build, launch macOS app, and stream logs to .agent-tmp/app-logs.txt
run-mac-with-logs predicate='subsystem == "com.moolah.app"': generate
    bash scripts/run-with-logs.sh '{{predicate}}'

# Open the project in Xcode
open:
    open Moolah.xcodeproj
