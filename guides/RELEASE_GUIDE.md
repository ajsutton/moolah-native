# Release Guide

> The procedure for cutting a release. The `justfile` is the source of truth for what each `just` target does; this guide is the source of truth for which targets to run, in what order, and which decisions to make. The skill `cutting-a-release` follows this same guide.

## Conventions

- **RC tag:** `v<MAJOR>.<MINOR>.<PATCH>-rc.<N>`. Example: `v1.2.0-rc.1`, `v1.2.0-rc.2`.
- **Final tag:** `v<MAJOR>.<MINOR>.<PATCH>`. Example: `v1.2.0`.
- The final tag points at the **same commit** as the RC being promoted. The same iOS binary that was beta-tested ships to the App Store; the same notarised Mac zip that RC users downloaded is the one attached to the final GitHub Release.
- Tags are never deleted once pushed. Abandoned RCs and final releases stay as historical record.
- Channel signals carry the RC vs final distinction (TestFlight badge, GitHub "Pre-release" label). The binary itself is identical.

## Prerequisites

Before cutting any release, confirm these are in place. They are one-time setup items.

- [ ] Match repo contains a `Developer ID Application` cert for `rocks.moolah.app`. Verify with `security find-identity -v -p codesigning | grep "Developer ID Application"` after running `bundle exec fastlane match developer_id`.
- [ ] App Store Connect API key secrets are present in the GitHub repo: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT`.
- [ ] Match secrets are present: `MATCH_GIT_URL`, `MATCH_PASSWORD`, `MATCH_GIT_BASIC_AUTHORIZATION`.
- [ ] CloudKit secrets are present: `DEVELOPMENT_TEAM`, `CKTOOL_MANAGEMENT_TOKEN`.
- [ ] GitHub repo allows auto-merge (Settings → General → "Allow auto-merge").
- [ ] GitHub Environment `await-prod-deploy` exists with the release operator as a required reviewer (Settings → Environments → New environment). The release pipeline pauses here when a CloudKit Production schema deploy is needed.

## Schema deploys

CloudKit Production schema changes can only be deployed via the **CloudKit Console** ("Schema → Deploy Schema Changes to Production"). Apple's API does not expose a CLI/CI path. The release pipeline handles this with a manual-approval gate:

1. The pipeline checks whether live Production already matches `CloudKit/schema.ckdb`.
2. If it does, the pipeline proceeds without intervention.
3. If it doesn't, the pipeline imports `schema.ckdb` to the team's CloudKit Development environment (so the Console diff view shows exactly what will be promoted) and pauses for approval on the `await-prod-deploy` environment.
4. The operator opens the [CloudKit Console](https://icloud.developer.apple.com/dashboard/), reviews the diff, clicks **Deploy Schema Changes to Production**, then approves the workflow run on GitHub.
5. The pipeline re-verifies that Production matches `schema.ckdb`. If it does, the build proceeds; if not, the pipeline fails (the deploy didn't actually take effect, or the schema in Console doesn't match).

The pipeline writes detailed instructions to the workflow run's job summary when it pauses — follow those.

## Cut a release candidate

1. **Pre-flight.** Run `just release-preflight`. Fix any issue it reports (push outstanding work, sync with origin, authenticate `gh`, wait for green CI) before continuing.

2. **Determine the version.** Run `just release-next-version rc`. Read the JSON output:
   - `version` — the proposed RC version (e.g. `1.2.0-rc.2`).
   - `confirm_marketing` — `true` when the previous tag was a final release. When true, confirm the marketing version in `project.yml` is right for the new RC. If wrong, run `just bump-version <X.Y.Z>`, open a PR to land it, then return to step 1.
   - `notes_base` — the previous RC tag (or previous final, if this is `rc.1`). Use this as the comparison base when authoring release notes. If this is the first release ever for the project (no prior tags), `notes_base` will be empty — in that case, summarise the project's purpose and headline features rather than describing a delta.

3. **Author release notes.** RC notes describe what changed since `notes_base` — the audience is testers; they want the delta from the previous RC. See "Authoring release notes" below for the procedure. Save the draft to `.agent-tmp/release-notes-<version>.md`.

4. **Cut the GH pre-release.** Run `just release-create-rc <version> .agent-tmp/release-notes-<version>.md`. This creates the tag, which fires `release-rc.yml`.

5. **Wait + verify.** Run `just release-wait v<version>`. The workflow may pause on the `await-prod-deploy` job — if so, follow the "Schema deploys" procedure above (open Console → Deploy → approve the GH job). When the workflow concludes green, run `just release-status v<version>` to confirm the Mac zip is attached to the GH pre-release and the IPA reached TestFlight.

6. **Smoke-test.** Install the TestFlight build (iOS device + simulator) and the Mac zip (extract, drag `Moolah.app` to `/Applications`, run). If anything is broken, document the issue, fix on `main`, and cut a fresh RC. Don't delete the bad RC; mark its release body to note it is obsolete.

## Promote an RC to final

1. **Pre-flight.** Run `just release-preflight`. Confirm the latest RC for the current marketing version has been smoke-tested and is the one you want to ship.

2. **Determine the version.** Run `just release-next-version final`. The JSON includes `version`, `rc_tag`, `commit`, and `notes_base` (the previous final tag).

3. **Author final release notes.** Final notes describe what changed since `notes_base` (the previous final release) — the audience is end-users; they want the cumulative picture, polished. The release notes you wrote for the RC are a starting point but typically need to be rewritten for the final audience. Save to `.agent-tmp/release-notes-<version>.md`.

4. **Cut the final GH release.** Run `just release-create-final <version> <rc_tag> .agent-tmp/release-notes-<version>.md`. This creates the final tag at the same commit as the RC and fires `release-final.yml`.

5. **Wait.** Run `just release-wait v<version>`.

6. **Verify.** Run `just release-status v<version>`. Confirm the workflow concluded green and the Mac zip asset is attached to the final release. The workflow's green conclusion implies the App Store submission was made (auto-release on) and the bump PR was opened with automerge enabled — but cross-check both in App Store Connect and the GitHub PR list. If you see a workflow failure, jump to "Recovery" → "Final workflow fails after submission".

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

### Workflow paused on `await-prod-deploy` and you need to abandon
If you click "Reject" on the manual-approval gate (or the 6-hour timeout fires before approval), the build job is skipped. The Dev environment still has the staged schema — that's fine; the next release run will overwrite it cleanly. The GH pre-release tag stays per the never-delete rule; mark its body obsolete.

### Console deploy didn't take effect
If you click Deploy in the Console and approve the workflow but `await-prod-deploy` still fails the re-verify step: the Console operation either didn't complete, or the schema you deployed differs from `CloudKit/schema.ckdb` for some reason. Open the Console, check Production's current schema, and either repeat the Deploy or fix the discrepancy. Then re-run the failed `await-prod-deploy` job (Actions → Run → Re-run failed jobs).

### Schema deploy succeeded, build failed mid-RC
The Production schema change is permanent. Diagnose the build failure on `main`, fix it, cut a new RC. The next RC's preflight will see Prod already matches `schema.ckdb` and skip straight to the build. The bad RC's GH pre-release stays as a record; edit its body to note it is obsolete.

### iOS upload succeeded, Mac zip step failed
Re-run the workflow run from the failed step (Actions → Run → Re-run failed jobs). Notarisation hiccups are usually transient. If a config issue, fix on `main` and cut a new RC.

### Notarisation timeout
`notarytool submit --wait` blocks for up to ~30 min. Re-running the workflow fetches the existing submission status rather than re-submitting. If the queue is genuinely slow, give it another hour.

### RC failed smoke-testing
Don't promote it. Cut a new RC. The bad RC's GH pre-release stays for traceability — edit the release body to note it.

### Marketing version needs to skip ahead
Open a PR that bumps `MARKETING_VERSION` past it (or back, if you really need to). Land through the merge-queue. The next RC reads the new value.

### Final workflow fails after submission
Re-run the workflow. The build is unchanged; idempotent steps (Mac zip copy, bump PR creation) are safe to retry.

### Apple rejects the App Store submission
Address feedback on `main`, cut a new RC + final cycle. Auto-release is per-submission, so the rejected submission has no live effect.

### Bump PR has merge conflicts
The PR is opened anyway. Resolve manually and let merge-queue handle it. The release itself is already complete; the bump PR is only there to set up the next cycle.

### Erroneous tag pushed
**Never delete the tag.** The bad release stays as record. Move forward with a new RC or final tag at a new commit. Edit the bad release's body to note that it is obsolete.
