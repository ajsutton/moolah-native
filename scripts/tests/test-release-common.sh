#!/usr/bin/env bash
# Unit tests for scripts/lib/release-common.sh.
# Run via: just test-release-scripts
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/release-common.sh"

PASS=0
FAIL=0

assert_eq() {
    local expected="$1" actual="$2" name="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf '  PASS: %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  FAIL: %s\n' "$name"
        printf '    expected: %s\n' "$expected"
        printf '    actual:   %s\n' "$actual"
        FAIL=$((FAIL + 1))
    fi
}

echo "== compute_next_rc_version =="

# Case 1: no tags at all (first release ever).
result=$(compute_next_rc_version "1.0.0" "")
assert_eq \
    '{"version":"1.0.0-rc.1","confirm_marketing":false,"notes_base":""}' \
    "$result" \
    "first rc, no prior tags"

# Case 2: rc.1 already exists, bump to rc.2.
tags=$'v1.0.0-rc.1'
result=$(compute_next_rc_version "1.0.0" "$tags")
assert_eq \
    '{"version":"1.0.0-rc.2","confirm_marketing":false,"notes_base":"v1.0.0-rc.1"}' \
    "$result" \
    "second rc"

# Case 3: rc.10 ordering (lexicographic vs numeric).
tags=$'v1.0.0-rc.1\nv1.0.0-rc.2\nv1.0.0-rc.9\nv1.0.0-rc.10'
result=$(compute_next_rc_version "1.0.0" "$tags")
assert_eq \
    '{"version":"1.0.0-rc.11","confirm_marketing":false,"notes_base":"v1.0.0-rc.10"}' \
    "$result" \
    "rc.10 sorts numerically"

# Case 4: previous final exists, no RC for new marketing version.
tags=$'v0.9.0-rc.1\nv0.9.0\nv1.0.0-rc.1\nv1.0.0'
result=$(compute_next_rc_version "1.1.0" "$tags")
assert_eq \
    '{"version":"1.1.0-rc.1","confirm_marketing":true,"notes_base":"v1.0.0"}' \
    "$result" \
    "rc.1 after final, confirm_marketing=true"

# Case 5: prior RCs from older marketing versions don't bleed in.
tags=$'v0.9.0-rc.1\nv0.9.0\nv1.0.0-rc.1\nv1.0.0\nv1.1.0-rc.3'
result=$(compute_next_rc_version "1.1.0" "$tags")
assert_eq \
    '{"version":"1.1.0-rc.4","confirm_marketing":false,"notes_base":"v1.1.0-rc.3"}' \
    "$result" \
    "rc.N+1 ignores other marketing versions"

echo
echo "== compute_final_version =="

# Case 6: final after rc.3.
tags=$'v1.1.0-rc.1\nv1.1.0-rc.2\nv1.1.0-rc.3\nv1.0.0'
result=$(compute_final_version "1.1.0" "$tags" "abc1234")
assert_eq \
    '{"version":"1.1.0","rc_tag":"v1.1.0-rc.3","commit":"abc1234","notes_base":"v1.0.0"}' \
    "$result" \
    "final picks latest RC and prev final"

# Case 7: final but no RC exists — must error.
if compute_final_version "1.1.0" "" "abc1234" 2>/dev/null; then
    echo "  FAIL: final with no RC should have errored"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: final with no RC errors"
    PASS=$((PASS + 1))
fi

# Case 8: final with no prior final.
tags=$'v1.0.0-rc.1'
result=$(compute_final_version "1.0.0" "$tags" "abc1234")
assert_eq \
    '{"version":"1.0.0","rc_tag":"v1.0.0-rc.1","commit":"abc1234","notes_base":""}' \
    "$result" \
    "final with no prior final"

echo
echo "Total: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
