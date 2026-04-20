#!/usr/bin/env bash
# Run XCUITest UI tests on native macOS (no simulator).
#
# Usage: test-ui.sh [FILTER ...]
#   FILTERs follow the same convention as scripts/test.sh: pass a class name
#   (`UITestingLaunchSmokeTests`) or class/method
#   (`UITestingLaunchSmokeTests/testAppLaunchesWithTradeBaselineSeed`) to
#   narrow the run. The `MoolahUITests_macOS` prefix is added automatically;
#   pass a fully-qualified `MoolahUITests_macOS/Class[/method]` form to skip
#   the prefix.
#
# UI tests are macOS-only (see guides/UI_TEST_GUIDE.md §1) and run through
# the dedicated `Moolah-macOS-UITests` scheme. Output flows directly to the
# terminal; tee it to `.agent-tmp/test-ui.txt` from the caller if you want to
# inspect failures without re-running.
set -euo pipefail

# Disable nested sandboxing when running inside sandvault; xcodebuild creates
# its own sandbox and fails when already running inside one.
export SWIFTPM_DISABLE_SANDBOX=1
export SWIFT_BUILD_USE_SANDBOX=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

COMMON_ARGS=(
    -IDEPackageSupportDisableManifestSandbox=1
    -IDEPackageSupportDisablePackageSandbox=1
    'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox'
)

FILTERS=("$@")

filter_flags=()
for f in ${FILTERS[@]+"${FILTERS[@]}"}; do
    if [[ "$f" == MoolahUITests_macOS/* ]]; then
        filter_flags+=("-only-testing:$f")
    else
        filter_flags+=("-only-testing:MoolahUITests_macOS/$f")
    fi
done

echo "==> Running UI tests on native macOS…"
# Capture xcodebuild output in a tmpfile so we can both print it live and
# scan it afterwards for ARTEFACT_DIR lines emitted by MoolahUITestCase
# when a test fails. The runner is sandboxed and cannot write directly to
# the worktree's `.agent-tmp/`, so artefacts land under
# `$TMPDIR/MoolahUITests/`. We copy them back here so subsequent agent
# inspection (and CI uploads) can find them in the conventional location.
LOG_FILE="$(mktemp)"
trap 'rm -f "$LOG_FILE"' EXIT

set +e
xcodebuild test "${COMMON_ARGS[@]}" \
    -derivedDataPath "$REPO_ROOT/.DerivedData-mac-ui" \
    -scheme Moolah-macOS-UITests \
    -destination "platform=macOS" \
    ${filter_flags[@]+"${filter_flags[@]}"} \
    | tee "$LOG_FILE"
EXIT_CODE=${PIPESTATUS[0]}
set -e

# Mirror any captured artefact directories back into the repo's .agent-tmp/
# so they survive after $TMPDIR cleanup.
mkdir -p "$REPO_ROOT/.agent-tmp"
copied=0
while IFS= read -r src; do
    [ -d "$src" ] || continue
    dest="$REPO_ROOT/.agent-tmp/$(basename "$src")"
    rm -rf "$dest"
    cp -R "$src" "$dest"
    copied=$((copied + 1))
    echo "==> mirrored artefacts: $dest"
done < <(grep -oE '\[MoolahUITestCase\] ARTEFACT_DIR [^ ]+' "$LOG_FILE" \
    | awk '{print $3}' | sort -u)

if [ "$EXIT_CODE" -eq 0 ]; then
    echo ""
    echo "==> UI tests passed."
else
    echo ""
    echo "==> UI tests FAILED (exit $EXIT_CODE). $copied artefact dir(s) copied to .agent-tmp/."
    exit "$EXIT_CODE"
fi
