# TODO Reference Enforcement — Design

**Date:** 2026-04-23
**Status:** Draft
**Closes:** [#249](https://github.com/ajsutton/moolah-native/issues/249)

## Background

`guides/CODE_GUIDE.md` §20 mandates that every `TODO` / `FIXME` comment reference a tracked GitHub issue in the form `TODO(#N)` / `FIXME(#N)`. Bare `TODO:` / `FIXME:` is disallowed. The guide notes: *"CI will check that referenced issues remain open while the TODO is live — a closed issue means the TODO has stale rationale."*

That CI enforcement does not yet exist. Without it, references drift: a developer can merge a bare `TODO:`, or close an issue while `TODO(#N)` comments still point at it, leaving the codebase citing invalid context.

## Goals

1. **Gate merges** on two conditions:
   - Every `TODO` / `FIXME` uses the `(#N)` form.
   - Every referenced issue `#N` is currently open on GitHub.
2. **Self-heal daily.** When an issue gets closed (via the GitHub UI, another repo, or a PR that didn't touch the TODO file) while live references remain, a scheduled job reopens it and surfaces the references.
3. **Keep a live "don't close me" signal** on every open issue referenced by a live TODO, via a `has-todos` label that is applied and removed automatically.

## Non-goals

- Enforcing any TODO format **other than** `TODO(#N)` / `FIXME(#N)`. Authors can write whatever body text they like after the reference.
- Checking issue references in `plans/` (design documents and roadmaps frequently discuss historical or future issues that may be closed).
- Validating `#N` references in commit messages, PR bodies, or code-review comments — scope is in-source comments only.
- Migrating the existing codebase. There are zero `TODO` / `FIXME` comments in `.swift` sources today, so the check starts green.

## Architecture

Two layers:

1. **Pre-merge gate** (synchronous, blocking): `scripts/check-todos.sh`, invoked via `just validate-todos`, wired into `.github/workflows/ci.yml`.
2. **Daily watchdog** (asynchronous, self-healing): `.github/workflows/todo-issue-watchdog.yml`, running on `cron` + `workflow_dispatch`, using the same extraction library but with reopen / comment / label side effects.

A single shell helper does extraction so both jobs share one source of truth:

```
scripts/
├── check-todos.sh           # pre-merge gate (read-only; exits non-zero on failure)
└── lib/
    └── todo-extract.sh      # sourced by both: emits "N\tfile:line" for each reference
```

The watchdog's logic is inline in the workflow YAML (Node/bash via `gh`), since it's orchestration rather than reusable validation.

## Component: `scripts/lib/todo-extract.sh`

Single responsibility: scan tracked files and emit a normalised stream of TODO references and bare-TODO violations.

### Inputs
None (reads `git ls-files` from CWD).

### Outputs
Two streams on stdout:

```
VALID  <issue_number>  <file>:<line>  <matched-text>
BARE   <file>:<line>  <matched-text>
```

`VALID` lines represent `TODO(#N)` / `FIXME(#N)`. `BARE` lines represent any `TODO` / `FIXME` that doesn't match that form.

### Scope

- `git ls-files` filters to tracked files.
- Pathspec `:(exclude)plans/` excludes the plans directory.
- All file types included (`.swift`, `.sh`, `Justfile`, `.yml`, `.md`, etc.).

### Regex

Case-insensitive. Two patterns applied per line:

- **Valid reference:** `\b(TODO|FIXME)\(#([0-9]+)\)`
- **Bare form:** `\b(TODO|FIXME)(:|\s|$)` *without* the valid reference on the same span.

Implementation: one `grep -nE` pass with the union pattern, then a post-process step that classifies each hit.

### Known limitations

- If a source file legitimately uses an identifier named `TODO` or `FIXME` (e.g. `let TODOStatus = ...`), it will be flagged. This is rare and easily renamed; we document it rather than complicate the regex.
- Multi-line TODO bodies are fine; only the first line triggers classification.

## Component: `scripts/check-todos.sh` (pre-merge gate)

1. Source `todo-extract.sh`.
2. If any `BARE` lines exist, print them and exit 1 with a clear message pointing at CODE_GUIDE §20.
3. Collect unique issue numbers from `VALID` lines into a set.
4. For each unique `N`:
   - `gh api /repos/$GH_REPO/issues/$N --jq .state` (cached in-memory within the run).
   - Record `closed` and `404` results.
5. If any issue is closed or missing, print every offending `file:line` grouped by issue number and exit 1.
6. Otherwise exit 0.

### Rate-limit posture

- GitHub Actions `GITHUB_TOKEN`: 1,000 req/hour/repo.
- Per-run cache ensures one API call per unique issue, not per TODO line.
- Realistic upper bound: the repo will plausibly have tens, not hundreds, of distinct references. Well within budget even with many concurrent CI runs.
- Future optimisation if ever needed: single GraphQL `nodes(ids: [...])` call fetches N issues in one request.

### `just` target

```makefile
# Validate that every TODO/FIXME references an open GitHub issue.
# Requires `gh` authenticated (in CI via GITHUB_TOKEN; locally via `gh auth login`).
validate-todos:
    bash scripts/check-todos.sh
```

### CI wiring

Add to both the `test` and `ui-test` jobs in `.github/workflows/ci.yml`:

```yaml
- name: Validate TODO references
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  run: just validate-todos
```

Placed immediately after `Format check` so style/content gates run before heavier build steps.

## Component: `.github/workflows/todo-issue-watchdog.yml` (daily watchdog)

```yaml
name: TODO Issue Watchdog

on:
  schedule:
    - cron: '0 8 * * *'   # 08:00 UTC daily
  workflow_dispatch:

permissions:
  issues: write
  contents: read

jobs:
  watchdog:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Ensure has-todos label exists
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh label create 'has-todos' \
            --color 'fbca04' \
            --description 'Open issue is referenced by live TODO(#N) comments — do not close until references are removed.' \
            || true
      - name: Reconcile labels and reopen closed issues
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: bash scripts/todo-watchdog.sh
```

### `scripts/todo-watchdog.sh` algorithm

```
1. Source todo-extract.sh. Build map M: issue_number -> list of "file:line" strings
   from VALID stream (ignore BARE — pre-merge gate's job).
2. Let S = set of keys in M.                          # referenced issues
3. Query GitHub for all issues with label `has-todos` (any state): set L.
4. For each N in S:
     state = gh api .../issues/N --jq .state
     if state == 'closed':
        gh issue reopen N
        comment = "Reopened automatically: live TODO comments still reference this issue.
                   References in main:
                     - <file>:<line>
                     - <file>:<line>
                     ...
                   Remove the TODOs (or resolve the issue so they can be removed) before closing again."
        gh issue comment N --body "$comment"
        gh issue edit N --add-label 'has-todos'
     elif state == 'open':
        if 'has-todos' not already in the issue's labels:
          gh issue edit N --add-label 'has-todos'
     else:   # 404 — transferred/deleted
        echo "::warning::TODO references missing issue #$N at $(refs_for N)"
5. For each N in L that is NOT in S:
     gh issue edit N --remove-label 'has-todos'
6. Exit 0. Failures in individual issues are logged as ::warning:: but don't fail the job —
   the CI gate catches real problems; the watchdog is best-effort reconciliation.
```

### Failure mode & alerting

The watchdog is self-healing — it runs daily and any transient failure (API blip, auth hiccup) corrects itself on the next run. No paging / Slack wiring is in scope; rely on GitHub's built-in workflow-failure email to the actor (`@ajsutton`).

## Data flow summary

```
 Developer writes TODO  ─┐
                         │
                         ▼
                 ┌──────────────────┐
                 │  PR / push to    │
                 │  main            │
                 └────────┬─────────┘
                          │
                          ▼
                 ┌──────────────────┐
                 │ just validate-   │  ← BLOCKS merge on bare TODO
                 │ todos (CI)       │    or closed-issue reference
                 └──────────────────┘

 Someone closes referenced issue via UI / another repo
                          │
                          ▼
                 ┌──────────────────┐
                 │  Daily cron      │
                 │  watchdog        │  ← reopens, comments, relabels
                 └──────────────────┘
```

## Label: `has-todos`

- **Colour:** `#fbca04` (amber) — matches existing housekeeping labels (`swiftlint-cleanup`, `severity:minor`).
- **Description:** "Open issue is referenced by live TODO(#N) comments — do not close until references are removed."
- **Managed by:** the watchdog only. Humans should not apply or remove it manually.
- **Invariant:** post-watchdog-run, the set of issues carrying `has-todos` equals the set of issues referenced by at least one live TODO.

## Optional: SwiftLint custom rule (inline Xcode feedback)

As an ergonomic addition, add a `custom_rules` entry to `.swiftlint.yml` that flags bare `TODO:` / `FIXME:` in `.swift` files:

```yaml
custom_rules:
  todo_issue_reference:
    name: "TODO must reference a GitHub issue"
    regex: '(?i)//[^\n]*\b(TODO|FIXME)\b(?!\(#[0-9]+\))'
    message: "Use TODO(#N) / FIXME(#N) referencing an open GitHub issue. See CODE_GUIDE §20."
    severity: error
```

This fires inside Xcode as the developer types, catching bare TODOs before they even reach `just format-check`. It is **not** authoritative — the shell script is the CI gate because it also covers non-Swift files — but it shortens the feedback loop for the common case.

If one mechanism is preferred, drop this section; the behaviour is identical either way.

## Files changed

| Path | Change |
|---|---|
| `scripts/lib/todo-extract.sh` | **new** — extraction helper |
| `scripts/check-todos.sh` | **new** — pre-merge gate |
| `scripts/todo-watchdog.sh` | **new** — daily reconciliation |
| `Justfile` | +1 target: `validate-todos` |
| `.github/workflows/ci.yml` | +1 step in `test` + `ui-test` jobs |
| `.github/workflows/todo-issue-watchdog.yml` | **new** — cron workflow |
| `.swiftlint.yml` | +1 `custom_rules` entry (optional) |
| `guides/CODE_GUIDE.md` | §20: replace *"Enforcement tracked by #249"* with a pointer to `just validate-todos` + the watchdog |

## Testing

- **Extraction library:** ship with a self-test mode. `scripts/lib/todo-extract.sh --self-test` runs against a fixture file containing one valid reference, one bare TODO, and one non-TODO identifier, and asserts the expected output. Invoked from a `just test-scripts` target.
- **Pre-merge gate:** manual smoke — create a throwaway branch with `// TODO(#999999):` (closed issue), push, confirm CI fails with clear output.
- **Watchdog:** trigger via `workflow_dispatch` against `main` after merge. Confirm the label exists, no-op run on the initial empty-TODO state succeeds.
- **End-to-end:** as part of the implementation plan, add one legitimate `TODO(#N)` to a throwaway comment pointing at #249 itself, verify the pre-merge gate passes, remove it before merge.

## Rollout

1. Implementation PR (single branch):
   - Adds extraction lib, pre-merge gate, watchdog workflow, SwiftLint rule, Justfile target, CODE_GUIDE update.
   - Body: `Fixes #249`.
2. After merge, manually trigger the watchdog via `gh workflow run todo-issue-watchdog.yml` to confirm it's wired up.
3. No codebase migration needed (zero existing TODOs).

## Open questions

None. All clarifications resolved in brainstorming:
- Scope: all tracked files except `plans/`.
- Label: `has-todos`, lifecycle managed by watchdog.
- Rate limits: well within `GITHUB_TOKEN`'s 1,000/hour budget.
