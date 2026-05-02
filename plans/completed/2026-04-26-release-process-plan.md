# Release Process Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the RC and final release pipeline described in `plans/2026-04-26-release-process-design.md` — local `just` atoms, a runbook, GitHub workflows for RC + final, Mac DMG signing/notarisation, and an AI skill that drives the procedure.

**Architecture:** Three layers, no duplication. `justfile` targets are atomic verbs (source of truth for what each step does). `guides/RELEASE_GUIDE.md` is the runbook (source of truth for the procedure). `.claude/skills/cutting-a-release/SKILL.md` is a thin AI wrapper that points at the runbook. GitHub workflows do the heavy build/notarise/submit work; the local atoms create GH releases and tags.

**Tech Stack:** Bash (scripts), `gh` CLI (GitHub Releases), Fastlane + `match` (signing), `notarytool` + `stapler` (notarisation), `create-dmg` (DMG packaging), GitHub Actions (CI).

---

## Pre-flight context for the executor

Read these before starting:
- `plans/2026-04-26-release-process-design.md` — the design spec (just merged with this plan).
- `CLAUDE.md` — repo conventions (worktree-only edits, `git -C` over `cd && git`, `just` targets for build/test, no direct push to `main`, `TODO(#N)` rule, etc.).
- `guides/BRAND_GUIDE.md` — voice for the runbook's "release notes" instructions.
- `.github/workflows/testflight.yml` — current workflow being replaced.
- `fastlane/Fastfile` — current iOS lanes (`certificates`, `validate`, `beta`).
- `scripts/check-todos.sh` + `scripts/lib/todo-extract.sh` — reference pattern for split-script-with-shared-lib.
- `justfile` — existing recipe style.

Conventions used by every task in this plan:
- All edits happen in this worktree (`.worktrees/release-process-design/`); never in the main checkout.
- Every commit message starts with a `<scope>: ` prefix (`scripts:`, `workflows:`, `fastlane:`, `guides:`, `skills:`, `plans:`).
- After modifying any Swift, `just format && just format-check` before commit. (No tasks here modify Swift, so this is unlikely to trigger — but if you touch any `.swift` file in the course of debugging, run it.)
- After modifying anything: `git -C <worktree> status` to confirm only intended files changed.
- Push to the existing PR branch (`release-process-design`) at the end of each task with a meaningful commit. Do not force-push, do not amend.

---

## Task 0: One-time manual setup (operator)

**Owner:** Adrian (manual). The agent does not perform these steps but checks they are done before subsequent tasks rely on them.

**Why this exists in the plan:** Mac DMG signing/notarisation requires a Developer ID Application certificate that doesn't exist yet, and `release-final.yml`'s automerge bump-PR requires GitHub branch-protection settings that may not be enabled.

- [ ] **Step 1: Create Match repo entry for Developer ID Application cert**

Run locally on Adrian's Mac (one-time):

```bash
cd /Users/aj/Documents/code/moolah-project/moolah-native
bundle exec fastlane match developer_id --app_identifier rocks.moolah.app
```

When prompted, enter the Match passphrase from your existing setup. This creates a `Developer ID Application` cert + provisioning profile in the Match git repo and installs them into the local keychain.

Verify:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Expected: a single matching identity for the team ID in `DEVELOPMENT_TEAM`.

- [ ] **Step 2: Confirm App Store Connect API key secrets are present in GitHub**

Check that the repo has these secrets (Settings → Secrets and variables → Actions):
- `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT` (already present, used by `testflight.yml`)
- `MATCH_GIT_URL`, `MATCH_PASSWORD`, `MATCH_GIT_BASIC_AUTHORIZATION` (already present)
- `DEVELOPMENT_TEAM`, `CKTOOL_MANAGEMENT_TOKEN` (already present)

No new secrets needed — Mac DMG notarisation reuses the ASC API key.

- [ ] **Step 3: Enable repo automerge**

GitHub repo Settings → General → "Allow auto-merge" → check the box. (Required for `gh pr merge --auto` to succeed in `release-final.yml`.)

- [ ] **Step 4: Confirm branch protection on `main` allows automated PR merges**

Settings → Branches → `main` rule. The merge-queue daemon already submits squash merges as a bot user; the bump PR uses the same path. No change needed unless the rule blocks bot merges.

- [ ] **Step 5: Mark this task complete**

Add a one-line confirmation in the PR comment thread once all four steps are verified, then untick the boxes for tracking. The agent reads the PR comment to confirm before starting Task 8 (the runbook documents the prerequisites once they exist).

---

## Task 1: Shared release-script library + tests

**Files:**
- Create: `scripts/lib/release-common.sh`
- Create: `scripts/tests/test-release-common.sh`

This task implements the pure-function logic for next-version computation. Pulling it into a library lets us unit-test it without git side effects.

- [ ] **Step 1: Write the failing tests**

Create `scripts/tests/test-release-common.sh`:

```bash
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
```

- [ ] **Step 2: Run the tests, confirm they fail**

```bash
bash scripts/tests/test-release-common.sh
```

Expected: fails (`compute_next_rc_version: command not found` or similar).

- [ ] **Step 3: Implement `scripts/lib/release-common.sh`**

```bash
#!/usr/bin/env bash
# Shared helpers for release-* scripts. Pure functions where possible.
# Sourced by scripts/release-*.sh and tests/test-release-common.sh.

# json_escape: escape a string for safe JSON inclusion (basic — handles
# the chars a tag or commit might contain).
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# compute_next_rc_version <marketing_version> <newline_separated_tags>
# Emits JSON: {"version":"<MV>-rc.<N>","confirm_marketing":<bool>,"notes_base":"<tag>"}
compute_next_rc_version() {
    local marketing_version="$1"
    local tags="$2"

    local rc_tags last_rc last_num next_rc_num
    rc_tags=$(printf '%s\n' "$tags" \
        | grep -E "^v${marketing_version//./\\.}-rc\\.[0-9]+$" \
        | sort -V \
        || true)

    local confirm_marketing="false"
    local notes_base=""

    if [[ -z "$rc_tags" ]]; then
        next_rc_num=1
        local prev_final
        prev_final=$(printf '%s\n' "$tags" \
            | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
            | sort -V \
            | tail -1 \
            || true)
        if [[ -n "$prev_final" ]]; then
            confirm_marketing="true"
            notes_base="$prev_final"
        fi
    else
        last_rc=$(printf '%s\n' "$rc_tags" | tail -1)
        last_num="${last_rc##*-rc.}"
        next_rc_num=$((last_num + 1))
        notes_base="$last_rc"
    fi

    printf '{"version":"%s-rc.%s","confirm_marketing":%s,"notes_base":"%s"}\n' \
        "$(json_escape "$marketing_version")" \
        "$next_rc_num" \
        "$confirm_marketing" \
        "$(json_escape "$notes_base")"
}

# compute_final_version <marketing_version> <newline_separated_tags> <rc_commit_sha>
# Emits JSON: {"version":"<MV>","rc_tag":"<tag>","commit":"<sha>","notes_base":"<tag>"}
# Errors (exits non-zero) if no RC exists for the marketing version.
compute_final_version() {
    local marketing_version="$1"
    local tags="$2"
    local rc_commit="$3"

    local rc_tags last_rc
    rc_tags=$(printf '%s\n' "$tags" \
        | grep -E "^v${marketing_version//./\\.}-rc\\.[0-9]+$" \
        | sort -V \
        || true)

    if [[ -z "$rc_tags" ]]; then
        printf 'compute_final_version: no RC tag exists for marketing version %s\n' \
            "$marketing_version" >&2
        return 1
    fi
    last_rc=$(printf '%s\n' "$rc_tags" | tail -1)

    local prev_final
    prev_final=$(printf '%s\n' "$tags" \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -V \
        | tail -1 \
        || true)

    printf '{"version":"%s","rc_tag":"%s","commit":"%s","notes_base":"%s"}\n' \
        "$(json_escape "$marketing_version")" \
        "$(json_escape "$last_rc")" \
        "$(json_escape "$rc_commit")" \
        "$(json_escape "$prev_final")"
}

# read_marketing_version_from_project_yml [path]
# Reads MARKETING_VERSION from project.yml. Path defaults to ./project.yml.
read_marketing_version_from_project_yml() {
    local path="${1:-project.yml}"
    grep 'MARKETING_VERSION:' "$path" | head -1 | sed 's/.*"\(.*\)".*/\1/'
}

# read_all_tags
# Returns newline-separated list of all tags in the current repo.
read_all_tags() {
    git tag -l
}
```

- [ ] **Step 4: Re-run tests, confirm they pass**

```bash
bash scripts/tests/test-release-common.sh
```

Expected: `Total: 8 passed, 0 failed`.

- [ ] **Step 5: Add `just test-release-scripts` target**

Append to `justfile` (after the `test-ui` recipe, before `build-mac`):

```just
# Run unit tests for release-script helpers (no git/network side effects).
test-release-scripts:
    bash scripts/tests/test-release-common.sh
```

- [ ] **Step 6: Verify just target works**

```bash
just test-release-scripts
```

Expected: same passing output.

- [ ] **Step 7: Commit**

```bash
git -C .worktrees/release-process-design add scripts/lib/release-common.sh \
    scripts/tests/test-release-common.sh justfile
git -C .worktrees/release-process-design commit -m "scripts: add release-common library with version-calc helpers"
```

---

## Task 2: `release-preflight` script + `just` target

**Files:**
- Create: `scripts/release-preflight.sh`
- Modify: `justfile` (add target)

- [ ] **Step 1: Create `scripts/release-preflight.sh`**

```bash
#!/usr/bin/env bash
# Verifies the local repo is in a state suitable for cutting a release.
# Exits zero on success, non-zero with a descriptive message on failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/release-common.sh"

fail() {
    printf '✗ %s\n' "$1" >&2
    exit 1
}

# 1. On main branch.
branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$branch" != "main" ]]; then
    fail "must be on main (currently on '$branch')"
fi

# 2. Working tree is clean.
if ! git diff-index --quiet HEAD --; then
    fail "working tree has uncommitted changes"
fi
if [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    fail "working tree has untracked files"
fi

# 3. In sync with origin/main.
git fetch origin main --quiet
local_sha=$(git rev-parse HEAD)
remote_sha=$(git rev-parse origin/main)
if [[ "$local_sha" != "$remote_sha" ]]; then
    fail "local main ($local_sha) is not in sync with origin/main ($remote_sha)"
fi

# 4. gh authenticated.
if ! gh auth status >/dev/null 2>&1; then
    fail "gh CLI is not authenticated (run 'gh auth login')"
fi

# 5. Latest CI run on main passed.
ci_status=$(gh run list --branch main --limit 1 \
    --json status,conclusion --jq '.[0] | "\(.status):\(.conclusion)"')
case "$ci_status" in
    completed:success) ;;
    completed:*) fail "latest CI run on main concluded as ${ci_status#completed:}" ;;
    in_progress:*|queued:*) fail "CI is still running on main; wait for it to finish" ;;
    *) fail "unexpected CI status '$ci_status'" ;;
esac

printf '✓ release-preflight passed\n'
printf '  branch: %s\n' "$branch"
printf '  HEAD:   %s\n' "$local_sha"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/release-preflight.sh
```

- [ ] **Step 3: Add `just` target**

Append to `justfile` (group with the other release- targets — recommend a "Release" section comment heading):

```just
# === Release ===
# Verify the local repo is on main, clean, in sync with origin, gh
# authenticated, and CI green. Used by both RC and final flows.
release-preflight:
    bash scripts/release-preflight.sh
```

- [ ] **Step 4: Smoke-test on the worktree**

The worktree is on `release-process-design`, not `main`. The script should fail at step 1.

```bash
bash scripts/release-preflight.sh || echo "expected failure"
```

Expected: `✗ must be on main (currently on 'release-process-design')` then `expected failure`.

- [ ] **Step 5: Commit**

```bash
git -C .worktrees/release-process-design add scripts/release-preflight.sh justfile
git -C .worktrees/release-process-design commit -m "scripts: add release-preflight"
```

---

## Task 3: `release-next-version` script + `just` target

**Files:**
- Create: `scripts/release-next-version.sh`
- Modify: `justfile`

- [ ] **Step 1: Create `scripts/release-next-version.sh`**

```bash
#!/usr/bin/env bash
# Computes the proposed version for the next RC or final tag.
# Usage: release-next-version (rc|final)
# Output: JSON on stdout. See compute_next_rc_version / compute_final_version
# in lib/release-common.sh for the schema.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/release-common.sh"

usage() {
    printf 'Usage: %s (rc|final)\n' "$(basename "$0")" >&2
    exit 2
}

[[ "$#" -eq 1 ]] || usage

kind="$1"
mv=$(read_marketing_version_from_project_yml)
[[ -n "$mv" ]] || { echo "could not read MARKETING_VERSION from project.yml" >&2; exit 1; }

tags=$(read_all_tags)

case "$kind" in
    rc)
        compute_next_rc_version "$mv" "$tags"
        ;;
    final)
        # Find the latest RC for this marketing version to resolve the commit SHA.
        last_rc=$(printf '%s\n' "$tags" \
            | grep -E "^v${mv//./\\.}-rc\\.[0-9]+$" \
            | sort -V \
            | tail -1 \
            || true)
        if [[ -z "$last_rc" ]]; then
            printf 'no RC tag exists for marketing version %s — cut an RC first\n' \
                "$mv" >&2
            exit 1
        fi
        rc_commit=$(git rev-list -n 1 "$last_rc")
        compute_final_version "$mv" "$tags" "$rc_commit"
        ;;
    *)
        usage
        ;;
esac
```

- [ ] **Step 2: Make executable + add just target**

```bash
chmod +x scripts/release-next-version.sh
```

Append to `justfile`:

```just
# Compute the proposed version for the next release tag.
# KIND=rc|final. Emits JSON to stdout (see scripts/lib/release-common.sh).
release-next-version KIND:
    bash scripts/release-next-version.sh {{KIND}}
```

- [ ] **Step 3: Smoke-test against current repo state**

```bash
just release-next-version rc | jq .
```

Expected: JSON object with `version`, `confirm_marketing`, `notes_base` fields. The exact values depend on current `MARKETING_VERSION` and tag state.

```bash
just release-next-version final 2>&1 | head -2
```

Expected: error message about no RC tag (since no `v1.0.0-rc.*` tags exist yet at the time of writing).

- [ ] **Step 4: Commit**

```bash
git -C .worktrees/release-process-design add scripts/release-next-version.sh justfile
git -C .worktrees/release-process-design commit -m "scripts: add release-next-version"
```

---

## Task 4: `release-create-rc` script + `just` target

**Files:**
- Create: `scripts/release-create-rc.sh`
- Modify: `justfile`

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
# Creates a GitHub pre-release at HEAD with the given notes file.
# Creating the GH release also creates the underlying tag, which fires
# release-rc.yml. Errors if a release with the requested tag already exists.
#
# Usage: release-create-rc VERSION NOTES_FILE
#   VERSION:    semver+rc form (e.g. "1.2.0-rc.1")
#   NOTES_FILE: path to a markdown file containing the release notes
set -euo pipefail

[[ "$#" -eq 2 ]] || {
    printf 'Usage: %s VERSION NOTES_FILE\n' "$(basename "$0")" >&2
    exit 2
}

version="$1"
notes_file="$2"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]] || {
    printf 'invalid RC version: %s (expected X.Y.Z-rc.N)\n' "$version" >&2
    exit 1
}

[[ -f "$notes_file" ]] || {
    printf 'notes file does not exist: %s\n' "$notes_file" >&2
    exit 1
}

tag="v${version}"

# Refuse if release already exists.
if gh release view "$tag" >/dev/null 2>&1; then
    printf 'release %s already exists\n' "$tag" >&2
    exit 1
fi

gh release create "$tag" \
    --target main \
    --title "$tag" \
    --notes-file "$notes_file" \
    --prerelease

printf '✓ created GH pre-release %s; release-rc.yml will fire shortly\n' "$tag"
printf '  watch: just release-wait %s\n' "$tag"
```

- [ ] **Step 2: Make executable + add just target**

```bash
chmod +x scripts/release-create-rc.sh
```

Append to `justfile`:

```just
# Create the GH pre-release for an RC. Creates the tag at HEAD of main,
# which fires release-rc.yml. NOTES_FILE is a path to a markdown file
# containing the user-facing release notes (see guides/RELEASE_GUIDE.md).
release-create-rc VERSION NOTES_FILE:
    bash scripts/release-create-rc.sh {{VERSION}} {{NOTES_FILE}}
```

- [ ] **Step 3: Verify dry-run behaviour**

The script can't be safely smoke-tested without actually creating a release. Verify the validation paths:

```bash
just release-create-rc not-a-version /tmp/missing.md 2>&1 | head -2
```

Expected: `invalid RC version: not-a-version (expected X.Y.Z-rc.N)`.

```bash
just release-create-rc 1.0.0-rc.1 /tmp/missing.md 2>&1 | head -2
```

Expected: `notes file does not exist: /tmp/missing.md`.

- [ ] **Step 4: Commit**

```bash
git -C .worktrees/release-process-design add scripts/release-create-rc.sh justfile
git -C .worktrees/release-process-design commit -m "scripts: add release-create-rc"
```

---

## Task 5: `release-create-final` script + `just` target

**Files:**
- Create: `scripts/release-create-final.sh`
- Modify: `justfile`

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
# Creates a GitHub release at the same commit as the named RC tag.
# Creating the GH release also creates the final tag at that commit,
# which fires release-final.yml.
#
# Usage: release-create-final VERSION RC_TAG NOTES_FILE
#   VERSION:    semver form (e.g. "1.2.0")
#   RC_TAG:     the RC tag to promote (e.g. "v1.2.0-rc.3")
#   NOTES_FILE: path to a markdown file with end-user release notes
set -euo pipefail

[[ "$#" -eq 3 ]] || {
    printf 'Usage: %s VERSION RC_TAG NOTES_FILE\n' "$(basename "$0")" >&2
    exit 2
}

version="$1"
rc_tag="$2"
notes_file="$3"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'invalid final version: %s (expected X.Y.Z)\n' "$version" >&2
    exit 1
}

[[ "$rc_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]] || {
    printf 'invalid RC tag: %s (expected vX.Y.Z-rc.N)\n' "$rc_tag" >&2
    exit 1
}

[[ -f "$notes_file" ]] || {
    printf 'notes file does not exist: %s\n' "$notes_file" >&2
    exit 1
}

# Resolve the RC's commit. git rev-list errors if the tag is unknown.
rc_commit=$(git rev-list -n 1 "$rc_tag")

final_tag="v${version}"

if gh release view "$final_tag" >/dev/null 2>&1; then
    printf 'release %s already exists\n' "$final_tag" >&2
    exit 1
fi

gh release create "$final_tag" \
    --target "$rc_commit" \
    --title "$final_tag" \
    --notes-file "$notes_file"

printf '✓ created GH release %s at commit %s (same commit as %s)\n' \
    "$final_tag" "$rc_commit" "$rc_tag"
printf '  watch: just release-wait %s\n' "$final_tag"
```

- [ ] **Step 2: Make executable + add just target**

```bash
chmod +x scripts/release-create-final.sh
```

Append to `justfile`:

```just
# Create the final GH release. Creates the tag at the same commit as
# the named RC, which fires release-final.yml.
release-create-final VERSION RC_TAG NOTES_FILE:
    bash scripts/release-create-final.sh {{VERSION}} {{RC_TAG}} {{NOTES_FILE}}
```

- [ ] **Step 3: Verify validation**

```bash
just release-create-final 1.0.0 not-a-tag /tmp/x.md 2>&1 | head -2
```

Expected: `invalid RC tag: not-a-tag (expected vX.Y.Z-rc.N)`.

- [ ] **Step 4: Commit**

```bash
git -C .worktrees/release-process-design add scripts/release-create-final.sh justfile
git -C .worktrees/release-process-design commit -m "scripts: add release-create-final"
```

---

## Task 6: `release-wait` and `release-status` scripts + `just` targets

**Files:**
- Create: `scripts/release-wait.sh`
- Create: `scripts/release-status.sh`
- Modify: `justfile`

These are merged into one task because they're small and share lookup logic.

- [ ] **Step 1: Create `scripts/release-wait.sh`**

```bash
#!/usr/bin/env bash
# Polls the workflow run associated with a tag until terminal.
# Exits zero on success; the workflow's conclusion code otherwise.
#
# Usage: release-wait TAG
set -euo pipefail

[[ "$#" -eq 1 ]] || {
    printf 'Usage: %s TAG\n' "$(basename "$0")" >&2
    exit 2
}

tag="$1"

# Determine which workflow file matches the tag pattern.
if [[ "$tag" == *-rc.* ]]; then
    workflow="release-rc.yml"
else
    workflow="release-final.yml"
fi

# Find the most recent run on this tag's ref.
# (`gh run list --branch <tag>` matches workflow runs whose head_branch
# equals the tag name — the case for tag-triggered workflows.)
run_id=""
for _ in {1..30}; do
    run_id=$(gh run list --workflow="$workflow" --branch="$tag" \
        --limit 1 --json databaseId --jq '.[0].databaseId // empty')
    [[ -n "$run_id" ]] && break
    sleep 2
done

if [[ -z "$run_id" ]]; then
    printf 'no workflow run found for %s on %s after 60s\n' "$workflow" "$tag" >&2
    exit 1
fi

printf 'watching %s run %s for tag %s\n' "$workflow" "$run_id" "$tag"
gh run watch "$run_id" --exit-status
```

- [ ] **Step 2: Create `scripts/release-status.sh`**

```bash
#!/usr/bin/env bash
# Prints a human-readable summary of a release: workflow status, GH
# release assets, and (for final tags) App Store submission state.
#
# Usage: release-status TAG
set -euo pipefail

[[ "$#" -eq 1 ]] || {
    printf 'Usage: %s TAG\n' "$(basename "$0")" >&2
    exit 2
}

tag="$1"

if [[ "$tag" == *-rc.* ]]; then
    workflow="release-rc.yml"
else
    workflow="release-final.yml"
fi

printf '== Release %s ==\n' "$tag"

# GH release.
if gh release view "$tag" >/dev/null 2>&1; then
    printf '\nGitHub release:\n'
    gh release view "$tag" --json tagName,isPrerelease,createdAt,assets \
        --jq '"  tag:        \(.tagName)\n  prerelease: \(.isPrerelease)\n  created:    \(.createdAt)\n  assets:     \([.assets[].name] | join(", "))"'
else
    printf '\nGitHub release: NOT FOUND\n'
fi

# Workflow run.
printf '\nWorkflow:\n'
run_status=$(gh run list --workflow="$workflow" --branch="$tag" \
    --limit 1 --json status,conclusion,databaseId,createdAt --jq '.[0]')
if [[ -z "$run_status" || "$run_status" == "null" ]]; then
    printf '  no run found for %s\n' "$workflow"
else
    printf '%s' "$run_status" \
        | jq -r '"  workflow:   '"$workflow"'\n  run id:     \(.databaseId)\n  status:     \(.status)\n  conclusion: \(.conclusion // "-")\n  created:    \(.createdAt)"'
fi
```

- [ ] **Step 3: Make executable + add just targets**

```bash
chmod +x scripts/release-wait.sh scripts/release-status.sh
```

Append to `justfile`:

```just
# Wait for the workflow run associated with a release tag to finish.
# Exits zero if the run succeeded, non-zero with the conclusion otherwise.
release-wait TAG:
    bash scripts/release-wait.sh {{TAG}}

# Print a summary of a release: GH release state, workflow run state,
# attached assets.
release-status TAG:
    bash scripts/release-status.sh {{TAG}}
```

- [ ] **Step 4: Smoke-test `release-status` against an existing tag**

The repo doesn't have a `v*` tag yet (release-process-design is in development), but the script should at least error gracefully on a missing tag:

```bash
just release-status v0.0.0 2>&1 | head -10
```

Expected: prints `== Release v0.0.0 ==` then `GitHub release: NOT FOUND` and `no run found for release-final.yml`.

- [ ] **Step 5: Commit**

```bash
git -C .worktrees/release-process-design add scripts/release-wait.sh \
    scripts/release-status.sh justfile
git -C .worktrees/release-process-design commit -m "scripts: add release-wait and release-status"
```

---

## Task 7: Runbook (`guides/RELEASE_GUIDE.md`)

**Files:**
- Create: `guides/RELEASE_GUIDE.md`

The runbook is the source of truth for the procedure. It cites `just` targets by name; it never explains what they do internally (that's the justfile's job).

- [ ] **Step 1: Create the runbook**

```markdown
# Release Guide

> The procedure for cutting a release. The `justfile` is the source of truth for what each `just` target does; this guide is the source of truth for which targets to run, in what order, and which decisions to make. The skill `cutting-a-release` follows this same guide.

## Conventions

- **RC tag:** `v<MAJOR>.<MINOR>.<PATCH>-rc.<N>`. Example: `v1.2.0-rc.1`, `v1.2.0-rc.2`.
- **Final tag:** `v<MAJOR>.<MINOR>.<PATCH>`. Example: `v1.2.0`.
- The final tag points at the **same commit** as the RC being promoted. The same iOS binary that was beta-tested ships to the App Store; the same notarised DMG that RC users downloaded is the one attached to the final GitHub Release.
- Tags are never deleted once pushed. Abandoned RCs and final releases stay as historical record.
- Channel signals carry the RC vs final distinction (TestFlight badge, GitHub "Pre-release" label). The binary itself is identical.

## Prerequisites

Before cutting any release, confirm these are in place. They are one-time setup items.

- [ ] Match repo contains a `Developer ID Application` cert for `rocks.moolah.app`. Verify with `security find-identity -v -p codesigning | grep "Developer ID Application"` after running `bundle exec fastlane match developer_id`.
- [ ] App Store Connect API key secrets are present in the GitHub repo: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT`.
- [ ] Match secrets are present: `MATCH_GIT_URL`, `MATCH_PASSWORD`, `MATCH_GIT_BASIC_AUTHORIZATION`.
- [ ] CloudKit secrets are present: `DEVELOPMENT_TEAM`, `CKTOOL_MANAGEMENT_TOKEN`.
- [ ] GitHub repo allows auto-merge (Settings → General → "Allow auto-merge").

## Cut a release candidate

1. **Pre-flight.** Run `just release-preflight`. Fix any issue it reports (push outstanding work, sync with origin, authenticate `gh`, wait for green CI) before continuing.

2. **Determine the version.** Run `just release-next-version rc`. Read the JSON output:
   - `version` — the proposed RC version (e.g. `1.2.0-rc.2`).
   - `confirm_marketing` — `true` when the previous tag was a final release. When true, confirm the marketing version in `project.yml` is right for the new RC. If wrong, run `just bump-version <X.Y.Z>`, open a PR to land it, then return to step 1.
   - `notes_base` — the previous RC tag (or previous final, if this is `rc.1`). Use this as the comparison base when authoring release notes.

3. **Author release notes.** RC notes describe what changed since `notes_base` — the audience is testers; they want the delta from the previous RC. See "Authoring release notes" below for the procedure. Save the draft to `.agent-tmp/release-notes-<version>.md`.

4. **Cut the GH pre-release.** Run `just release-create-rc <version> .agent-tmp/release-notes-<version>.md`. This creates the tag, which fires `release-rc.yml`.

5. **Wait + verify.** Run `just release-wait v<version>`. When it returns successfully, run `just release-status v<version>` to confirm the IPA reached TestFlight, the DMG is attached to the GH pre-release, and the CloudKit schema was promoted.

6. **Smoke-test.** Install the TestFlight build (iOS device + simulator) and the DMG (Mac). If anything is broken, document the issue, fix on `main`, and cut a fresh RC. Don't delete the bad RC; mark its release body to note it is obsolete.

## Promote an RC to final

1. **Pre-flight.** Run `just release-preflight`. Confirm the latest RC for the current marketing version has been smoke-tested and is the one you want to ship.

2. **Determine the version.** Run `just release-next-version final`. The JSON includes `version`, `rc_tag`, `commit`, and `notes_base` (the previous final tag).

3. **Author final release notes.** Final notes describe what changed since `notes_base` (the previous final release) — the audience is end-users; they want the cumulative picture, polished. The release notes you wrote for the RC are a starting point but typically need to be rewritten for the final audience. Save to `.agent-tmp/release-notes-<version>.md`.

4. **Cut the final GH release.** Run `just release-create-final <version> <rc_tag> .agent-tmp/release-notes-<version>.md`. This creates the final tag at the same commit as the RC and fires `release-final.yml`.

5. **Wait.** Run `just release-wait v<version>`.

6. **Verify.** Run `just release-status v<version>`. Confirm:
   - Workflow concluded successfully.
   - The DMG asset on the final release is the same DMG from the RC release.
   - A version-bump PR was opened (with automerge enabled).
   - App Store Connect shows the existing TestFlight build was submitted for review with auto-release after approval enabled.

7. **Review the bump PR.** It is opened with the default minor bump and automerge enabled. If you want a different bump (major / patch / explicit version), edit `project.yml` in the PR before automerge fires; otherwise let it merge.

## Authoring release notes

Both RC and final notes are authored manually (or by an AI assistant following this section). Auto-generated lists from PR titles do not capture user-facing intent; we write notes that highlight changes that actually matter.

### Research

- The comparison base is `notes_base` from `just release-next-version`.
- Read merged PRs: `gh pr list --state merged --search "merged:>=<base-date>"`. Read PR bodies, not just titles — many user-facing changes are richer than the one-liner.
- Read commits: `git log <notes_base>..HEAD --oneline` for the full picture, then `git log <notes_base>..HEAD -p -- <path>` for any change worth understanding in detail.

### Filtering

- Keep changes a real user would notice: new features, changed behaviour, fixed bugs they could hit, performance wins they will feel.
- Drop pure refactors, internal cleanups, test-only changes, doc-only changes, and CI tweaks.
- Aggregate small fixes into a single "Fixes and polish" item rather than enumerating them.

### Voice

Follow `guides/BRAND_GUIDE.md`:
- Confident but warm, plain-spoken, "you" / "your".
- Short sentences. Fragments are fine.
- No corporate-speak ("leverage", "optimize", "empower").
- No automation or bank-sync claims (the app uses manual entry).
- Don't use "just" dismissively.

### RC vs final scope

- RC notes describe the delta since the previous RC for this marketing version (or the previous final, if this is `rc.1`). Keep them tight; testers care about what's new since they last installed.
- Final notes describe the cumulative changes since the previous final release. Polished for end-users; this is what shows up in App Store Connect (eventually) and on the GitHub Release page.

## Recovery

### Schema promoted, build failed mid-RC
The schema is in Production permanently. Diagnose the build failure on `main`, fix it, cut a new RC. The next RC's schema verify step will pass because the prod baseline now matches the proposed schema. The bad RC's GH pre-release stays as a record; edit its body to note it is obsolete.

### iOS upload succeeded, Mac DMG step failed
Re-run the workflow run from the failed step (Actions → Run → Re-run failed jobs). Notarisation hiccups are usually transient. If a config issue, fix on `main` and cut a new RC.

### Notarisation timeout
`notarytool submit --wait` blocks for up to ~30 min. Re-running the workflow fetches the existing submission status rather than re-submitting. If the queue is genuinely slow, give it another hour.

### RC failed smoke-testing
Don't promote it. Cut a new RC. The bad RC's GH pre-release stays for traceability — edit the release body to note it.

### Marketing version needs to skip ahead
Open a PR that bumps `MARKETING_VERSION` past it (or back, if you really need to). Land through the merge-queue. The next RC reads the new value.

### Final workflow fails after submission
Re-run the workflow. The build is unchanged; idempotent steps (DMG copy, bump PR creation) are safe to retry.

### Apple rejects the App Store submission
Address feedback on `main`, cut a new RC + final cycle. Auto-release is per-submission, so the rejected submission has no live effect.

### Bump PR has merge conflicts
The PR is opened anyway. Resolve manually and let merge-queue handle it. The release itself is already complete; the bump PR is only there to set up the next cycle.

### Erroneous tag pushed
**Never delete the tag.** The bad release stays as record. Move forward with a new RC or final tag at a new commit. Edit the bad release's body to note that it is obsolete.
```

- [ ] **Step 2: Verify nothing in the runbook duplicates what a `just` target does**

Re-read the runbook. For each `just <verb>` reference, confirm the runbook only says **when** and **why** to run it, never **what it does internally**. (The justfile's recipe comments hold that.)

- [ ] **Step 3: Commit**

```bash
git -C .worktrees/release-process-design add guides/RELEASE_GUIDE.md
git -C .worktrees/release-process-design commit -m "guides: add RELEASE_GUIDE.md"
```

---

## Task 8: Fastlane — add `mac_dmg` lane

**Files:**
- Modify: `fastlane/Matchfile` (or supplementary call) — keep iOS appstore type as default; the Developer ID profile is fetched explicitly in the lane.
- Modify: `fastlane/Fastfile` — add `mac_dmg` lane.
- Create: `fastlane/Moolah-mac.entitlements` — Mac-specific entitlements for distribution outside the App Store.

The Mac entitlements file is separate from `fastlane/Moolah.entitlements` (which is iOS App Store) because Mac distribution outside the App Store has different requirements (no app sandbox in some cases, hardened runtime, etc.). Verify what the existing macOS Release config bakes in by reading `project.yml` for the `Moolah_macOS` target.

- [ ] **Step 1: Create `fastlane/Moolah-mac.entitlements`**

Mirror `fastlane/Moolah.entitlements` but for the Mac DMG:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.developer.icloud-container-identifiers</key>
  <array><string>iCloud.rocks.moolah.app.v2</string></array>
  <key>com.apple.developer.icloud-services</key>
  <array><string>CloudKit</string></array>
  <key>com.apple.developer.icloud-container-environment</key>
  <string>Production</string>
  <key>com.apple.security.app-sandbox</key>
  <true/>
  <key>com.apple.security.network.client</key>
  <true/>
  <key>com.apple.security.files.user-selected.read-write</key>
  <true/>
</dict>
</plist>
```

The added `com.apple.security.files.user-selected.read-write` entitlement allows users to import/export `.moolah-export` files via the standard sandbox file picker — useful for direct-distribution Mac users.

- [ ] **Step 2: Add the `mac_dmg` lane to `fastlane/Fastfile`**

Append after the existing iOS platform block:

```ruby
platform :mac do
  before_all do
    setup_ci
  end

  desc "Sync Developer ID certificates and profiles for Mac distribution"
  lane :certificates do
    api_key = app_store_connect_api_key(
      key_id: ENV["ASC_KEY_ID"],
      issuer_id: ENV["ASC_ISSUER_ID"],
      key_content: ENV["ASC_KEY_CONTENT"],
      is_key_content_base64: true
    )

    match(
      type: "developer_id",
      app_identifier: "rocks.moolah.app",
      platform: "macos",
      api_key: api_key,
      readonly: is_ci
    )
  end

  desc "Build, sign, notarise, and DMG-package the Mac app for direct distribution"
  lane :dmg do |options|
    version = options[:version] or UI.user_error!("missing :version (e.g. 1.2.0)")

    certificates

    api_key = app_store_connect_api_key(
      key_id: ENV["ASC_KEY_ID"],
      issuer_id: ENV["ASC_ISSUER_ID"],
      key_content: ENV["ASC_KEY_CONTENT"],
      is_key_content_base64: true
    )

    profile_name = ENV["sigh_rocks.moolah.app_developer_id_profile-name"]
    entitlements_path = File.expand_path("Moolah-mac.entitlements", __dir__)

    build_app(
      scheme: "Moolah-macOS",
      configuration: "Release",
      export_method: "developer-id",
      output_directory: "./build",
      output_name: "Moolah",
      xcargs: [
        "CODE_SIGN_ENTITLEMENTS=#{entitlements_path}",
        "CODE_SIGN_STYLE=Manual",
        "DEVELOPMENT_TEAM=#{ENV['DEVELOPMENT_TEAM']}",
        "'CODE_SIGN_IDENTITY=Developer ID Application'",
        "'PROVISIONING_PROFILE_SPECIFIER=#{profile_name}'",
        "ENABLE_HARDENED_RUNTIME=YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) CLOUDKIT_ENABLED'"
      ].join(" ")
    )

    app_path = "./build/Moolah.app"
    UI.user_error!("Moolah.app not found at #{app_path}") unless File.directory?(app_path)

    # Notarise the .app first (faster turnaround than notarising the DMG alone).
    sh "xcrun notarytool submit '#{app_path}' " \
       "--key '#{api_key[:key_filepath]}' " \
       "--key-id '#{api_key[:key_id]}' " \
       "--issuer '#{api_key[:issuer_id]}' " \
       "--wait"
    sh "xcrun stapler staple '#{app_path}'"

    # Build the DMG with create-dmg (assumed installed via brew on the runner).
    dmg_path = "./build/Moolah-#{version}.dmg"
    sh "rm -f '#{dmg_path}'"
    sh "create-dmg " \
       "--volname 'Moolah #{version}' " \
       "--window-size 540 380 " \
       "--icon-size 96 " \
       "--icon 'Moolah.app' 140 190 " \
       "--app-drop-link 400 190 " \
       "--no-internet-enable " \
       "'#{dmg_path}' '#{app_path}'"

    # Sign + notarise + staple the DMG itself.
    sh "codesign --sign 'Developer ID Application' --timestamp '#{dmg_path}'"
    sh "xcrun notarytool submit '#{dmg_path}' " \
       "--key '#{api_key[:key_filepath]}' " \
       "--key-id '#{api_key[:key_id]}' " \
       "--issuer '#{api_key[:issuer_id]}' " \
       "--wait"
    sh "xcrun stapler staple '#{dmg_path}'"

    UI.success("Notarised DMG ready at #{dmg_path}")
  end
end
```

- [ ] **Step 3: Verify `create-dmg` is installable on the GH runner**

Quick check — `create-dmg` is a standard Homebrew formula (`brew install create-dmg`). The workflow will install it. No verification possible without running CI.

- [ ] **Step 4: Commit**

```bash
git -C .worktrees/release-process-design add fastlane/Fastfile fastlane/Moolah-mac.entitlements
git -C .worktrees/release-process-design commit -m "fastlane: add mac_dmg lane and Mac entitlements"
```

---

## Task 9: Fastlane — add `submit_review` lane

**Files:**
- Modify: `fastlane/Fastfile`

- [ ] **Step 1: Add the `submit_review` lane to the iOS platform block**

After the existing `beta` lane in `platform :ios do … end`, add:

```ruby
  desc "Submit an existing TestFlight build for App Store review (auto-release after approval)"
  lane :submit_review do |options|
    build_number = options[:build_number] or UI.user_error!("missing :build_number")
    version = options[:version] or UI.user_error!("missing :version")

    api_key = app_store_connect_api_key(
      key_id: ENV["ASC_KEY_ID"],
      issuer_id: ENV["ASC_ISSUER_ID"],
      key_content: ENV["ASC_KEY_CONTENT"],
      is_key_content_base64: true
    )

    deliver(
      api_key: api_key,
      app_version: version,
      build_number: build_number.to_s,
      submit_for_review: true,
      automatic_release: true,
      force: true,
      skip_binary_upload: true,
      skip_metadata: true,
      skip_screenshots: true,
      precheck_include_in_app_purchases: false,
      submission_information: {
        add_id_info_uses_idfa: false,
        export_compliance_uses_encryption: false,
        export_compliance_encryption_updated: false
      }
    )

    UI.success("Submitted build #{build_number} (#{version}) for App Store review with auto-release")
  end
```

- [ ] **Step 2: Commit**

```bash
git -C .worktrees/release-process-design add fastlane/Fastfile
git -C .worktrees/release-process-design commit -m "fastlane: add submit_review lane for App Store promotion"
```

---

## Task 10: `release-rc.yml` workflow

**Files:**
- Create: `.github/workflows/release-rc.yml`
- Delete: `.github/workflows/testflight.yml`

`release-rc.yml` is a superset of the existing `testflight.yml` (iOS build + TestFlight + schema promotion) plus the Mac DMG steps and asset attachment.

- [ ] **Step 1: Create `release-rc.yml`**

```yaml
name: Release RC

on:
  push:
    tags:
      - "v[0-9]+.[0-9]+.[0-9]+-rc.[0-9]+"

permissions:
  contents: write
  pull-requests: write

jobs:
  build:
    name: Build & Upload RC artefacts
    runs-on: macos-26
    timeout-minutes: 60
    environment: testflight

    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
        with:
          fetch-depth: 0

      - name: Install tools
        run: brew install xcodegen just create-dmg

      - name: Set up Ruby
        uses: ruby/setup-ruby@e65c17d16e57e481586a6a5a0282698790062f92 # v1.300.0
        with:
          ruby-version: "3.3"
          bundler-cache: true

      - name: Extract base version from tag
        id: version
        run: |
          # v1.2.0-rc.1 → 1.2.0
          BASE_VERSION=$(echo "${GITHUB_REF_NAME#v}" | sed 's/-rc\..*//')
          echo "base=$BASE_VERSION" >> "$GITHUB_OUTPUT"
          echo "tag=$GITHUB_REF_NAME" >> "$GITHUB_OUTPUT"

      - name: Update marketing version
        run: |
          sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"${{ steps.version.outputs.base }}\"/" project.yml

      - name: Verify Production schema matches committed baseline
        env:
          DEVELOPMENT_TEAM: ${{ secrets.DEVELOPMENT_TEAM }}
          CKTOOL_MANAGEMENT_TOKEN: ${{ secrets.CKTOOL_MANAGEMENT_TOKEN }}
        run: just verify-prod-matches-baseline

      - name: Promote CloudKit schema to Production
        env:
          DEVELOPMENT_TEAM: ${{ secrets.DEVELOPMENT_TEAM }}
          CKTOOL_MANAGEMENT_TOKEN: ${{ secrets.CKTOOL_MANAGEMENT_TOKEN }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: just promote-schema

      - name: Build & upload iOS to TestFlight
        env:
          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
          ASC_KEY_CONTENT: ${{ secrets.ASC_KEY_CONTENT }}
          MATCH_GIT_URL: ${{ secrets.MATCH_GIT_URL }}
          MATCH_PASSWORD: ${{ secrets.MATCH_PASSWORD }}
          MATCH_GIT_BASIC_AUTHORIZATION: ${{ secrets.MATCH_GIT_BASIC_AUTHORIZATION }}
          DEVELOPMENT_TEAM: ${{ secrets.DEVELOPMENT_TEAM }}
          CODE_SIGN_STYLE: "Manual"
        run: bundle exec fastlane ios beta

      - name: Capture TestFlight build number
        run: |
          # Fastlane writes the new build number into project.pbxproj.
          # Read it back so we can attach it to the GH release.
          BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' Moolah.xcodeproj/project.pbxproj \
              | head -1 \
              | sed 's/.*= \([0-9]*\);/\1/')
          if [[ -z "$BUILD" ]]; then
              echo "Could not read CURRENT_PROJECT_VERSION from pbxproj" >&2
              exit 1
          fi
          echo "$BUILD" > build/build-number.txt
          echo "Build number: $BUILD"

      - name: Build & notarise Mac DMG
        env:
          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
          ASC_KEY_CONTENT: ${{ secrets.ASC_KEY_CONTENT }}
          MATCH_GIT_URL: ${{ secrets.MATCH_GIT_URL }}
          MATCH_PASSWORD: ${{ secrets.MATCH_PASSWORD }}
          MATCH_GIT_BASIC_AUTHORIZATION: ${{ secrets.MATCH_GIT_BASIC_AUTHORIZATION }}
          DEVELOPMENT_TEAM: ${{ secrets.DEVELOPMENT_TEAM }}
          CODE_SIGN_STYLE: "Manual"
        run: bundle exec fastlane mac dmg version:${{ steps.version.outputs.base }}

      - name: Attach DMG and build-number to GH pre-release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh release upload "${{ steps.version.outputs.tag }}" \
              "build/Moolah-${{ steps.version.outputs.base }}.dmg" \
              build/build-number.txt \
              --clobber

      - name: Upload IPA workflow artefact
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4
        with:
          name: Moolah-${{ steps.version.outputs.tag }}.ipa
          path: build/Moolah.ipa
```

- [ ] **Step 2: Delete `testflight.yml`**

```bash
git -C .worktrees/release-process-design rm .github/workflows/testflight.yml
```

- [ ] **Step 3: Commit**

```bash
git -C .worktrees/release-process-design add .github/workflows/release-rc.yml
git -C .worktrees/release-process-design commit -m "workflows: add release-rc.yml, drop testflight.yml"
```

---

## Task 11: `release-final.yml` workflow

**Files:**
- Create: `.github/workflows/release-final.yml`

- [ ] **Step 1: Create `release-final.yml`**

```yaml
name: Release Final

on:
  push:
    tags:
      - "v[0-9]+.[0-9]+.[0-9]+"

permissions:
  contents: write
  pull-requests: write

jobs:
  guard-not-rc:
    name: Skip if tag is an RC
    runs-on: ubuntu-latest
    outputs:
      is_final: ${{ steps.check.outputs.is_final }}
    steps:
      - id: check
        run: |
          if [[ "${GITHUB_REF_NAME}" == *-rc.* ]]; then
            echo "Skipping: tag ${GITHUB_REF_NAME} is an RC"
            echo "is_final=false" >> "$GITHUB_OUTPUT"
          else
            echo "is_final=true" >> "$GITHUB_OUTPUT"
          fi

  promote:
    name: Promote RC to final
    needs: guard-not-rc
    if: needs.guard-not-rc.outputs.is_final == 'true'
    runs-on: macos-26
    timeout-minutes: 30
    environment: testflight

    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
        with:
          fetch-depth: 0

      - name: Install tools
        run: brew install just

      - name: Set up Ruby
        uses: ruby/setup-ruby@e65c17d16e57e481586a6a5a0282698790062f92 # v1.300.0
        with:
          ruby-version: "3.3"
          bundler-cache: true

      - name: Resolve RC tag pairing
        id: pair
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          MV="${GITHUB_REF_NAME#v}"     # 1.2.0
          FINAL_SHA=$(git rev-list -n 1 "$GITHUB_REF_NAME")

          # Latest RC tag for this marketing version.
          RC_TAG=$(git tag -l "v${MV}-rc.*" | sort -V | tail -1)
          if [[ -z "$RC_TAG" ]]; then
              echo "No RC tag found for $MV" >&2
              exit 1
          fi
          RC_SHA=$(git rev-list -n 1 "$RC_TAG")
          if [[ "$FINAL_SHA" != "$RC_SHA" ]]; then
              echo "Final tag $GITHUB_REF_NAME ($FINAL_SHA) does not point at the same commit as $RC_TAG ($RC_SHA)" >&2
              exit 1
          fi

          echo "rc_tag=$RC_TAG" >> "$GITHUB_OUTPUT"
          echo "marketing_version=$MV" >> "$GITHUB_OUTPUT"
          echo "final_sha=$FINAL_SHA" >> "$GITHUB_OUTPUT"

      - name: Read RC's TestFlight build number
        id: build
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh release download "${{ steps.pair.outputs.rc_tag }}" \
              -p "build-number.txt" -D build
          BUILD=$(cat build/build-number.txt)
          echo "Build number from RC: $BUILD"
          echo "build_number=$BUILD" >> "$GITHUB_OUTPUT"

      - name: Submit existing TestFlight build for App Store review
        env:
          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
          ASC_KEY_CONTENT: ${{ secrets.ASC_KEY_CONTENT }}
          DEVELOPMENT_TEAM: ${{ secrets.DEVELOPMENT_TEAM }}
        run: |
          bundle exec fastlane ios submit_review \
              version:${{ steps.pair.outputs.marketing_version }} \
              build_number:${{ steps.build.outputs.build_number }}

      - name: Copy DMG from RC release to final release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh release download "${{ steps.pair.outputs.rc_tag }}" \
              -p "*.dmg" -D build
          gh release upload "$GITHUB_REF_NAME" build/*.dmg --clobber

      - name: Open version-bump PR with automerge
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          MV="${{ steps.pair.outputs.marketing_version }}"
          # Default minor bump.
          IFS=. read -r MAJOR MINOR PATCH <<< "$MV"
          NEXT="${MAJOR}.$((MINOR + 1)).0"

          BRANCH="release/post-v${MV}-bump"
          git config user.name "moolah-release-bot"
          git config user.email "release-bot@users.noreply.github.com"
          git fetch origin main
          git checkout -B "$BRANCH" origin/main
          sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"${NEXT}\"/" project.yml
          git add project.yml
          git commit -m "build: bump marketing version to ${NEXT} (post-v${MV})"
          git push --force-with-lease origin "$BRANCH"

          PR_BODY=$(cat <<EOF
          Default minor bump after \`v${MV}\` shipped. The next RC will read marketing version \`${NEXT}\` from \`project.yml\`.

          If you want a different bump (major \`$((MAJOR + 1)).0.0\`, patch \`${MAJOR}.${MINOR}.$((PATCH + 1))\`, or an explicit version), edit \`project.yml\` in this PR before automerge fires.

          Auto-opened by \`release-final.yml\`.
          EOF
          )

          gh pr create \
              --base main \
              --head "$BRANCH" \
              --title "build: bump marketing version to ${NEXT}" \
              --body "$PR_BODY"
          gh pr merge "$BRANCH" --auto --squash
```

- [ ] **Step 2: Commit**

```bash
git -C .worktrees/release-process-design add .github/workflows/release-final.yml
git -C .worktrees/release-process-design commit -m "workflows: add release-final.yml"
```

---

## Task 12: Rewire `monthly-tag.yml`

**Files:**
- Modify: `.github/workflows/monthly-tag.yml`

The current monthly cron creates a `v1.0.0-monthly.YYYYMM` tag and triggers `testflight.yml`. The new monthly cron computes the next RC and creates a GH pre-release with auto-generated notes — which fires `release-rc.yml` exactly as a manual cut would.

- [ ] **Step 1: Replace the contents of `monthly-tag.yml`**

```yaml
name: Monthly RC

on:
  schedule:
    - cron: "0 9 1 * *"  # 9 AM UTC on the 1st of each month
  workflow_dispatch: {}

permissions:
  contents: write

jobs:
  cut-rc:
    name: Cut monthly RC
    runs-on: macos-26
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
        with:
          fetch-depth: 0

      - name: Install just
        run: brew install just

      - name: Compute next RC version
        id: version
        run: |
          JSON=$(just release-next-version rc)
          VERSION=$(echo "$JSON" | jq -r .version)
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"
          echo "tag=v$VERSION" >> "$GITHUB_OUTPUT"

      - name: Create GH pre-release with auto-generated notes
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh release create "${{ steps.version.outputs.tag }}" \
              --target main \
              --title "${{ steps.version.outputs.tag }}" \
              --prerelease \
              --generate-notes
          # release-rc.yml fires from the tag push that gh release just created.
```

- [ ] **Step 2: Commit**

```bash
git -C .worktrees/release-process-design add .github/workflows/monthly-tag.yml
git -C .worktrees/release-process-design commit -m "workflows: rewire monthly-tag to RC pipeline"
```

---

## Task 13: `cutting-a-release` skill

**Files:**
- Create: `.claude/skills/cutting-a-release/SKILL.md`

Minimal skill body. Points at the runbook and adds AI-specific notes only where they genuinely add something.

- [ ] **Step 1: Create the skill file**

```markdown
---
name: cutting-a-release
description: Use when cutting a release candidate, promoting an RC to a final release, or when the user asks to "ship a release" / "tag a release". Drafts user-facing release notes per BRAND_GUIDE.md and walks through the procedure in guides/RELEASE_GUIDE.md.
---

# Cutting a Release

The procedure is in [`guides/RELEASE_GUIDE.md`](../../../guides/RELEASE_GUIDE.md). Follow it step by step. Each step there names a `just` target — run that target via the Bash tool. Don't restate or paraphrase the procedure here; the runbook is the source of truth.

## What's special about doing this with AI assistance

The runbook is written so a human can execute it solo. The reasons a human might invoke this skill rather than running the runbook themselves are:

1. **Drafting release notes.** This is the step that benefits most from analysis: read merged PRs since `notes_base`, read the diffs that actually shipped, separate user-facing changes from internal ones, and write something that respects `guides/BRAND_GUIDE.md`.
2. **Surfacing surprises during the run.** If `release-preflight` fails, if `release-wait` reports a workflow failure, or if `release-status` shows missing assets, summarise the situation and propose a recovery path from the runbook's Recovery section.

Everything else is just running `just` targets in order.

## Release notes — operational notes

When the runbook says "Author release notes", do this:

1. Run `just release-next-version <kind>` and read `notes_base` from the JSON.
2. Gather the changeset:
   - `gh pr list --state merged --base main --search "merged:>=$(git -C . log -1 --format=%aI <notes_base>)"` for merged PRs in the window.
   - `git -C . log <notes_base>..HEAD --oneline` for the full commit list.
   - For any PR that looks substantive, read its body via `gh pr view <number> --json title,body,labels`.
3. Read `guides/BRAND_GUIDE.md` once per session before drafting (don't rely on memory of the voice rules).
4. Write the draft to `.agent-tmp/release-notes-<version>.md`. Show it to the user. Iterate on their feedback. Only call `just release-create-rc` / `just release-create-final` after they approve the notes.

The runbook's "Authoring release notes" section governs scope, filtering, and voice for both AI and human authors — re-read it before drafting; don't paraphrase the rules from memory.

## When something goes wrong

Point at the relevant heading under "Recovery" in the runbook. Don't invent recovery procedures the runbook doesn't sanction. If something genuinely doesn't fit any recovery case, surface that to the user and ask before acting — the runbook is conservative on purpose (e.g. it says never delete a tag).

## Hand-off

- After an RC: tell the user how to install the TestFlight build and the DMG, and what to look for in smoke-testing.
- After a final: tell the user the App Store submission has been made (auto-release after approval) and that the bump PR is in flight; remind them to edit `project.yml` in the PR if they want a non-default bump.
```

- [ ] **Step 2: Verify the skill body has no procedural duplication**

Re-read the file. The runbook describes the procedure; the skill body must not restate it. The skill mentions specific `just` targets only by name (no explanation of what they do). The skill cites the runbook's sections rather than rewriting them.

- [ ] **Step 3: Commit**

```bash
git -C .worktrees/release-process-design add .claude/skills/cutting-a-release/SKILL.md
git -C .worktrees/release-process-design commit -m "skills: add cutting-a-release"
```

---

## Task 14: End-to-end verification dry run

**Files:**
- None (verification only).

The dry-run cannot exercise the GH-Actions side without firing real CI, an actual TestFlight upload, and an actual schema promotion. So this task is split into "things we can verify locally" and "things the operator must do via a real test cycle once the PR lands."

- [ ] **Step 1: Local verifications**

Run from the worktree:

```bash
just test-release-scripts
just release-next-version rc | jq .
just release-next-version final 2>&1 | head -3   # should error: no RC tag yet
just release-status v0.0.0                       # should report not found, no error
```

Expected:
- `test-release-scripts` passes.
- `release-next-version rc` outputs valid JSON with the current MARKETING_VERSION.
- `release-next-version final` errors with "no RC tag exists for marketing version …".
- `release-status v0.0.0` reports the release is not found and no run exists.

- [ ] **Step 2: Lint workflow YAML**

```bash
brew install actionlint 2>/dev/null || true
actionlint .github/workflows/release-rc.yml .github/workflows/release-final.yml \
    .github/workflows/monthly-tag.yml
```

Expected: no errors. If `actionlint` flags issues, fix the workflow inline.

- [ ] **Step 3: Lint shell scripts**

```bash
brew install shellcheck 2>/dev/null || true
shellcheck scripts/release-*.sh scripts/lib/release-common.sh \
    scripts/tests/test-release-common.sh
```

Expected: no errors. Fix any flagged issues.

- [ ] **Step 4: Update PR body with live verification checklist**

Once the PR is merged to `main`, the operator must run a real test cycle. Add a section to the PR body capturing this hand-off so it doesn't get lost:

```bash
gh pr edit 486 --body "$(cat <<'EOF'
## Summary

Implements the release process designed in `plans/2026-04-26-release-process-design.md`. Three layers: `justfile` atoms, `guides/RELEASE_GUIDE.md` runbook, `.claude/skills/cutting-a-release` AI wrapper. New workflows for RC + final; existing `testflight.yml` removed.

## Test plan

- [x] `just test-release-scripts` passes.
- [x] `just release-next-version rc` / `final` return correct JSON.
- [x] `actionlint` clean on new workflows.
- [x] `shellcheck` clean on new scripts.
- [ ] Operator: completes Task 0 (Match Developer ID, automerge enabled).
- [ ] Operator: cuts a real `v0.X.Y-rc.1` after merge to verify `release-rc.yml` end-to-end (TestFlight upload + Mac DMG + GH pre-release).
- [ ] Operator: promotes that RC to `v0.X.Y` to verify `release-final.yml` end-to-end (App Store submission, DMG copy, bump PR).
EOF
)"
```

- [ ] **Step 5: Commit any lint fixes from steps 2-3**

If `actionlint` or `shellcheck` flagged anything:

```bash
git -C .worktrees/release-process-design add <fixed files>
git -C .worktrees/release-process-design commit -m "scripts: fix shellcheck / actionlint issues"
```

If nothing was flagged, skip this step.

- [ ] **Step 6: Push**

```bash
git -C .worktrees/release-process-design push origin release-process-design
```

---

## Self-review

After writing the plan, the following coverage / consistency checks were performed:

**Spec coverage:**
- ✅ Tag conventions → Task 7 (runbook), Task 1 (regex in scripts)
- ✅ Same-bytes-ship invariant → Task 11 (release-final.yml: no rebuild, DMG copy, build-number lookup)
- ✅ Schema promotion at RC time → Task 10 (release-rc.yml steps), no schema in Task 11
- ✅ Three-layer factoring → Tasks 1-6 (atoms), Task 7 (runbook), Task 13 (skill)
- ✅ AI-authored release notes per BRAND_GUIDE → Task 7 ("Authoring release notes" section), Task 13 (skill notes)
- ✅ Workflow-owned bump PR with automerge → Task 11 ("Open version-bump PR with automerge" step)
- ✅ Monthly cron → Task 12
- ✅ No tag deletion ever → Task 7 ("Recovery" section, "Erroneous tag pushed")
- ✅ Manual prerequisites → Task 0
- ✅ Recovery procedures → Task 7
- ✅ DMG bytes-identical between RC and final → Task 11 ("Copy DMG from RC release to final release")

**Type / name consistency:**
- `compute_next_rc_version` / `compute_final_version` referenced consistently across Task 1 (definition + tests), Task 3 (caller).
- `notes_base` field used consistently in Task 1, 3, 7, 13.
- `release-create-rc` / `release-create-final` / `release-wait` / `release-status` are all referenced by their final names in justfile, runbook, skill, and verification.

**Placeholder scan:** no `TBD`, `TODO`, "implement later", or "similar to Task N" patterns. Every code/script/YAML block contains the actual content.

**Open question disposition:**
- Bump-PR / merge-queue interaction: handled in Task 11 with `gh pr merge --auto --squash`. If the operator's merge-queue daemon ends up wanting to manage this PR explicitly, that's a follow-up; the design noted this as deferred.
- DMG creation tooling: `create-dmg` chosen and pinned in Task 8 (Fastfile) and installed in Task 10 (release-rc.yml).
- Match `developer_id` profile setup: documented in Task 0 + Task 8.

---

## Plan complete

This plan is suitable for execution via `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans`. Tasks 1-13 are independently implementable; Task 14 is a verification gate at the end.
