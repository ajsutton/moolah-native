# Release Process — Design

**Date:** 2026-04-26
**Status:** Approved (pending implementation plan)
**Scope:** Define the end-to-end release process for moolah-native — RC tagging that publishes to TestFlight and a GH pre-release with a notarised Mac DMG, followed by a final tag at the same commit that submits the existing TestFlight build to the App Store and copies the DMG to a final GH release.

## Goals

- Cut a release candidate that uploads to TestFlight (iOS) and publishes a notarised Mac DMG to a GitHub pre-release. Same commit can be RC'd multiple times (`-rc.1`, `-rc.2`, …) until smoke testing is happy.
- Promote a confirmed-good RC to a final release by re-tagging the **same commit**: submit the existing TestFlight binary for App Store review (auto-release after approval) and copy the same notarised DMG to a final GitHub release.
- Make the procedure runnable by a human from a written runbook (no AI required) and equally runnable by Claude via a thin skill that drafts user-facing release notes.

## Non-goals

- Automated rollbacks. CloudKit schema promotion is one-way; App Store releases are managed in App Store Connect.
- Mac App Store distribution. Mac is distributed via direct DMG download from GitHub.
- Per-build differentiation inside the binary. The same bytes ship to RC testers and final users; channel signals (TestFlight badge, GH "Pre-release" label) carry the RC vs final distinction. `AboutView` already shows the build number for diagnostic identification.
- Beta testing program management (TestFlight tester groups, etc.). Out of scope.

## Architectural decisions

### Tag conventions (SemVer pre-release)

- **RC:** `v<MAJOR>.<MINOR>.<PATCH>-rc.<N>`. Example: `v1.2.0-rc.1`, `v1.2.0-rc.2`.
- **Final:** `v<MAJOR>.<MINOR>.<PATCH>`. Example: `v1.2.0`.
- The final tag MUST point at the same commit as the RC being promoted.
- Tags are never deleted once pushed. Abandoned RCs and final releases stay as historical record.

### Same bytes ship to RC testers and final users

- The RC workflow builds the iOS IPA, uploads to TestFlight, builds + notarises the Mac DMG, and attaches the DMG to the GH pre-release.
- The final workflow performs **no rebuild**. It looks up the existing TestFlight build (uploaded by the RC), submits it for App Store review with auto-release after approval, and copies the same DMG asset from the RC's GH release to the final's GH release.
- Trade-off: a bug found between RC and final requires a new RC cycle. Accepted, because shipping the bytes that were beta-tested is the correct safety property.

### CloudKit schema promotion happens at RC time

- `verify-prod-matches-baseline` then `promote-schema` run in `release-rc.yml`, before any build.
- Rationale: schema promotion is one-way; running it at RC time lets testers exercise the new schema in TestFlight before customers see it. If the schema is wrong, that's the cycle to catch it.
- The final workflow does not touch schema.

### Three layers, no duplication

- **`justfile`** is the source of truth for what each step does. Each target has a `# comment` explaining its semantics, inputs, outputs.
- **`guides/RELEASE_GUIDE.md`** (the runbook) is the source of truth for the procedure — which decisions to make, which `just` targets to run, in what order. The runbook never explains what a `just` target does internally; it cites the target by name.
- **`.claude/skills/cutting-a-release/SKILL.md`** points at the runbook and adds only what's AI-specific (mostly notes about how to gather and draft release notes content). It never duplicates the procedure.

### Release notes are AI-authored, brand-aligned, and scope-aware

- The skill drafts user-facing release notes by analysing merged PRs and commits in the relevant range, then renders them in the voice defined by `guides/BRAND_GUIDE.md` (confident-warm, plain-spoken, "you/your", no corporate-speak).
- **RC notes** describe what changed since the previous RC for the same marketing version, or since the previous final if this is `rc.1`.
- **Final notes** describe what changed since the previous final release — the cumulative picture for end-users.
- A human can do this by hand by following the same runbook step. The runbook describes the analysis ("read merged PRs, filter to user-facing changes, voice per BRAND_GUIDE"); the skill executes it on the user's behalf.
- Monthly cron RCs auto-generate notes from PR titles via `gh release create --generate-notes`; a user or Claude can later upgrade them with `gh release edit --notes-file`.

### Post-finalize version bump is owned by the workflow, with automerge

- After `release-final.yml` finishes its primary work (App Store submission + DMG copy), it opens a PR bumping `project.yml` to the next minor version with `gh pr merge --auto --squash`.
- If the user wants a different bump (major / patch / explicit version), they edit `project.yml` in the PR before automerge fires.
- This keeps `main` always describing the marketing version of the next release-in-flight, with no manual step required from the human cutting the release.

## Components

### `justfile` targets (local atoms)

Every target is callable from the runbook by name and is the single source of truth for its semantics.

- `release-preflight` — verifies the local repo is on `main`, working tree is clean, in sync with `origin/main`, `gh` is authenticated, and there is no in-flight RC blocked by failed CI. Exits non-zero with a descriptive message on any failure.
- `release-next-version KIND` — emits JSON describing the next tag.
  - `KIND=rc`: reads `MARKETING_VERSION` from `project.yml`, lists tags matching `v$MV-rc.*`. Output: `{"version": "1.2.0-rc.2", "confirm_marketing": <bool>, "notes_base": "v1.2.0-rc.1"}`. `confirm_marketing` is true when the previous tag was a final and the user should confirm the marketing version is right for the new RC.
  - `KIND=final`: reads `MARKETING_VERSION`, asserts at least one matching RC tag exists. Output: `{"version": "1.2.0", "rc_tag": "v1.2.0-rc.3", "commit": "<sha>", "notes_base": "v1.1.0"}`.
- `release-create-rc VERSION NOTES_FILE` — runs `gh release create v<VERSION> --target main --prerelease --title "v<VERSION>" --notes-file <NOTES_FILE>`. Creates the tag, which fires `release-rc.yml`. Errors if a release with this tag already exists.
- `release-create-final VERSION RC_TAG NOTES_FILE` — resolves the commit SHA at `<RC_TAG>`, runs `gh release create v<VERSION> --target <SHA> --title "v<VERSION>" --notes-file <NOTES_FILE>`. Creates the tag at the same commit as the RC, fires `release-final.yml`.
- `release-wait TAG` — polls the workflow run associated with `<TAG>` until terminal. Exits zero on success, non-zero with the workflow conclusion otherwise.
- `release-status TAG` — prints the workflow state, TestFlight upload status (build number + processing state), GH release asset list, and (for final tags) App Store submission state.

### `guides/RELEASE_GUIDE.md` (the runbook)

Sections:

1. **Conventions** — tag formats, what RC and final mean, same-commit invariant, no-tag-deletion rule.
2. **Prerequisites** — Match Developer ID + App Store Distribution certs, ASC API key secrets, GH automerge enabled on the repo's branch protection.
3. **Cut an RC** — six numbered steps, each citing the `just` target it uses (preflight, determine version, author notes, create release, wait + verify, smoke-test).
4. **Promote RC to final** — seven numbered steps (preflight, determine version, author final notes, create release, wait, verify, review bump PR).
5. **Authoring release notes** — research instructions (`gh pr list`, `git log` against `notes_base`), filtering rules (skip pure refactors / test-only changes, aggregate small fixes), voice per `BRAND_GUIDE.md`. Applies to both RC and final.
6. **Recovery** — what to do when something goes wrong. Covered below.

### `.claude/skills/cutting-a-release/SKILL.md`

Minimal body that points at the runbook plus AI-specific notes:

- Identifies whether the user wants an RC, a final, or a status check.
- Defers to `guides/RELEASE_GUIDE.md` for the procedure.
- For the release-notes step, executes the analysis described in the runbook (read merged PRs, read commits since `notes_base`, draft per `BRAND_GUIDE.md`), iterating with the user before saving the final notes file and invoking the next `just` target.
- After tagging, monitors with `release-wait`. On failure, points at the runbook's Recovery section.

The skill explicitly avoids restating procedural steps that live in the runbook.

### GitHub workflows

#### `release-rc.yml` — trigger `push: tags: ['v*-rc.*']`

Runs on `macos-26`. Steps:

1. Checkout the tag.
2. Extract base SemVer from tag name; inject into `project.yml` for this build only (not committed).
3. `just verify-prod-matches-baseline` then `just promote-schema`.
4. `bundle exec fastlane ios beta` — builds, signs, uploads to TestFlight.
5. Capture the build number Fastlane assigned; write to `build-number.txt`.
6. Build `Moolah-macOS` Release with Developer ID Application signing (Match `developer_id` profile), hardened runtime on, app-sandbox + iCloud entitlement.
7. Notarise the `.app` (`xcrun notarytool submit … --wait`), staple.
8. Build a DMG with `create-dmg`, sign with the same Developer ID, notarise, staple.
9. `gh release upload v<tag> Moolah-<version>.dmg build-number.txt --clobber` — attaches assets to the GH pre-release the skill (or cron) created.

The GH pre-release is created **before** the workflow runs, by `just release-create-rc` (or by the monthly cron). The workflow's role is to attach assets and upload to TestFlight, not to create the release.

#### `release-final.yml` — trigger `push: tags: ['v*']` with a guard against `*-rc.*`

Runs on `ubuntu-latest`. No xcodebuild involved. Steps:

1. Checkout the tag.
2. Find the latest `v<MARKETING>-rc.*` tag for this marketing version. Assert it points at the same commit as the final tag; fail loudly if not.
3. `gh release download v<rc-tag> -p 'build-number.txt'` — read the TestFlight build number to submit.
4. Run a new Fastlane lane (`submit_review`) that calls `deliver` with `submit_for_review: true, automatic_release: true, skip_binary_upload: true, skip_metadata: true, skip_screenshots: true, build_number: <RC's build>`. App Store Connect's "auto-release after approval" is configured here.
5. `gh release download v<rc-tag> -p '*.dmg'`, then `gh release upload v<tag> *.dmg` — bytes-identical asset transfer.
6. Check out `main`, branch `release/post-v<version>-bump`, run `just bump-version <next-minor>`, commit, push, `gh pr create`, then `gh pr merge --auto --squash`. PR body explains the default bump and instructs the user to edit `project.yml` in the PR if a different bump is desired.

#### `monthly-tag.yml` — rewired

Runs on the 1st of each month. Calls `just release-next-version rc`, then `gh release create v<version> --target main --prerelease --generate-notes`. The cron has no AI in the loop, so notes are auto-generated from PR titles. The created GH release fires `release-rc.yml` exactly as a manual cut would.

#### `testflight.yml` — deleted

Replaced by `release-rc.yml`.

## Failure modes and recovery

These live in the runbook's Recovery section.

- **Schema promoted, build failed mid-RC** — schema is in Production permanently. Diagnose, fix on `main`, cut a new RC; the next RC's schema verify step will succeed because the prod baseline now matches. The bad RC stays as a record. Mark the GH pre-release body to note it is obsolete.
- **iOS upload succeeded, Mac DMG step failed** — re-run the workflow run from the failed step. Notarisation hiccups are usually transient. If a config issue, fix and cut a new RC.
- **Notarisation timeout** — `notarytool submit --wait` blocks for up to ~30 min. Re-running the workflow fetches the existing submission status rather than re-submitting.
- **RC failed smoke-testing** — don't promote it. Cut a new RC. The bad RC's GH pre-release stays for traceability.
- **Marketing version needs to skip ahead** — `just bump-version <X.Y.Z>` and PR through merge-queue. The next RC reads the new version.
- **Final workflow fails after submission** — re-run the workflow. The build is unchanged; idempotent steps (DMG copy, bump PR) are safe to retry.
- **Apple rejects the App Store submission** — address feedback on `main`, cut a new RC + final cycle. Auto-release is per-submission.
- **Bump PR has merge conflicts** — the PR is opened anyway; resolve manually and let merge-queue handle it.
- **Erroneous tag pushed** — never delete the tag. The bad release stays as record. Move forward with a new RC or final tag at a new commit.

## Open implementation questions (resolved during plan, not design)

The implementation plan covers:

- One-time setup steps (Match Developer ID cert creation, GH branch-protection automerge, secrets configured for ASC API and Match repo).
- Whether the bump-PR step needs custom merge-queue integration or just standard `gh pr merge --auto`.
- Where `notes_base` resolution lives (justfile target vs. inline shell in workflow) when the previous tag is for a different marketing version line.
- DMG creation tooling — `create-dmg` vs raw `hdiutil` — chosen during implementation.
- Fastlane Matchfile updates to include `developer_id` profile type.

## Acceptance criteria

The release process is complete when:

1. Running `just release-preflight && just release-next-version rc` from a clean `main` produces a valid version JSON.
2. `just release-create-rc <version> <notes-file>` creates a GH pre-release that fires `release-rc.yml`, which uploads an IPA to TestFlight and attaches a notarised DMG to the pre-release within 30 minutes.
3. `just release-create-final <version> <rc-tag> <notes-file>` creates a GH release at the same commit as the RC, fires `release-final.yml`, which submits the existing TestFlight build for App Store review with auto-release on, copies the DMG to the final release, and opens an automerge bump PR.
4. The skill `cutting-a-release` walks Claude through both flows by reading `guides/RELEASE_GUIDE.md`, drafting notes per `BRAND_GUIDE.md`, and invoking the relevant `just` targets.
5. A human following only `guides/RELEASE_GUIDE.md` (no Claude) can complete both flows without missing or ambiguous steps.
6. The monthly cron continues to cut RCs autonomously on the 1st of each month using auto-generated notes.
