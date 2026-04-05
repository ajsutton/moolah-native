# Moolah native app — common development tasks.
# Install just: brew install just

# List available recipes
default:
    @just --list

# Run the full test suite on iOS Simulator and macOS
test:
    bash scripts/test.sh

# Build the app for macOS (ad-hoc signed, no certificate required)
build-mac:
    xcodegen generate
    xcodebuild build \
        -scheme Moolah \
        -destination 'platform=macOS' \
        CODE_SIGN_IDENTITY="-" \
        ENABLE_HARDENED_RUNTIME=NO

# Build and launch the macOS app
run-mac:
    xcodegen generate
    xcodebuild build \
        -scheme Moolah \
        -destination 'platform=macOS' \
        -derivedDataPath .build \
        CODE_SIGN_IDENTITY="-" \
        ENABLE_HARDENED_RUNTIME=NO
    open .build/Build/Products/Debug/Moolah.app

# Build the app for the iOS Simulator
build-ios:
    xcodegen generate
    xcodebuild build \
        -scheme Moolah \
        -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
        CODE_SIGNING_ALLOWED=NO

# Regenerate Moolah.xcodeproj from project.yml (run after editing project.yml)
generate:
    xcodegen generate

# Open the project in Xcode
open:
    open Moolah.xcodeproj
