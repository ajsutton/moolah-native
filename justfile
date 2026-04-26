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

# Apply swift-format formatting in place, then run SwiftLint autocorrect.
# Run this before committing; CI rejects unformatted files or new lint warnings.
format:
    swift-format format -i -r . --configuration .swift-format
    swiftlint lint --fix --quiet

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
    swiftlint lint --baseline .swiftlint-baseline.yml --strict --quiet

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

# Run unit tests for release-script helpers (no git/network side effects).
test-release-scripts:
    bash scripts/tests/test-release-common.sh

# Build the app for macOS
build-mac: generate
    #!/usr/bin/env bash
    set -euo pipefail
    args=(-scheme Moolah-macOS -destination 'platform=macOS' -derivedDataPath .build)
    if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
        args+=(CODE_SIGN_IDENTITY="-" ENABLE_HARDENED_RUNTIME=NO)
    fi
    xcodebuild build "${args[@]}"

# Build and launch the macOS app. Extra args are forwarded as launch
# arguments to the app process (e.g. `just run-mac --ui-testing`).
#
# With args: launches the binary directly and backgrounds it so env
# vars exported by the caller (e.g. `UI_TESTING_SEED=welcomeEmpty`)
# reach the child process. Launch Services (`open --args`) does not
# reliably forward the shell environment into the target app.
#
# Without args: uses `open` so the app activates through Launch
# Services like a double-click (preserves Finder-style launch).
run-mac *args: generate
    #!/usr/bin/env bash
    set -euo pipefail
    build=(-scheme Moolah-macOS -destination 'platform=macOS' -derivedDataPath .build)
    if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
        build+=(CODE_SIGN_IDENTITY="-" ENABLE_HARDENED_RUNTIME=NO)
    fi
    xcodebuild build "${build[@]}"
    if [ -n "{{args}}" ]; then
        # Kill any running instance first; `open` would silently
        # reuse it, skipping the new launch arguments entirely.
        pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null || true
        nohup .build/Build/Products/Debug/Moolah.app/Contents/MacOS/Moolah \
            {{args}} >/dev/null 2>&1 &
        disown
    else
        open .build/Build/Products/Debug/Moolah.app
    fi

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

# Regenerate the CloudKit wire-struct layer from CloudKit/schema.ckdb,
# then regenerate Moolah.xcodeproj from project.yml.
generate:
    #!/usr/bin/env bash
    set -euo pipefail

    swift run --package-path tools/CKDBSchemaGen ckdb-schema-gen generate \
        --input CloudKit/schema.ckdb \
        --output Backends/CloudKit/Sync/Generated

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

# Verify CloudKit/schema.ckdb is additive over the committed Production
# baseline. Pure-text check: no CloudKit calls. Run in CI on every PR.
check-schema-additive:
    swift run --package-path tools/CKDBSchemaGen ckdb-schema-gen check-additive \
        --proposed CloudKit/schema.ckdb \
        --baseline CloudKit/schema-prod-baseline.ckdb

# Sync code signing certificates (runs Match)
certificates:
    bundle exec fastlane ios certificates

# Build and install macOS app, then upload iOS app to TestFlight
test-release: install-mac testflight

# Check App Store requirements without signing (Info.plist, icons, etc.)
validate-appstore:
    bash scripts/validate-appstore.sh

# Validate that every TODO / FIXME references an open GitHub issue.
# Requires `gh` authenticated (GITHUB_TOKEN in CI or `gh auth login` locally).
# See guides/CODE_GUIDE.md §20.
validate-todos:
    bash scripts/check-todos.sh

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

# Build, launch macOS app, and stream logs to .agent-tmp/app-logs.txt.
# Extra args after the predicate are forwarded as launch arguments to
# the app process (e.g.
# `just run-mac-with-logs 'subsystem == "com.moolah.app"' --ui-testing`).
run-mac-with-logs predicate='subsystem == "com.moolah.app"' *args: generate
    bash scripts/run-with-logs.sh '{{predicate}}' {{args}}

# Open the project in Xcode
open:
    open Moolah.xcodeproj

# Export the CloudKit Development schema to CloudKit/schema.ckdb.
# Requires DEVELOPMENT_TEAM and a management token (`xcrun cktool save-token
# --type management` for local use, or CKTOOL_MANAGEMENT_TOKEN in CI).
export-schema:
    bash scripts/export-schema.sh

# Manual local convenience: import CloudKit/schema.ckdb to the developer's
# personal Development container with --validate. Not used by CI.
verify-schema:
    bash scripts/verify-schema.sh

# Manual local convenience: Apple's recommended Production-equivalent
# dry-run. Resets your personal Dev container to match Prod, then imports
# the proposed schema with --validate. DESTRUCTIVE — set
# CKTOOL_ALLOW_DEV_RESET=1 to confirm. Not used by CI.
dryrun-promote-schema:
    bash scripts/dryrun-promote-schema.sh

# Release-tag CI: verifies the live Production schema matches
# CloudKit/schema-prod-baseline.ckdb before promote-schema runs.
verify-prod-matches-baseline:
    bash scripts/verify-prod-matches-baseline.sh

# Release-tag CI: imports CloudKit/schema.ckdb to Production with --validate,
# refreshes CloudKit/schema-prod-baseline.ckdb from live Production, and
# opens a follow-up PR with the new baseline. Run via the testflight workflow.
# Production schema changes are one-way — to run locally, re-run with
# CKTOOL_PROMOTE_FORCE=1.
promote-schema:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "${CI:-}" != "true" ] && [ "${CKTOOL_PROMOTE_FORCE:-}" != "1" ]; then
        echo "promote-schema is intended to run only in CI (on release tags)." >&2
        echo "Re-run with CKTOOL_PROMOTE_FORCE=1 to force a local promotion." >&2
        exit 1
    fi
    bash scripts/promote-schema.sh

# === Release ===
# Verify the local repo is on main, clean, in sync with origin, gh
# authenticated, and CI green. Used by both RC and final flows.
release-preflight:
    bash scripts/release-preflight.sh

# Compute the proposed version for the next release tag.
# KIND=rc|final. Emits JSON to stdout (see scripts/lib/release-common.sh).
release-next-version KIND:
    bash scripts/release-next-version.sh {{KIND}}

# Create the GH pre-release for an RC. Creates the tag at HEAD of main,
# which fires release-rc.yml. NOTES_FILE is a path to a markdown file
# containing the user-facing release notes (see guides/RELEASE_GUIDE.md).
release-create-rc VERSION NOTES_FILE:
    bash scripts/release-create-rc.sh {{VERSION}} {{NOTES_FILE}}
