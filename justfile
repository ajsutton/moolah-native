# Moolah native app — common development tasks.
# Install just: brew install just

# Load .env if present (code signing settings, etc.)
set dotenv-load := true

# List available recipes
default:
    @just --list

lint:
    swift-format lint -r . --configuration .swift-format

lint-fix:
    swift-format format -i -r . --configuration .swift-format

# Run the full test suite on iOS Simulator and macOS (in parallel)
test: generate
    bash scripts/test.sh

# Run tests on macOS only
test-mac: generate
    bash scripts/test.sh mac

# Run tests on iOS Simulator only
test-ios: generate
    bash scripts/test.sh ios

# Build the app for macOS
build-mac: generate
    #!/usr/bin/env bash
    set -euo pipefail
    args=(-scheme Moolah-macOS -destination 'platform=macOS')
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

# Build a Release macOS app and install to /Applications
install-mac: generate
    #!/usr/bin/env bash
    set -euo pipefail
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
    xcodebuild build \
        -scheme Moolah-iOS \
        -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
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

# Build and upload to TestFlight
testflight: generate
    bundle exec fastlane ios beta

# Bump marketing version (usage: just bump-version 1.2.0)
bump-version version:
    sed -i '' 's/MARKETING_VERSION: .*/MARKETING_VERSION: "{{version}}"/' project.yml
    just generate

# Open the project in Xcode
open:
    open Moolah.xcodeproj
