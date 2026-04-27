# Issue #495 — Separate Test/Dev iCloud Container from the Release-Pipeline Container — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split CloudKit container usage so that `iCloud.rocks.moolah.app.v2` is touched only by production users (Prod env) and the release pipeline's schema-staging step (Dev env), and a new `iCloud.rocks.moolah.app.test` absorbs every other use (local dev runs, manual `cktool` experimentation, CI). Production data on `…app.v2` must be preserved untouched.

**Architecture:**
- The only locally-signed CloudKit-enabled build is **Debug**. The `just install-mac` target — which previously produced a locally-signed Release binary — is removed; developers who want to run a Release-signed copy of the app install it from the GitHub release artefact (`Moolah-x.y.z.zip`) instead. With `install-mac` gone, `inject-entitlements.sh` only ever needs to handle Debug.
- Container ID becomes per-build-configuration in `project.yml`: `Debug` and `Debug-Tests` resolve to `iCloud.rocks.moolah.app.test`; `Release` resolves to `iCloud.rocks.moolah.app.v2` (the value used by fastlane-signed shipped builds — the only Release path that exists post this change). The `MoolahCloudKitContainer` Info.plist key (already wired) propagates the choice to runtime via `CloudKitContainer.swift`.
- `scripts/inject-entitlements.sh` is invoked only when a developer runs `ENABLE_ENTITLEMENTS=1 just generate` (Debug-with-CloudKit). It writes `.build/Moolah.entitlements` listing only `iCloud.rocks.moolah.app.test` and injects `CODE_SIGN_ENTITLEMENTS` only into each target's Debug block. fastlane lanes run `just generate` without `ENABLE_ENTITLEMENTS=1`, bypass `inject-entitlements.sh` entirely, and produce a Release binary signed with `fastlane/Moolah(-mac).entitlements` (which keeps listing only `app.v2`); that is the only path that can ever sign a binary for the release container.
- `scripts/cloudkit-config.sh` exposes two named constants — `CLOUDKIT_CONTAINER_ID_RELEASE` and `CLOUDKIT_CONTAINER_ID_TEST` — and requires every script that calls `cloudkit_cktool` to set `CLOUDKIT_CONTAINER_ID` to one of them. Release-pipeline-only scripts (`verify-prod-deployed.sh`, `verify-prod-matches-baseline.sh`, `refresh-prod-baseline.sh`, `import-schema-to-dev.sh`) pin the **release** constant. Local-only convenience scripts (`export-schema.sh`, `verify-schema.sh`, `dryrun-promote-schema.sh`) pin the **test** constant. A new `scripts/import-schema-to-test.sh` is added to bootstrap the new container's Development schema.
- Production users on shipped builds keep targeting `…app.v2` (their data is unchanged because nothing about `…app.v2` Production is being modified). Local developers transitioning from the old single-container Debug flow will see their old `…app.v2` Dev data become invisible to Debug builds — that is intentional and is documented as a one-time housekeeping note.

**Tech Stack:** XcodeGen (`project.yml` → `Moolah.xcodeproj` via `just generate`), bash scripts under `scripts/`, GitHub Actions workflows under `.github/workflows/`, fastlane lanes under `fastlane/`, Swift 6, `xcrun cktool`. Build via `just build-mac` / `just build-ios`. Tests via `just test`. Pre-commit: `just format` then `just format-check`.

**Issue:** https://github.com/ajsutton/moolah-native/issues/495

**Ordering rationale:** The earliest tasks (1–3) refactor `cloudkit-config.sh` and split scripts by audience without changing which container any of them targets at runtime — `cloudkit_cktool` keeps hitting `…app.v2` from every release-pipeline script. The Apple Developer Portal manual prereq (Task 4) and the bootstrap-the-test-container manual prereq (Task 5) introduce the new container without touching anything that production depends on. Task 6 removes `install-mac` and simplifies `inject-entitlements.sh` to a Debug-only injector listing only `app.test`. Task 7 then makes `project.yml`'s `CLOUDKIT_CONTAINER_ID` per-configuration (Debug/Debug-Tests → `app.test`, Release → `app.v2`). Task 8 documents the split. Each commit between Task 1 and Task 8 leaves the repo in a working state.

**Out of scope (per the issue):**
- Migration of user data on `…app.v2` Production (none required).
- Changes to the release pipeline's overall shape (tracked separately).
- Adding the new container to `NSUbiquitousContainers` in `App/Info-iOS.plist` / `App/Info-macOS.plist` — that key is for iCloud Drive document scoping, which Moolah does not use; the existing entry is cosmetic and unrelated to CloudKit container selection.

---

## Task 1: Add named container constants to `cloudkit-config.sh`

**Files:**
- Modify: `scripts/cloudkit-config.sh`

**Goal of this task:** Introduce both container IDs as separate, named constants and require every caller of `cloudkit_cktool` to opt into one explicitly. After this task, `cloudkit_cktool` still talks to `…app.v2` because every existing script will be updated in Task 2 to pin the release constant — behaviour is unchanged.

- [ ] **Step 1: Replace `scripts/cloudkit-config.sh` with the dual-constant version**

  Overwrite the file with:

  ```bash
  #!/usr/bin/env bash
  # Shared config and helpers for CloudKit schema scripts. Sourced, not executed.
  #
  # Two CloudKit containers are in play (issue #495):
  #
  # - CLOUDKIT_CONTAINER_ID_RELEASE: production users + the release pipeline's
  #   schema-staging step. Anything that targets this container can affect what
  #   gets promoted to live Production. Touched by:
  #     verify-prod-deployed.sh, verify-prod-matches-baseline.sh,
  #     refresh-prod-baseline.sh, import-schema-to-dev.sh.
  #
  # - CLOUDKIT_CONTAINER_ID_TEST: local dev runs, manual cktool experimentation,
  #   anything not part of the release flow. Touched by:
  #     export-schema.sh, verify-schema.sh, dryrun-promote-schema.sh,
  #     import-schema-to-test.sh.
  #
  # Every caller of cloudkit_cktool MUST set CLOUDKIT_CONTAINER_ID to one of the
  # two constants above before invoking cloudkit_cktool — there is no default,
  # to make the choice explicit at every call site.
  
  set -euo pipefail
  
  # Must stay in sync with the Release-config CLOUDKIT_CONTAINER_ID in project.yml
  # and with com.apple.developer.icloud-container-identifiers in
  # fastlane/Moolah.entitlements / fastlane/Moolah-mac.entitlements.
  CLOUDKIT_CONTAINER_ID_RELEASE="iCloud.rocks.moolah.app.v2"
  
  # Must stay in sync with the Debug- and Debug-Tests-config CLOUDKIT_CONTAINER_ID
  # in project.yml and with com.apple.developer.icloud-container-identifiers in
  # the entitlements file written by scripts/inject-entitlements.sh.
  CLOUDKIT_CONTAINER_ID_TEST="iCloud.rocks.moolah.app.test"
  
  # Committed schema snapshot. Diffed on every PR, promoted to production on
  # every release tag.
  CLOUDKIT_SCHEMA_FILE="CloudKit/schema.ckdb"
  
  cloudkit_fail() {
      echo "error: $*" >&2
      exit 1
  }
  
  cloudkit_require_env() {
      [ -n "${DEVELOPMENT_TEAM:-}" ] \
          || cloudkit_fail "DEVELOPMENT_TEAM is not set. Put it in .env or export it."
  }
  
  cloudkit_require_container_id() {
      [ -n "${CLOUDKIT_CONTAINER_ID:-}" ] \
          || cloudkit_fail "CLOUDKIT_CONTAINER_ID is not set. The caller must pin it to either CLOUDKIT_CONTAINER_ID_RELEASE or CLOUDKIT_CONTAINER_ID_TEST before calling cloudkit_cktool."
      case "$CLOUDKIT_CONTAINER_ID" in
          "$CLOUDKIT_CONTAINER_ID_RELEASE"|"$CLOUDKIT_CONTAINER_ID_TEST") ;;
          *)
              cloudkit_fail "CLOUDKIT_CONTAINER_ID=$CLOUDKIT_CONTAINER_ID is not one of the known constants ($CLOUDKIT_CONTAINER_ID_RELEASE, $CLOUDKIT_CONTAINER_ID_TEST)."
              ;;
      esac
  }
  
  # Usage: cloudkit_cktool <subcommand> [extra args...]
  # Fills in --team-id and --container-id (from CLOUDKIT_CONTAINER_ID, which the
  # caller must set). Passes --token when CKTOOL_MANAGEMENT_TOKEN is set (CI
  # path); otherwise cktool falls back to the keychain entry written by
  # `xcrun cktool save-token` (local-dev path).
  cloudkit_cktool() {
      cloudkit_require_container_id
      local sub="$1"
      shift
      local args=(
          "$sub"
          --team-id "$DEVELOPMENT_TEAM"
          --container-id "$CLOUDKIT_CONTAINER_ID"
      )
      if [ -n "${CKTOOL_MANAGEMENT_TOKEN:-}" ]; then
          args+=(--token "$CKTOOL_MANAGEMENT_TOKEN")
      fi
      args+=("$@")
      xcrun cktool "${args[@]}"
  }
  ```

- [ ] **Step 2: Sanity-check the script parses cleanly**

  Run: `bash -n scripts/cloudkit-config.sh`
  Expected: no output, exit 0.

  Run: `bash -c 'set -euo pipefail; source scripts/cloudkit-config.sh; echo "release=$CLOUDKIT_CONTAINER_ID_RELEASE test=$CLOUDKIT_CONTAINER_ID_TEST"'`
  Expected: `release=iCloud.rocks.moolah.app.v2 test=iCloud.rocks.moolah.app.test`

- [ ] **Step 3: Commit**

  ```bash
  git -C "$(pwd)" add scripts/cloudkit-config.sh
  git -C "$(pwd)" commit -m "refactor(cloudkit): expose release and test container constants in cloudkit-config

  Defines CLOUDKIT_CONTAINER_ID_RELEASE and CLOUDKIT_CONTAINER_ID_TEST and
  requires every caller of cloudkit_cktool to opt in via CLOUDKIT_CONTAINER_ID.
  No behaviour change yet; existing scripts are pinned to the release constant
  in the next commit. Refs #495."
  ```

  Expected: pre-commit hooks succeed; one new commit on the branch.

---

## Task 2: Pin existing schema scripts to the appropriate container

**Files:**
- Modify: `scripts/verify-prod-deployed.sh`
- Modify: `scripts/verify-prod-matches-baseline.sh`
- Modify: `scripts/refresh-prod-baseline.sh`
- Modify: `scripts/import-schema-to-dev.sh`
- Modify: `scripts/export-schema.sh`
- Modify: `scripts/verify-schema.sh`
- Modify: `scripts/dryrun-promote-schema.sh`

**Goal of this task:** Make every existing script declare which container it targets. The four release-pipeline scripts pin `CLOUDKIT_CONTAINER_ID_RELEASE`; the three local convenience scripts pin `CLOUDKIT_CONTAINER_ID_TEST`. After this task, the local convenience scripts will start failing (because the test container does not exist yet) — that is intentional and is fixed by Tasks 4–5, which create and bootstrap the new container.

- [ ] **Step 1: Pin `scripts/verify-prod-deployed.sh` to the release constant**

  Replace the block from `cloudkit_require_env` through to the next blank line with:

  ```bash
  cloudkit_require_env

  CLOUDKIT_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID_RELEASE"
  ```

  i.e. the existing call to `cloudkit_require_env` stays, and a new line below it pins `CLOUDKIT_CONTAINER_ID` to the release constant. The rest of the script (which uses `cloudkit_cktool`) is unchanged. Also update the user-facing message that names the container — replace any hard-coded `iCloud.rocks.moolah.app.v2` strings in the script's output text with `$CLOUDKIT_CONTAINER_ID` so the message stays in sync if the constant is ever renamed.

  Concretely, the file's body after the change reads (full content):

  ```bash
  #!/usr/bin/env bash
  #
  # Verifies that the live Production schema matches CloudKit/schema.ckdb (the
  # committed source of truth). Used by release-rc.yml as the gate that proves
  # a Console-deploy has been performed.
  #
  # Apple's API does not expose a way to write schema to Production via cktool
  # — the only path is the CloudKit Console's "Deploy Schema Changes to
  # Production" button. This script is the verification half of that handoff:
  # after a developer clicks Deploy in the Console, this script confirms the
  # bytes landed.
  #
  # Comparison is *semantic*, not byte-equal: cktool's `export-schema` returns
  # record types in chronological-creation order and uses different
  # column-alignment whitespace than human-edited `.ckdb` files. We delegate
  # to `tools/CKDBSchemaGen check-equal`, which parses both files and compares
  # their parsed AST (record types, fields, types, indexes, deprecation flags)
  # regardless of source-file order or whitespace.
  #
  # Targets the release container (CLOUDKIT_CONTAINER_ID_RELEASE) — see issue
  # #495.
  #
  # Exits 0 if Production is semantically equal to schema.ckdb; non-zero with
  # a descriptive list of differences (printed by the Swift tool) if not.
  set -euo pipefail
  HERE="$(cd "$(dirname "$0")" && pwd)"
  # shellcheck source=scripts/cloudkit-config.sh
  source "$HERE/cloudkit-config.sh"

  cloudkit_require_env
  CLOUDKIT_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID_RELEASE"

  [ -f "$CLOUDKIT_SCHEMA_FILE" ] \
      || cloudkit_fail "$CLOUDKIT_SCHEMA_FILE is missing."

  live=$(mktemp)
  trap 'rm -f "$live"' EXIT

  cloudkit_cktool export-schema \
      --environment production \
      --output-file "$live" >/dev/null

  if swift run --quiet --package-path tools/CKDBSchemaGen ckdb-schema-gen check-equal \
      --a "$live" \
      --b "$CLOUDKIT_SCHEMA_FILE" >&2
  then
      echo "✓ live Production schema matches $CLOUDKIT_SCHEMA_FILE"
      exit 0
  fi

  cat >&2 <<EOF

  ✗ live Production schema does not match $CLOUDKIT_SCHEMA_FILE.

  The proposed schema has not been deployed to Production. Apple's API does
  not expose a CLI path for production schema deploys — the only way to
  deploy is the CloudKit Console:

    1. Open https://icloud.developer.apple.com/dashboard/ for container
       $CLOUDKIT_CONTAINER_ID.
    2. Schema → Deploy Schema Changes to Production.
    3. Review the diff (Dev should already match schema.ckdb if this script
       ran via the release pipeline; if not, run 'just import-schema-to-dev'
       first).
    4. Confirm Deploy.
  EOF
  exit 1
  ```

- [ ] **Step 2: Pin `scripts/verify-prod-matches-baseline.sh` to the release constant**

  Final content:

  ```bash
  #!/usr/bin/env bash
  #
  # Release-tag CI gate: exports the live CloudKit Production schema and
  # compares it byte-for-byte against the committed
  # CloudKit/schema-prod-baseline.ckdb. Halts the release on mismatch
  # (manual dashboard edit, partial prior promote, etc.) so a human can
  # investigate before promote-schema runs.
  #
  # Targets the release container (CLOUDKIT_CONTAINER_ID_RELEASE) — see issue
  # #495.
  set -euo pipefail
  HERE="$(cd "$(dirname "$0")" && pwd)"
  # shellcheck source=scripts/cloudkit-config.sh
  source "$HERE/cloudkit-config.sh"

  cloudkit_require_env
  CLOUDKIT_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID_RELEASE"

  baseline="CloudKit/schema-prod-baseline.ckdb"
  [ -f "$baseline" ] || cloudkit_fail "$baseline is missing."

  tmp="$(mktemp -t cloudkit-prod-schema)"
  trap 'rm -f "$tmp"' EXIT

  cloudkit_cktool export-schema \
      --environment production \
      --output-file "$tmp"

  if diff -u "$baseline" "$tmp"; then
      echo "Production schema matches $baseline."
      exit 0
  fi

  cat >&2 <<EOF

  error: live Production schema does not match $baseline.

  The release pipeline halts here. Investigate the divergence (manual
  dashboard edit, partial prior promote, etc.) and update the baseline
  via a follow-up PR before retrying the release.
  EOF
  exit 1
  ```

- [ ] **Step 3: Pin `scripts/refresh-prod-baseline.sh` to the release constant**

  Final content:

  ```bash
  #!/usr/bin/env bash
  #
  # Exports the live CloudKit Production schema into
  # CloudKit/schema-prod-baseline.ckdb. If the file changed, opens a follow-up
  # PR. Run by release-rc.yml after a successful release so that
  # `just check-schema-additive` on subsequent PRs runs against an
  # up-to-date baseline.
  #
  # Targets the release container (CLOUDKIT_CONTAINER_ID_RELEASE) — see issue
  # #495.
  set -euo pipefail
  HERE="$(cd "$(dirname "$0")" && pwd)"
  # shellcheck source=scripts/cloudkit-config.sh
  source "$HERE/cloudkit-config.sh"

  cloudkit_require_env
  CLOUDKIT_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID_RELEASE"

  baseline="CloudKit/schema-prod-baseline.ckdb"

  cloudkit_cktool export-schema \
      --environment production \
      --output-file "$baseline"
  echo "Exported live Production schema to $baseline."

  if git -C "$(pwd)" diff --quiet -- "$baseline"; then
      echo "$baseline unchanged; nothing to commit."
      exit 0
  fi

  git -C "$(pwd)" config user.name "github-actions[bot]"
  git -C "$(pwd)" config user.email "41898282+github-actions[bot]@users.noreply.github.com"

  branch="cloudkit-baseline-refresh-$(date -u +%Y%m%d-%H%M%S)"
  git -C "$(pwd)" checkout -b "$branch"
  git -C "$(pwd)" add "$baseline"
  git -C "$(pwd)" commit -m "chore(cloudkit): refresh schema-prod-baseline after deploy"
  git -C "$(pwd)" push -u origin "$branch"

  gh pr create \
      --title "chore(cloudkit): refresh schema-prod-baseline after deploy" \
      --body "$(cat <<EOF
  Auto-generated after a successful CloudKit Production schema deploy.
  Refreshes \`CloudKit/schema-prod-baseline.ckdb\` to match the new live
  Production schema. Subsequent PRs run \`just check-schema-additive\`
  against this updated baseline.
  EOF
  )"
  ```

- [ ] **Step 4: Pin `scripts/import-schema-to-dev.sh` to the release constant and update the warning**

  This script is now safe by construction: with the release-pipeline container split off from local dev, the comment about "DESTRUCTIVE side-effect on the team's Development CloudKit container — any pending dev experiments will be wiped" no longer applies, because no developer or CI job other than the release pipeline writes to this container's Dev environment. Update the comment block to describe the new contract.

  Final content:

  ```bash
  #!/usr/bin/env bash
  #
  # Imports CloudKit/schema.ckdb to the Development environment of the
  # release container (CLOUDKIT_CONTAINER_ID_RELEASE = iCloud.rocks.moolah.app.v2)
  # as a staging step before a manual CloudKit Console "Deploy Schema Changes
  # to Production" click.
  #
  # Resetting Dev first ensures the Console's diff view shows exactly what
  # would be promoted, with no developer-side pollution. Per issue #495 the
  # release container's Dev environment is touched only by this script and
  # by the release pipeline — local dev runs and manual cktool experimentation
  # use the separate test container (CLOUDKIT_CONTAINER_ID_TEST).
  set -euo pipefail
  HERE="$(cd "$(dirname "$0")" && pwd)"
  # shellcheck source=scripts/cloudkit-config.sh
  source "$HERE/cloudkit-config.sh"

  cloudkit_require_env
  CLOUDKIT_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID_RELEASE"

  [ -f "$CLOUDKIT_SCHEMA_FILE" ] \
      || cloudkit_fail "$CLOUDKIT_SCHEMA_FILE is missing."

  echo "Resetting Development schema to match Production…"
  # cktool reset-schema only operates on the development environment by
  # definition (per `cktool reset-schema --help`); passing --environment is
  # rejected as an unknown option.
  cloudkit_cktool reset-schema

  echo "Validating $CLOUDKIT_SCHEMA_FILE against Development (dry-run)…"
  cloudkit_cktool import-schema \
      --environment development \
      --validate \
      --file "$CLOUDKIT_SCHEMA_FILE"

  echo "Importing $CLOUDKIT_SCHEMA_FILE to Development…"
  cloudkit_cktool import-schema \
      --environment development \
      --file "$CLOUDKIT_SCHEMA_FILE"

  cat <<EOF

  ✓ Development now mirrors $CLOUDKIT_SCHEMA_FILE on container
    $CLOUDKIT_CONTAINER_ID.

  Open https://icloud.developer.apple.com/dashboard/ for container
  $CLOUDKIT_CONTAINER_ID and click Schema → Deploy Schema Changes to
  Production. Review the diff, confirm Deploy.
  EOF
  ```

- [ ] **Step 5: Pin `scripts/export-schema.sh` to the test constant**

  Final content:

  ```bash
  #!/usr/bin/env bash
  #
  # Exports the developer's personal CloudKit Development schema (from the
  # test container, CLOUDKIT_CONTAINER_ID_TEST) into CloudKit/schema.ckdb.
  # This is how a developer captures schema changes they made in cktool / the
  # Console for committing back into the repo. Per issue #495 the test
  # container is the one local developers experiment against.
  set -euo pipefail
  HERE="$(cd "$(dirname "$0")" && pwd)"
  # shellcheck source=scripts/cloudkit-config.sh
  source "$HERE/cloudkit-config.sh"

  cloudkit_require_env
  CLOUDKIT_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID_TEST"

  mkdir -p "$(dirname "$CLOUDKIT_SCHEMA_FILE")"
  cloudkit_cktool export-schema \
      --environment development \
      --output-file "$CLOUDKIT_SCHEMA_FILE"
  echo "Wrote $CLOUDKIT_SCHEMA_FILE (from $CLOUDKIT_CONTAINER_ID Development)."
  ```

- [ ] **Step 6: Pin `scripts/verify-schema.sh` to the test constant**

  Final content:

  ```bash
  #!/usr/bin/env bash
  #
  # Manual local convenience: imports CloudKit/schema.ckdb to the developer's
  # test container Development environment (CLOUDKIT_CONTAINER_ID_TEST) with
  # --validate. Not run in CI.
  #
  # Use this when you want belt-and-braces verification before opening a PR
  # that touches the schema. It will surface any cktool import-side issues
  # (syntax, conflicts with what your test container's Dev currently has)
  # that the static additivity check cannot catch.
  set -euo pipefail
  HERE="$(cd "$(dirname "$0")" && pwd)"
  # shellcheck source=scripts/cloudkit-config.sh
  source "$HERE/cloudkit-config.sh"

  cloudkit_require_env
  CLOUDKIT_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID_TEST"

  [ -f "$CLOUDKIT_SCHEMA_FILE" ] \
      || cloudkit_fail "$CLOUDKIT_SCHEMA_FILE is missing."

  cloudkit_cktool import-schema \
      --environment development \
      --validate \
      --file "$CLOUDKIT_SCHEMA_FILE"

  echo "$CLOUDKIT_SCHEMA_FILE imported into the $CLOUDKIT_CONTAINER_ID Development environment."
  ```

- [ ] **Step 7: Pin `scripts/dryrun-promote-schema.sh` to the test constant**

  Final content:

  ```bash
  #!/usr/bin/env bash
  #
  # Manual local convenience: Apple's recommended Production-equivalent dry-run.
  # Resets the developer's test container (CLOUDKIT_CONTAINER_ID_TEST)
  # Development environment to match its Production, then imports the proposed
  # schema with --validate. If this fails, the same import would fail on the
  # release container's Production.
  #
  # DESTRUCTIVE: cktool reset-schema wipes any data in the test container's
  # Development environment. Set CKTOOL_ALLOW_DEV_RESET=1 to confirm.
  #
  # Not run in CI.
  set -euo pipefail
  HERE="$(cd "$(dirname "$0")" && pwd)"
  # shellcheck source=scripts/cloudkit-config.sh
  source "$HERE/cloudkit-config.sh"

  cloudkit_require_env
  CLOUDKIT_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID_TEST"

  [ -f "$CLOUDKIT_SCHEMA_FILE" ] \
      || cloudkit_fail "$CLOUDKIT_SCHEMA_FILE is missing."

  if [ "${CKTOOL_ALLOW_DEV_RESET:-}" != "1" ]; then
      cat >&2 <<EOF
  error: dryrun-promote-schema resets the $CLOUDKIT_CONTAINER_ID Development
         environment, which wipes any data and schema changes you've made
         there.

         Set CKTOOL_ALLOW_DEV_RESET=1 to confirm.
  EOF
      exit 1
  fi

  cloudkit_cktool reset-schema
  cloudkit_cktool import-schema \
      --environment development \
      --validate \
      --file "$CLOUDKIT_SCHEMA_FILE"

  echo "Dry-run promotion succeeded — $CLOUDKIT_SCHEMA_FILE is promotable to Production."
  ```

- [ ] **Step 8: Verify the four release-pipeline scripts still parse and source cleanly**

  Run: `for f in scripts/verify-prod-deployed.sh scripts/verify-prod-matches-baseline.sh scripts/refresh-prod-baseline.sh scripts/import-schema-to-dev.sh scripts/export-schema.sh scripts/verify-schema.sh scripts/dryrun-promote-schema.sh; do bash -n "$f" || { echo "syntax error in $f"; exit 1; }; done`
  Expected: no output, exit 0.

- [ ] **Step 9: Commit**

  ```bash
  git -C "$(pwd)" add scripts/verify-prod-deployed.sh scripts/verify-prod-matches-baseline.sh scripts/refresh-prod-baseline.sh scripts/import-schema-to-dev.sh scripts/export-schema.sh scripts/verify-schema.sh scripts/dryrun-promote-schema.sh
  git -C "$(pwd)" commit -m "refactor(cloudkit): pin schema scripts to release or test container

  Each script now explicitly pins CLOUDKIT_CONTAINER_ID to either the release
  or the test constant, making the audience of each script obvious at the top
  of the file. release-pipeline scripts (verify-prod-*, refresh-prod-baseline,
  import-schema-to-dev) target CLOUDKIT_CONTAINER_ID_RELEASE; local-only
  convenience scripts (export-schema, verify-schema, dryrun-promote-schema)
  target CLOUDKIT_CONTAINER_ID_TEST. The local scripts are expected to fail
  until the test container is created in App Store Connect (next task in
  the plan). Refs #495."
  ```

---

## Task 3: Add `import-schema-to-test.sh` and a `just` target for it

**Files:**
- Create: `scripts/import-schema-to-test.sh`
- Modify: `justfile`

**Goal of this task:** Provide a one-shot bootstrapping script to populate the new test container's Development schema from the committed `schema.ckdb`. Used in Task 5 (manual prereq) and any time a developer wants to wipe their test container back to a known good state.

- [ ] **Step 1: Create `scripts/import-schema-to-test.sh`**

  ```bash
  #!/usr/bin/env bash
  #
  # Imports CloudKit/schema.ckdb to the Development environment of the test
  # container (CLOUDKIT_CONTAINER_ID_TEST = iCloud.rocks.moolah.app.test).
  #
  # Run this once after creating the test container in App Store Connect to
  # bootstrap its Development schema. Re-run any time you want to wipe the
  # test container's Dev environment back to the committed schema.
  #
  # DESTRUCTIVE: cktool reset-schema wipes any schema and data in the test
  # container's Development environment. Set CKTOOL_ALLOW_DEV_RESET=1 to
  # confirm — same gate as dryrun-promote-schema.sh.
  set -euo pipefail
  HERE="$(cd "$(dirname "$0")" && pwd)"
  # shellcheck source=scripts/cloudkit-config.sh
  source "$HERE/cloudkit-config.sh"

  cloudkit_require_env
  CLOUDKIT_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID_TEST"

  [ -f "$CLOUDKIT_SCHEMA_FILE" ] \
      || cloudkit_fail "$CLOUDKIT_SCHEMA_FILE is missing."

  if [ "${CKTOOL_ALLOW_DEV_RESET:-}" != "1" ]; then
      cat >&2 <<EOF
  error: import-schema-to-test resets the $CLOUDKIT_CONTAINER_ID Development
         environment, which wipes any data and schema changes you've made
         there.

         Set CKTOOL_ALLOW_DEV_RESET=1 to confirm.
  EOF
      exit 1
  fi

  echo "Resetting Development schema on $CLOUDKIT_CONTAINER_ID…"
  cloudkit_cktool reset-schema

  echo "Validating $CLOUDKIT_SCHEMA_FILE against $CLOUDKIT_CONTAINER_ID Development (dry-run)…"
  cloudkit_cktool import-schema \
      --environment development \
      --validate \
      --file "$CLOUDKIT_SCHEMA_FILE"

  echo "Importing $CLOUDKIT_SCHEMA_FILE to $CLOUDKIT_CONTAINER_ID Development…"
  cloudkit_cktool import-schema \
      --environment development \
      --file "$CLOUDKIT_SCHEMA_FILE"

  echo "✓ $CLOUDKIT_CONTAINER_ID Development now mirrors $CLOUDKIT_SCHEMA_FILE."
  ```

  Make it executable: `chmod +x scripts/import-schema-to-test.sh`

- [ ] **Step 2: Verify syntax**

  Run: `bash -n scripts/import-schema-to-test.sh`
  Expected: no output, exit 0.

- [ ] **Step 3: Add a `just` target for it**

  In `justfile`, alongside the other CloudKit schema targets (after `import-schema-to-dev`, around line 258), add:

  ```make
  # Manual local convenience: bootstraps the test container's Development
  # schema from CloudKit/schema.ckdb. Run once after creating the test
  # container in App Store Connect, or to wipe the test container back to a
  # known-good state. DESTRUCTIVE — set CKTOOL_ALLOW_DEV_RESET=1 to confirm.
  # Not used by CI.
  import-schema-to-test:
      bash scripts/import-schema-to-test.sh
  ```

- [ ] **Step 4: Sanity-check the new just target is parsed**

  Run: `just --list 2>&1 | grep -E 'import-schema-to-(dev|test)'`
  Expected output (order may vary):
  ```
      import-schema-to-dev    # ...
      import-schema-to-test   # ...
  ```

- [ ] **Step 5: Commit**

  ```bash
  git -C "$(pwd)" add scripts/import-schema-to-test.sh justfile
  git -C "$(pwd)" commit -m "feat(cloudkit): add import-schema-to-test for bootstrapping the test container

  New scripts/import-schema-to-test.sh and matching just target. Resets the
  test container's Development environment and re-imports schema.ckdb. Used
  once after creating the test container in App Store Connect, and any time
  a developer wants to wipe their test container's Dev back to a known-good
  state. DESTRUCTIVE — gated on CKTOOL_ALLOW_DEV_RESET=1. Refs #495."
  ```

---

## Task 4: (Manual) Create the test container in App Store Connect and add it to the App ID

**Files:** None (Apple Developer Portal / App Store Connect changes only).

**Goal of this task:** Stand up the new container so subsequent tasks can write to it. This step cannot be automated — Apple does not expose a CLI/API for creating CloudKit containers or editing App ID capabilities.

- [ ] **Step 1: Create the new CloudKit container**

  1. Sign in to https://developer.apple.com/account/ with the team's Apple ID.
  2. Navigate to **Certificates, Identifiers & Profiles → Identifiers → iCloud Containers**.
  3. Click **+** to register a new container.
  4. **Description:** `Moolah Test`.
  5. **Identifier:** `iCloud.rocks.moolah.app.test`. (The `iCloud.` prefix is required.)
  6. Confirm.

  Verification: the new container appears in the iCloud Containers list with identifier `iCloud.rocks.moolah.app.test`.

- [ ] **Step 2: Add the test container to the `rocks.moolah.app` App ID**

  1. In **Identifiers → App IDs**, open `rocks.moolah.app` (the iOS/macOS app's App ID).
  2. In the **Capabilities** list, locate **iCloud** (already enabled and configured for `iCloud.rocks.moolah.app.v2`).
  3. Click **Edit** next to iCloud and tick **iCloud.rocks.moolah.app.test** in addition to the existing `iCloud.rocks.moolah.app.v2`.
  4. Save.

  Verification: the App ID's iCloud capability now lists both containers.

- [ ] **Step 3: Refresh provisioning profiles**

  Match-managed distribution profiles need to be regenerated so they reflect the new App ID capability set.

  ```bash
  bundle exec fastlane ios certificates
  bundle exec fastlane mac certificates
  ```

  Expected: `match` reports the existing profiles are out-of-date because the App ID changed, and regenerates them. The new profiles list both `iCloud.rocks.moolah.app.v2` and `iCloud.rocks.moolah.app.test` in their entitlement allowlist; the actual claims that ship in a signed binary are determined by the binary's `CODE_SIGN_ENTITLEMENTS` file.

  Verification: the latest profile in the match Git repository for `match Distribution rocks.moolah.app appstore` (and the `developer_id` mac variant) includes both container identifiers.

- [ ] **Step 4: No commit (no repo files changed)**

  This task only changes Apple Developer Portal state and the (private) match Git repository.

---

## Task 5: (Manual) Bootstrap the test container's Development schema

**Files:** None (CloudKit-side changes only).

**Goal of this task:** Populate the brand-new test container with the current committed schema, so that local dev builds can read/write records once Task 8 starts pointing the Debug binary at it.

- [ ] **Step 1: Run the bootstrap script**

  Prereqs: `DEVELOPMENT_TEAM` is exported (or in `.env`), and either `CKTOOL_MANAGEMENT_TOKEN` is set or `xcrun cktool save-token --type management` has been run for this Apple ID.

  ```bash
  CKTOOL_ALLOW_DEV_RESET=1 just import-schema-to-test
  ```

  Expected output (final lines):
  ```
  ✓ iCloud.rocks.moolah.app.test Development now mirrors CloudKit/schema.ckdb.
  ```

- [ ] **Step 2: Spot-check the imported schema**

  ```bash
  CLOUDKIT_CONTAINER_ID=iCloud.rocks.moolah.app.test xcrun cktool export-schema \
      --team-id "$DEVELOPMENT_TEAM" \
      --container-id iCloud.rocks.moolah.app.test \
      --environment development \
      --output-file .agent-tmp/test-schema-readback.ckdb
  swift run --quiet --package-path tools/CKDBSchemaGen ckdb-schema-gen check-equal \
      --a .agent-tmp/test-schema-readback.ckdb \
      --b CloudKit/schema.ckdb
  ```

  Expected: the second command exits 0 (semantic equality).

  Cleanup: `rm .agent-tmp/test-schema-readback.ckdb`.

- [ ] **Step 3: No commit (no repo files changed)**

---

## Task 6: Remove `install-mac` and simplify `inject-entitlements.sh` to Debug-only

**Files:**
- Modify: `justfile` (delete `install-mac` and `test-release` targets; update `generate`'s comment)
- Modify: `scripts/inject-entitlements.sh` (drop the Release-block injection)

**Goal of this task:** With `install-mac` gone, the only locally-signed CloudKit-enabled binary is Debug. Developers who want to run a Release-signed copy of the app install it from a GitHub release artefact (`Moolah-x.y.z.zip`). That removes the only reason `inject-entitlements.sh` was touching the Release block, so the script collapses to a Debug-only injector and `.build/Moolah.entitlements` lists only `iCloud.rocks.moolah.app.test`.

After this task:
- `ENABLE_ENTITLEMENTS=1 just generate && just build-mac` (or `just run-mac`) → Debug binary signed with `app.test`-only entitlements; runtime selects `app.test` once Task 7 lands.
- `just generate` without `ENABLE_ENTITLEMENTS=1` → as-committed `project.yml`, no entitlements file. Used by fastlane lanes (which then layer their own `CODE_SIGN_ENTITLEMENTS=fastlane/Moolah(-mac).entitlements`) and by `just test` (Debug-Tests has `CODE_SIGN_ENTITLEMENTS=""` and never claims any container).
- A bare `xcodebuild -configuration Release` build outside of fastlane is no longer supported locally — the binary would launch unentitled and be killed by the hardened runtime when it calls `CKContainer`. That is acceptable: the GitHub-release-artefact path is the supported way to run a Release build.

This task is independent of Task 7 — `inject-entitlements.sh` no longer reads or rewrites `project.yml`'s Release configuration, so the order of these two commits doesn't matter and each is buildable on its own.

- [ ] **Step 1: Remove the `install-mac` and `test-release` targets from `justfile`**

  In `justfile`, delete the entire `install-mac` recipe (currently lines 121–136 in the snapshot used to write this plan):

  ```make
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
  ```

  And delete the `test-release` target (currently around line 183), which only existed to chain `install-mac` + `testflight`:

  ```make
  # Build and install macOS app, then upload iOS app to TestFlight
  test-release: install-mac testflight
  ```

  No replacement target is added; developers who want a Release build install it from the GitHub release page.

- [ ] **Step 2: Confirm no other files reference `install-mac` or the deleted `test-release`**

  Use word-boundary anchors so we don't false-positive on the unrelated `test-release-scripts` justfile target or `scripts/tests/test-release-common.sh`:

  ```bash
  grep -rEn '\binstall-mac\b|\btest-release\b' \
      justfile fastlane/ scripts/ guides/ .github/ \
      2>/dev/null \
      | grep -vE '\btest-release-(scripts|common)\b'
  ```

  Expected hits at this point in the plan, all of which the same commit must clean up:

  - `justfile:125: install-mac:` — already deleted in Step 1 of this task.
  - `justfile:183: test-release: install-mac testflight` — already deleted in Step 1 of this task.
  - `scripts/inject-entitlements.sh:13: #      runtime at launch — which is what breaks just install-mac.` — removed by the Step 3 rewrite of this script.

  Re-run the grep after applying Steps 1 and 3 to confirm zero hits remain. Any *additional* hits surfaced by the grep (e.g. a sentence in `guides/RELEASE_GUIDE.md` referencing `install-mac` for local install) must be rewritten in this same commit to point at the GitHub release artefact instead.

- [ ] **Step 3: Rewrite `scripts/inject-entitlements.sh` to handle Debug only**

  Replace the entire file with:

  ```bash
  #!/usr/bin/env bash
  # Prepares the build tree for local CloudKit development.
  #
  # 1. Writes .build/Moolah.entitlements with the full sandbox + CloudKit keys.
  #    The icloud-container-identifiers list contains ONLY the test container —
  #    a locally-signed binary cannot claim the production container. See
  #    issue #495.
  # 2. Produces project-entitlements.yml — a copy of project.yml that augments
  #    each app target's existing Debug block with CODE_SIGN_ENTITLEMENTS
  #    pointing at .build/Moolah.entitlements and the CLOUDKIT_ENABLED
  #    compilation condition. (project.yml already carries a Debug block for
  #    CLOUDKIT_ENVIRONMENT.)
  #
  # Only Debug is touched: the only locally-signed CloudKit-enabled build is
  # `just build-mac` / `just run-mac` (Debug). Release builds are produced by
  # the fastlane lanes (which run `just generate` without ENABLE_ENTITLEMENTS=1
  # and apply their own fastlane/Moolah(-mac).entitlements) and shipped via
  # the GitHub release artefact.
  #
  # The Debug-Tests configuration deliberately does NOT get these, so
  # `just test` never signs the test host with iCloud entitlements. See
  # plans/2026-04-20-strip-icloud-from-tests-design.md.
  #
  # Prints the path to the temp project file. Caller cleans up.
  set -euo pipefail

  TEMP_FILE="project-entitlements.yml"
  ENTITLEMENTS_FILE=".build/Moolah.entitlements"

  mkdir -p "$(dirname "$ENTITLEMENTS_FILE")"
  cat > "$ENTITLEMENTS_FILE" <<'PLIST'
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
      <key>com.apple.security.app-sandbox</key>
      <true/>
      <key>com.apple.security.network.client</key>
      <true/>
      <key>com.apple.security.files.user-selected.read-write</key>
      <true/>
      <key>com.apple.developer.icloud-services</key>
      <array>
          <string>CloudKit</string>
      </array>
      <key>com.apple.developer.icloud-container-identifiers</key>
      <array>
          <!--
            Test container only: see issue #495. A locally-signed binary
            cannot claim the production container. fastlane-signed shipped
            builds use a different entitlements file
            (fastlane/Moolah(-mac).entitlements) that lists only
            iCloud.rocks.moolah.app.v2.
          -->
          <string>iCloud.rocks.moolah.app.test</string>
      </array>
      <key>com.apple.developer.icloud-container-environment</key>
      <string>$(CLOUDKIT_ENVIRONMENT)</string>
  </dict>
  </plist>
  PLIST

  OUTFILE="$TEMP_FILE" ENTITLEMENTS_FILE="$ENTITLEMENTS_FILE" python3 << 'PY'
  import os

  with open("project.yml") as f:
      content = f.read()

  entitlements_path = os.environ["ENTITLEMENTS_FILE"]

  for target in ("Moolah_iOS", "Moolah_macOS"):
      target_header = f"  {target}:\n    type: application\n"
      target_start = content.find(target_header)
      if target_start == -1:
          raise SystemExit(f"inject-entitlements: could not find target {target}")

      configs_marker = "      configs:\n"
      configs_pos = content.find(configs_marker, target_start)
      if configs_pos == -1:
          raise SystemExit(
              f"inject-entitlements: could not find configs: block for {target}"
          )

      # Insert CODE_SIGN_ENTITLEMENTS and the CLOUDKIT_ENABLED compilation
      # condition at the top of the existing Debug: block. project.yml already
      # carries a Debug: block (for CLOUDKIT_ENVIRONMENT: Development);
      # inserting a second Debug: sibling would make xcodegen's YAML loader
      # keep only the last occurrence and silently drop these keys.
      debug_header = "        Debug:\n"
      debug_pos = content.find(debug_header, configs_pos)
      if debug_pos == -1:
          raise SystemExit(
              f"inject-entitlements: could not find Debug: block for {target}"
          )
      debug_insert_at = debug_pos + len(debug_header)
      debug_injection = (
          f"          CODE_SIGN_ENTITLEMENTS: {entitlements_path}\n"
          '          SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) CLOUDKIT_ENABLED"\n'
      )
      content = content[:debug_insert_at] + debug_injection + content[debug_insert_at:]

  # Sanity check — both app targets now carry a Debug-scoped entitlement block.
  debug_marker = "        Debug:\n          CODE_SIGN_ENTITLEMENTS:"
  if content.count(debug_marker) != 2:
      raise SystemExit(
          "inject-entitlements: expected 2 Debug entitlement blocks, "
          f"found {content.count(debug_marker)}"
      )

  with open(os.environ["OUTFILE"], "w") as f:
      f.write(content)
  PY

  echo "$TEMP_FILE"
  ```

- [ ] **Step 4: Verify the script parses, emits a test-only entitlements file, and produces a valid project-entitlements.yml**

  ```bash
  bash -n scripts/inject-entitlements.sh
  rm -f .build/Moolah.entitlements project-entitlements.yml
  bash scripts/inject-entitlements.sh > /dev/null
  /usr/libexec/PlistBuddy -c "Print :com.apple.developer.icloud-container-identifiers" .build/Moolah.entitlements
  grep -c '^          CODE_SIGN_ENTITLEMENTS: \.build/Moolah\.entitlements' project-entitlements.yml
  grep -c 'iCloud\.rocks\.moolah\.app\.v2' project-entitlements.yml
  rm -f project-entitlements.yml
  ```

  Expected:
  ```
  Array {
      iCloud.rocks.moolah.app.test
  }
  2
  1
  ```

  - The `Array { iCloud.rocks.moolah.app.test }` confirms the entitlements file lists only the test container.
  - `2` confirms exactly two Debug entitlement-injection lines (one per app target).
  - `1` is the existing single occurrence of `iCloud.rocks.moolah.app.v2` from the as-committed base-level `CLOUDKIT_CONTAINER_ID:` setting. After Task 7 lands, this number becomes `2` (one Release block per app target). Either way, the script no longer touches that value.

- [ ] **Step 5: Smoke-test that `just generate` (with and without entitlements) still produces a buildable project**

  ```bash
  just generate
  just build-mac
  ENABLE_ENTITLEMENTS=1 just generate
  just build-mac
  ```

  Expected: both invocations build cleanly. `xcodegen` reports no errors; `xcodebuild` succeeds with no warnings.

- [ ] **Step 6: Update the comment in `justfile`'s `generate` recipe**

  The comment block above `generate:` (around line 162–163) currently reads:

  ```make
  # Optionally inject entitlements for local CloudKit development
  ```

  Replace with:

  ```make
  # Optionally inject Debug-config entitlements for local CloudKit development.
  # Set ENABLE_ENTITLEMENTS=1 to make `just build-mac` / `just run-mac` produce
  # a Debug binary signed with the test container's iCloud entitlement. Release
  # builds are produced by fastlane lanes (no entitlement injection here) and
  # shipped via the GitHub release artefact — there is no local Release path.
  ```

- [ ] **Step 7: Commit**

  ```bash
  git -C "$(pwd)" add justfile scripts/inject-entitlements.sh
  git -C "$(pwd)" commit -m "build(cloudkit): drop install-mac; simplify inject-entitlements to Debug-only

  Removes the just install-mac (and the now-vestigial just test-release)
  target. The supported way to run a Release-signed copy of Moolah locally
  is to download the GitHub release artefact (Moolah-x.y.z.zip).

  With install-mac gone, the only locally-signed CloudKit-enabled binary is
  Debug. scripts/inject-entitlements.sh collapses to a Debug-only injector:
  it writes .build/Moolah.entitlements listing only the test container
  (iCloud.rocks.moolah.app.test, per #495) and injects CODE_SIGN_ENTITLEMENTS
  + the CLOUDKIT_ENABLED compilation condition into each target's Debug
  block. The previous Release-block injection and the production-container
  reference in the entitlements array are gone. Refs #495."
  ```

---

## Task 7: Make `CLOUDKIT_CONTAINER_ID` config-driven in `project.yml`

**Files:**
- Modify: `project.yml`

**Goal of this task:** Pin the runtime container per build configuration: Debug and Debug-Tests resolve to `iCloud.rocks.moolah.app.test`; Release resolves to `iCloud.rocks.moolah.app.v2` (the value used by fastlane-signed shipped builds). After this task three runtime paths exist and each lands on the right container:

| Path | How | Expected container |
| --- | --- | --- |
| Local Debug + CloudKit (`ENABLE_ENTITLEMENTS=1 just generate`, then `just build-mac` or `just run-mac`) | Debug config; `inject-entitlements.sh` provides a test-only entitlements file | `iCloud.rocks.moolah.app.test` |
| Tests (`just test`) | Debug-Tests config; `CODE_SIGN_ENTITLEMENTS=""`; CloudKit code path disabled | (value present in Info.plist as `app.test` but unused at runtime) |
| fastlane shipped Release (`bundle exec fastlane mac zip`, `bundle exec fastlane ios beta/validate`) | Release config; fastlane `before_all` runs `just generate` without `ENABLE_ENTITLEMENTS=1`; signed with `fastlane/Moolah(-mac).entitlements` listing only `app.v2` | `iCloud.rocks.moolah.app.v2` |

- [ ] **Step 1: Remove the base-level `CLOUDKIT_CONTAINER_ID` from `project.yml` and adjust the comment**

  In `project.yml`, the current `settings.base` block (around lines 17–46) contains:

  ```yaml
  settings:
    base:
      SWIFT_VERSION: "6.0"
      ENABLE_TESTABILITY: YES
      SWIFT_TREAT_WARNINGS_AS_ERRORS: YES
      GCC_TREAT_WARNINGS_AS_ERRORS: YES

      # ---- CloudKit container ----
      # Surfaced to Swift via the MoolahCloudKitContainer Info.plist key and
      # read by CloudKitContainer.app. Must stay in sync with
      # fastlane/Moolah.entitlements and scripts/cloudkit-config.sh.
      CLOUDKIT_CONTAINER_ID: iCloud.rocks.moolah.app.v2
      ...
  ```

  Replace the four-line CloudKit-container block with a comment that points readers at the per-target configs:

  ```yaml
  settings:
    base:
      SWIFT_VERSION: "6.0"
      ENABLE_TESTABILITY: YES
      SWIFT_TREAT_WARNINGS_AS_ERRORS: YES
      GCC_TREAT_WARNINGS_AS_ERRORS: YES

      # ---- CloudKit container ----
      # CLOUDKIT_CONTAINER_ID is set per-configuration on each app target
      # below (Debug/Debug-Tests → iCloud.rocks.moolah.app.test, Release →
      # iCloud.rocks.moolah.app.v2). Surfaced to Swift via the
      # MoolahCloudKitContainer Info.plist key and read by
      # CloudKitContainer.app. Must stay in sync with
      # fastlane/Moolah.entitlements (Release-only, app.v2),
      # fastlane/Moolah-mac.entitlements (Release-only, app.v2),
      # scripts/inject-entitlements.sh (lists both for local Debug+Release),
      # and scripts/cloudkit-config.sh (CLOUDKIT_CONTAINER_ID_RELEASE /
      # CLOUDKIT_CONTAINER_ID_TEST). Refs issue #495.

      ...
  ```

- [ ] **Step 2: Add per-config `CLOUDKIT_CONTAINER_ID` to `Moolah_iOS`**

  Locate the `Moolah_iOS` target's `configs:` block (currently around lines 78–92). Replace the entire `configs:` block with:

  ```yaml
        configs:
          Debug:
            CLOUDKIT_ENVIRONMENT: Development
            CLOUDKIT_CONTAINER_ID: iCloud.rocks.moolah.app.test
          Debug-Tests:
            # Tests must never pick up iCloud entitlements, even when a dev
            # runs `ENABLE_ENTITLEMENTS=1 just generate` to inject them into Debug.
            CODE_SIGN_ENTITLEMENTS: ""
            SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited)"
            # Values are unused at runtime (test host has no iCloud entitlement
            # and uses in-memory stores) but must be defined so Info.plist
            # expansion yields literal strings rather than e.g.
            # "$(CLOUDKIT_ENVIRONMENT)".
            CLOUDKIT_ENVIRONMENT: Development
            CLOUDKIT_CONTAINER_ID: iCloud.rocks.moolah.app.test
          Release:
            SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) CLOUDKIT_ENABLED"
            CLOUDKIT_ENVIRONMENT: Production
            CLOUDKIT_CONTAINER_ID: iCloud.rocks.moolah.app.v2
  ```

- [ ] **Step 3: Add per-config `CLOUDKIT_CONTAINER_ID` to `Moolah_macOS`**

  Same change in the `Moolah_macOS` target's `configs:` block (currently around lines 116–126). Final form:

  ```yaml
        configs:
          Debug:
            CLOUDKIT_ENVIRONMENT: Development
            CLOUDKIT_CONTAINER_ID: iCloud.rocks.moolah.app.test
          Debug-Tests:
            CODE_SIGN_ENTITLEMENTS: ""
            SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited)"
            CLOUDKIT_ENVIRONMENT: Development
            CLOUDKIT_CONTAINER_ID: iCloud.rocks.moolah.app.test
          Release:
            ENABLE_HARDENED_RUNTIME: YES
            SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) CLOUDKIT_ENABLED"
            CLOUDKIT_ENVIRONMENT: Production
            CLOUDKIT_CONTAINER_ID: iCloud.rocks.moolah.app.v2
  ```

- [ ] **Step 4: Regenerate the Xcode project and confirm both targets see the new setting**

  ```bash
  just generate
  ```

  Expected: `xcodegen` exits 0; `Moolah.xcodeproj/project.pbxproj` is regenerated.

  Then:

  ```bash
  xcodebuild -project Moolah.xcodeproj -target Moolah_macOS -configuration Debug -showBuildSettings 2>/dev/null | grep -E '^\s+(CLOUDKIT_CONTAINER_ID|CLOUDKIT_ENVIRONMENT) ='
  xcodebuild -project Moolah.xcodeproj -target Moolah_macOS -configuration Release -showBuildSettings 2>/dev/null | grep -E '^\s+(CLOUDKIT_CONTAINER_ID|CLOUDKIT_ENVIRONMENT) ='
  ```

  Expected (Debug):
  ```
      CLOUDKIT_CONTAINER_ID = iCloud.rocks.moolah.app.test
      CLOUDKIT_ENVIRONMENT = Development
  ```

  Expected (Release):
  ```
      CLOUDKIT_CONTAINER_ID = iCloud.rocks.moolah.app.v2
      CLOUDKIT_ENVIRONMENT = Production
  ```

  Repeat the same two commands with `-target Moolah_iOS` and confirm matching output.

- [ ] **Step 5: Smoke-test the local Debug build picks the test container**

  ```bash
  ENABLE_ENTITLEMENTS=1 just generate
  just build-mac
  /usr/libexec/PlistBuddy -c "Print :MoolahCloudKitContainer" .build/Build/Products/Debug/Moolah.app/Contents/Info.plist
  /usr/libexec/PlistBuddy -c "Print :MoolahCloudKitEnvironment" .build/Build/Products/Debug/Moolah.app/Contents/Info.plist
  codesign -d --entitlements :- .build/Build/Products/Debug/Moolah.app 2>/dev/null \
      | /usr/libexec/PlistBuddy -c "Print :com.apple.developer.icloud-container-identifiers" /dev/stdin
  ```

  Expected:
  ```
  iCloud.rocks.moolah.app.test
  Development
  Array {
      iCloud.rocks.moolah.app.test
  }
  ```

  Important: the `codesign` line confirms the binary's effective entitlements list only the test container. If `app.v2` appears here, the entitlements injection has regressed.

- [ ] **Step 6: Smoke-test the fastlane-shipped Release path keeps the production container**

  Re-generate the project without entitlements injection (this is what fastlane lanes do via their `before_all`):

  ```bash
  rm -rf .build
  just generate
  xcodebuild build \
      -scheme Moolah-macOS \
      -destination 'platform=macOS' \
      -configuration Release \
      -derivedDataPath .build \
      CODE_SIGN_IDENTITY="-" \
      ENABLE_HARDENED_RUNTIME=NO \
      CODE_SIGN_ENTITLEMENTS=fastlane/Moolah-mac.entitlements 2>&1 \
      | tee .agent-tmp/shipped-release-build.txt | tail -5
  /usr/libexec/PlistBuddy -c "Print :MoolahCloudKitContainer" .build/Build/Products/Release/Moolah.app/Contents/Info.plist
  /usr/libexec/PlistBuddy -c "Print :MoolahCloudKitEnvironment" .build/Build/Products/Release/Moolah.app/Contents/Info.plist
  codesign -d --entitlements :- .build/Build/Products/Release/Moolah.app 2>/dev/null \
      | /usr/libexec/PlistBuddy -c "Print :com.apple.developer.icloud-container-identifiers" /dev/stdin
  rm .agent-tmp/shipped-release-build.txt
  ```

  We replicate the fastlane flow's choice of `fastlane/Moolah-mac.entitlements` via `CODE_SIGN_ENTITLEMENTS`; `CODE_SIGN_IDENTITY="-"` avoids requiring a real Developer ID cert for this smoke build.

  Expected:
  ```
  iCloud.rocks.moolah.app.v2
  Production
  Array {
      iCloud.rocks.moolah.app.v2
  }
  ```

- [ ] **Step 7: Run the test suite to confirm Debug-Tests is unaffected**

  ```bash
  mkdir -p .agent-tmp
  just test 2>&1 | tee .agent-tmp/test-output.txt
  ```

  Expected: tests pass (the suite never touches CloudKit because Debug-Tests sets `CODE_SIGN_ENTITLEMENTS=""` and the test backend uses in-memory SwiftData).

  Cleanup: `rm .agent-tmp/test-output.txt`.

- [ ] **Step 8: Commit**

  ```bash
  git -C "$(pwd)" add project.yml
  git -C "$(pwd)" commit -m "build(cloudkit): pin CLOUDKIT_CONTAINER_ID per build configuration

  Debug and Debug-Tests resolve to iCloud.rocks.moolah.app.test; Release
  keeps iCloud.rocks.moolah.app.v2 (the value used by fastlane-signed
  shipped builds). The base-level setting is removed so each configuration's
  value is the source of truth. Runtime selection is unchanged —
  CloudKitContainer.swift still reads MoolahCloudKitContainer from
  Info.plist. Closes the runtime half of #495."
  ```

---

## Task 8: Update `guides/SYNC_GUIDE.md` §11 Schema Management

**Files:**
- Modify: `guides/SYNC_GUIDE.md`

**Goal of this task:** Document the dual-container architecture so future contributors understand which container each script touches and why.

- [ ] **Step 1: Add a new sub-section after the "Pipeline" diagram**

  In `guides/SYNC_GUIDE.md`, locate the `## 11. Schema Management` section (around line 681). Immediately after the `### Pipeline` block (the ASCII diagram, ending at the line `       schema-prod-baseline.ckdb (committed)`), insert this new sub-section:

  ```markdown
  ### Two containers: release vs test

  Per issue #495, two CloudKit containers are in play:

  - `iCloud.rocks.moolah.app.v2` — the **release container**. Holds production
    user data (Production environment) and is the staging area used by the
    release pipeline before a Console Deploy (Development environment). Reached
    only by fastlane-signed shipped builds (the App Store / TestFlight /
    Developer-ID Mac binary distributed via the GitHub release artefact) and
    by the four release-pipeline schema scripts: `verify-prod-deployed.sh`,
    `verify-prod-matches-baseline.sh`, `refresh-prod-baseline.sh`,
    `import-schema-to-dev.sh`. Each of those scripts pins
    `CLOUDKIT_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID_RELEASE"`.

  - `iCloud.rocks.moolah.app.test` — the **test container**. Reached by every
    locally-signed binary — i.e. every Debug build (`just run-mac`,
    `just build-mac` after `ENABLE_ENTITLEMENTS=1 just generate`) — and by
    the local-only convenience scripts `export-schema.sh`, `verify-schema.sh`,
    `dryrun-promote-schema.sh`, and `import-schema-to-test.sh`. Each of those
    scripts pins `CLOUDKIT_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID_TEST"`.

  There is no local Release path. To run a Release-signed copy of the app,
  download the `Moolah-x.y.z.zip` artefact from the matching GitHub release.
  This makes the local-vs-shipped split mechanical: anything you build on
  your machine is Debug + test container; anything signed with the
  production container is fastlane-built and shipped through the release
  pipeline.

  Container selection at runtime is driven by the `CLOUDKIT_CONTAINER_ID`
  build setting in `project.yml`, which is per-configuration: Debug and
  Debug-Tests resolve to the test container; Release resolves to the release
  container. The setting is surfaced via the `MoolahCloudKitContainer`
  Info.plist key and read by `Backends/CloudKit/CloudKitContainer.swift`.

  This split exists so that the release pipeline's "import schema.ckdb to
  the release container's Dev environment, pause for the developer to click
  Deploy in the Console" handoff is safe: nothing else writes to the release
  container's Dev between the import step and the manual deploy. Local
  developer experimentation runs against a separate container that the
  release pipeline never touches.
  ```

- [ ] **Step 2: Update the "`dryrun-promote-schema` and `verify-schema`" sub-section**

  Replace the existing sub-section (currently around lines 732–738) with:

  ```markdown
  ### `dryrun-promote-schema`, `verify-schema`, `import-schema-to-test`

  All three are manual local affordances, not CI gates, and all three target
  the **test** container (`CLOUDKIT_CONTAINER_ID_TEST`).

  - `verify-schema` imports `.ckdb` to the test container's Dev with
    `--validate`. Use this for belt-and-braces verification before opening
    a schema-touching PR.
  - `dryrun-promote-schema` is Apple's Prod-equivalent dry-run
    (`reset-schema && import-schema --validate`) and is destructive to the
    test container's Dev — set `CKTOOL_ALLOW_DEV_RESET=1` to confirm.
  - `import-schema-to-test` resets the test container's Dev and re-imports
    `.ckdb`. Use this once after creating the test container in App Store
    Connect, or any time you want to wipe the test container back to a
    known-good state. Same `CKTOOL_ALLOW_DEV_RESET=1` gate.
  ```

- [ ] **Step 3: Update the cross-reference in `### CI gates`**

  In the existing `### CI gates` sub-section, the bullet for the release-tag step references `verify-prod-matches-baseline` and `promote-schema` — those names are correct. No change needed there. Just confirm there is no leftover wording in §11 that calls the test container "the team's Dev" or implies a single container; if any such phrasing exists, edit it to use the new "release container" / "test container" vocabulary.

  Search:

  ```bash
  grep -n "team's Dev\|developer's personal Dev\|single container" guides/SYNC_GUIDE.md
  ```

  For each hit inside §11, rewrite the line to use "the test container's Development environment" (for local-dev contexts) or "the release container's Development environment" (for release-pipeline contexts).

- [ ] **Step 4: Verify markdown still renders cleanly**

  ```bash
  awk '/^## 11\./,/^## 12\./' guides/SYNC_GUIDE.md | head -80
  ```

  Expected: §11 reads coherently, with the new sub-section present after `### Pipeline` and the updated `### dryrun-promote-schema, verify-schema, import-schema-to-test` sub-section visible.

- [ ] **Step 5: Commit**

  ```bash
  git -C "$(pwd)" add guides/SYNC_GUIDE.md
  git -C "$(pwd)" commit -m "docs(sync): document the release/test CloudKit container split

  Adds a 'Two containers: release vs test' sub-section to SYNC_GUIDE §11
  Schema Management explaining which container each script targets and why
  the split exists. Updates the dryrun-promote-schema / verify-schema
  sub-section to add import-schema-to-test alongside them. Closes the
  documentation half of #495."
  ```

---

## Task 9: End-to-end verification

**Files:** None (read-only checks).

**Goal of this task:** Prove the split works in practice before opening the PR.

- [ ] **Step 1: Confirm a local Debug run only contacts the test container**

  ```bash
  ENABLE_ENTITLEMENTS=1 just generate
  bash scripts/run-with-logs.sh 'subsystem == "com.moolah.app"' &
  RUN_PID=$!
  sleep 8
  kill $RUN_PID 2>/dev/null || true
  grep -E 'iCloud\.rocks\.moolah\.app\.(v2|test)' .agent-tmp/app-logs.txt | sort -u
  rm -f .agent-tmp/app-logs.txt
  ```

  Expected: only `iCloud.rocks.moolah.app.test` appears in the captured logs.

  (`SyncCoordinator+Lifecycle.swift:81` logs `containerID` once at startup, so a single hit is sufficient.)

- [ ] **Step 1a: Confirm `install-mac` and `test-release` are gone**

  ```bash
  just --list 2>&1 | grep -E '\b(install-mac|test-release)\b'
  ```

  Expected: no output (both targets have been removed).

- [ ] **Step 2: Confirm `just verify-schema` round-trips through the test container**

  ```bash
  CKTOOL_ALLOW_DEV_RESET=1 just import-schema-to-test
  just verify-schema
  ```

  Expected:
  - `import-schema-to-test` ends with `✓ iCloud.rocks.moolah.app.test Development now mirrors CloudKit/schema.ckdb.`
  - `verify-schema` ends with `CloudKit/schema.ckdb imported into the iCloud.rocks.moolah.app.test Development environment.`

- [ ] **Step 3: Confirm `just verify-prod-deployed` still targets the release container**

  ```bash
  just verify-prod-deployed
  ```

  Expected: either `✓ live Production schema matches CloudKit/schema.ckdb` (if Prod is in sync with `schema.ckdb`) or a clear "live Production schema does not match…" message naming `iCloud.rocks.moolah.app.v2`. Either way, the message must reference `iCloud.rocks.moolah.app.v2`, not `app.test`.

- [ ] **Step 4: Confirm the release-rc workflow's user-facing summary is correct**

  ```bash
  grep -n "rocks.moolah.app" .github/workflows/release-rc.yml
  ```

  Expected: the only hit is the line that names `iCloud.rocks.moolah.app.v2` in the manual-deploy summary text — that container ID is correct (the workflow targets the release container).

- [ ] **Step 5: Run the full test suite and the formatter check**

  ```bash
  mkdir -p .agent-tmp
  just format
  just test 2>&1 | tee .agent-tmp/test-output.txt
  just format-check
  ```

  Expected: tests pass; `just format-check` exits 0.

  Cleanup: `rm .agent-tmp/test-output.txt`.

- [ ] **Step 6: No commit — verification only**

---

## Task 10: Open the PR

**Files:** None.

- [ ] **Step 1: Push the branch and open a PR**

  ```bash
  git -C "$(pwd)" push -u origin "$(git -C "$(pwd)" branch --show-current)"
  gh pr create \
      --title "Separate the test/dev iCloud container from the release-pipeline container (#495)" \
      --body "$(cat <<'EOF'
  ## Summary
  - Splits CloudKit container usage so `iCloud.rocks.moolah.app.v2` is touched only by fastlane-signed shipped builds and the release pipeline; new `iCloud.rocks.moolah.app.test` absorbs every local Debug build and every manual-cktool / convenience-script use.
  - Removes `just install-mac` (and the dependent `just test-release`). Developers who want a Release-signed copy of the app install it from the GitHub release artefact (`Moolah-x.y.z.zip`). This collapses `inject-entitlements.sh` to a Debug-only injector listing only `app.test`.
  - `CLOUDKIT_CONTAINER_ID` is now per-build-configuration in `project.yml` (Debug/Debug-Tests → `app.test`; Release → `app.v2`). `scripts/cloudkit-config.sh` exposes `CLOUDKIT_CONTAINER_ID_RELEASE` and `CLOUDKIT_CONTAINER_ID_TEST`; every schema script pins one of the two explicitly.

  ## Manual prereqs (already done — see Tasks 4–5 in the plan)
  - [x] Created `iCloud.rocks.moolah.app.test` in App Store Connect.
  - [x] Added the new container to the `rocks.moolah.app` App ID's iCloud capability.
  - [x] Refreshed match profiles (`bundle exec fastlane ios certificates && bundle exec fastlane mac certificates`).
  - [x] Bootstrapped the test container's Dev schema (`CKTOOL_ALLOW_DEV_RESET=1 just import-schema-to-test`).

  ## Test plan
  - [ ] `just format-check` — clean.
  - [ ] `just test` — passes on iOS Simulator and macOS.
  - [ ] `ENABLE_ENTITLEMENTS=1 just run-mac` — app launches; `MoolahCloudKitContainer` log line reads `iCloud.rocks.moolah.app.test`.
  - [ ] `just --list` — `install-mac` and `test-release` are gone.
  - [ ] `just verify-schema` — succeeds against the test container.
  - [ ] `just verify-prod-deployed` — still targets `iCloud.rocks.moolah.app.v2`.

  ## One-time housekeeping for other developers
  After this PR lands, anyone with previously-synced data on `iCloud.rocks.moolah.app.v2` Development (from old `ENABLE_ENTITLEMENTS=1 just run-mac` flows) will see their local Debug build no longer surface that data — Debug now reads the test container. The shipped Release app on the same Mac is unaffected. To clear the old per-environment sync state on disk if it causes confusion, delete the Application Support `Development/` subdirectory once.

  Refs #495.
  EOF
  )"
  ```

  After the PR opens, format the link as a markdown clickable URL when reporting it back to the user (per `feedback_pr_link_format`):

  > Opened https://github.com/ajsutton/moolah-native/pull/NNN.

- [ ] **Step 2: Add the PR to the merge queue**

  Per `feedback_prs_to_merge_queue`, every PR opened goes through the merge-queue skill rather than being merged manually. Hand the PR number off to the `merge-queue` skill once it appears.

---

## Self-review

- **Spec coverage:**
  - "A new container in App Store Connect / Apple Developer Portal" → Task 4.
  - "`project.yml`'s `CLOUDKIT_CONTAINER_ID` becomes config-driven by build configuration: Debug → `…app.test`, Release → `…app.v2`" → Task 7.
  - "Mirror in `fastlane/Moolah.entitlements` / `fastlane/Moolah-mac.entitlements`" → no edits required: those files ship in fastlane-signed binaries only and correctly list `iCloud.rocks.moolah.app.v2`. Confirmed in Task 7 Step 6 (the shipped-Release smoke test signs against `fastlane/Moolah-mac.entitlements` and checks the resulting Info.plist + entitlements claim `app.v2`).
  - "Mirror in `scripts/cloudkit-config.sh`" → Tasks 1–3.
  - "The release pipeline (`release-rc.yml`, `verify-prod-deployed`, etc.) keeps targeting `…app.v2`" → Task 2 Steps 1–4 pin the four release-pipeline scripts; the workflow itself does not need editing because the scripts do the right thing.
  - "Local dev workflows (`ENABLE_ENTITLEMENTS=1`, `install-mac`) target `…app.test`" → Restructured: `install-mac` is removed in Task 6, so the only local CloudKit-enabled flow is `ENABLE_ENTITLEMENTS=1 just generate && just run-mac` / `just build-mac` (Debug). Verified in Task 7 Step 5. The fastlane-signed shipped Release path is the only thing that ever reaches `app.v2` (Task 7 Step 6).
  - "A new `…app.test` schema needs to be initialised (probably by importing schema.ckdb to it on creation)" → Tasks 3 + 5.
  - "Fastlane provisioning profiles + entitlements may need updating to include both container IDs (or the right one per build config)" → Task 4 Step 3 (match refresh adds `app.test` to dev/distribution profiles via the App ID's iCloud capability). Distribution entitlements files remain `app.v2`-only; locally-injected entitlements are `app.test`-only.
  - Production data on `…app.v2` preserved → no script or build setting in this plan modifies the release container's Production environment; Task 7 Step 6 confirms only the fastlane-signed Release path can reach `app.v2`, and that path is unchanged.

- **Removed-functionality call-out:** `just install-mac` and `just test-release` are deleted (Task 6). Local Release builds are no longer supported; the supported substitute is downloading `Moolah-x.y.z.zip` from the GitHub release page. If `guides/RELEASE_GUIDE.md` or any onboarding doc references `install-mac`, Task 6 Step 2's grep will catch it and that file will be edited in the same commit.

- **Placeholder scan:** No "TBD", "TODO", "implement later", or "Similar to Task N" references remain. Each step that changes code shows the full new file or full replacement block.

- **Type / name consistency:**
  - `CLOUDKIT_CONTAINER_ID_RELEASE` and `CLOUDKIT_CONTAINER_ID_TEST` used identically in Tasks 1, 2, 3, 8.
  - `cloudkit_require_container_id` introduced in Task 1 and called automatically from `cloudkit_cktool` (Task 1); no script needs to call it directly.
  - `MoolahCloudKitContainer` Info.plist key (read by `CloudKitContainer.swift`) and `MoolahCloudKitEnvironment` Info.plist key are referenced consistently across tasks; both are pre-existing wiring.
  - `CKTOOL_ALLOW_DEV_RESET` env-var gate is used in `dryrun-promote-schema.sh` (existing) and `import-schema-to-test.sh` (Task 3) with identical semantics.
