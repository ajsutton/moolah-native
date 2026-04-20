#!/usr/bin/env bash
# Verifies that the binary used as test host is not signed with any iCloud
# entitlement. Fails the test run if one is found. Called by scripts/test.sh
# after a platform's test action completes. See
# plans/2026-04-20-strip-icloud-from-tests-design.md.
set -euo pipefail

HOST="${1:-}"
if [[ -z "$HOST" ]]; then
    echo "usage: $0 <path-to-host-binary>" >&2
    exit 2
fi

if [[ ! -e "$HOST" ]]; then
    # Missing binary is not itself a leak, but indicates the caller passed the
    # wrong path — surface it rather than silently "pass".
    echo "ERROR: test host binary not found at $HOST" >&2
    exit 2
fi

# `codesign -d --entitlements :-` writes the entitlements plist to stdout and
# logs framing like `Executable=...` to stderr. Grep stdout only.
entitlements="$(codesign -d --entitlements :- "$HOST" 2>/dev/null || true)"

if printf '%s' "$entitlements" | grep -qi 'icloud'; then
    echo "ERROR: test host $HOST is signed with iCloud entitlements:" >&2
    printf '%s\n' "$entitlements" >&2
    exit 1
fi
