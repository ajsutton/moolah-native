#!/usr/bin/env bash
# Verifies that a Release-configuration build is using a real, incremented
# build number rather than the placeholder "1" baked into project.yml.
#
# We rely on Fastlane (`fastlane beta` / `fastlane release`) for ALL App
# Store / TestFlight uploads. Fastlane runs `increment_build_number` against
# the latest TestFlight build before archiving, so a Fastlane-driven build
# will never see CURRENT_PROJECT_VERSION == "1". Any Release build that
# *does* see "1" was produced outside Fastlane (local Archive, ad-hoc
# xcodebuild) and would either collide with an existing build number on
# upload or, worse, ship as 1.0.0 (1) and break delta updates.
#
# This script runs as a Run Script build phase on each app target. It fails
# the build only when both:
#   - $CONFIGURATION = Release, AND
#   - $CURRENT_PROJECT_VERSION = "1"
# Debug / Debug-Tests builds are unaffected, so local development continues
# to work unchanged.
#
# To produce a real Release build, run `bundle exec fastlane beta` from the
# repo root.
set -euo pipefail

if [ "${CONFIGURATION:-}" != "Release" ]; then
    exit 0
fi

if [ "${CURRENT_PROJECT_VERSION:-}" = "1" ]; then
    cat <<'MSG' >&2
error: CURRENT_PROJECT_VERSION is still the placeholder "1" for a Release build.

Release builds must be produced via Fastlane, which auto-increments the
build number against the latest TestFlight build. Run:

  bundle exec fastlane beta       # TestFlight
  bundle exec fastlane release    # App Store

If you genuinely need a local Release build for diagnosis (not upload),
set CURRENT_PROJECT_VERSION explicitly, e.g.:

  xcodebuild -scheme Moolah-macOS -configuration Release \
    CURRENT_PROJECT_VERSION=99999

See project.yml settings.base for the placeholder declaration and
guides/RELEASE_GUIDE.md / fastlane/Fastfile for the canonical flow.
MSG
    exit 1
fi
