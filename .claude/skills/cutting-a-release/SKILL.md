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
3. **Surfacing the schema-deploy gate.** If the workflow pauses on `await-prod-deploy`, the user needs to manually click Deploy in the CloudKit Console (per the runbook's "Schema deploys" section) and then approve the GH workflow run. Tell them the workflow has paused, point them at the Console, and wait. Don't try to bypass the gate.

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

- After an RC: tell the user how to install the TestFlight build and the Mac zip (extract, drag `Moolah.app` to `/Applications`), and what to look for in smoke-testing.
- After a final: tell the user the App Store submission has been made (auto-release after approval) and that the bump PR is in flight; remind them to edit `project.yml` in the PR if they want a non-default bump.
