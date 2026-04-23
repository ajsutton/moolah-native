# Automate-App Skill: Target the Worktree's Moolah Build

**Status:** Approved, pending review.
**Scope:** `.claude/skills/automate-app/` only. No changes to `project.yml`, `just` targets, or product code.

## Problem

Every example in the `automate-app` skill is of one of two shapes:

```bash
osascript -e 'tell application "Moolah" to <body>'
open "moolah://<path>"
```

When an agent runs these from inside a worktree, both hit the installed release build at `/Applications/Moolah.app`, **not** the worktree's debug build at `<worktree>/.build/Build/Products/Debug/Moolah.app`. The two bundles share a bundle identifier, so LaunchServices picks the `/Applications` copy as the default registration for the name "Moolah" and the `moolah://` URL scheme. Automation silently targets the wrong app — reads return stale state, writes mutate the wrong profile's data, and any "verify my change worked" signal is meaningless.

The fix is to address the worktree bundle by absolute path in both the AppleScript and URL-scheme paths.

## Design

### Two new scripts

Both live at `.claude/skills/automate-app/scripts/`, checked in with the skill. The skill folder is already duplicated into every worktree (it's part of the repo), so each worktree gets its own copy automatically.

#### `moolah-tell` — AppleScript runner

Takes an AppleScript body (from args or stdin) and auto-wraps it in `tell application "<abs-path>" ... end tell`, then execs `osascript`.

```bash
#!/usr/bin/env bash
# Run AppleScript against the Moolah app built in the current worktree.
# Auto-wraps the body in `tell application "<abs-path>" ... end tell`.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
app="$root/.build/Build/Products/Debug/Moolah.app"

if [ ! -d "$app" ]; then
    echo "error: Moolah.app not built at $app" >&2
    echo "       run 'just run-mac' in this worktree first" >&2
    exit 1
fi

if [ "$#" -eq 0 ] || [ "$1" = "-" ]; then
    body=$(cat)
else
    body="$*"
fi

exec osascript -e "tell application \"$app\"" -e "$body" -e "end tell"
```

Usage:

```bash
# One-liner
moolah-tell 'get name of every profile'

# Nested tell
moolah-tell 'tell profile "Test" to get {name, balance} of every account'

# Multi-line via stdin (use `-` or no args)
moolah-tell - <<'EOF'
tell profile "Test"
  set accts to {name, balance} of every account
  set cats to name of every category
  return {accts, cats}
end tell
EOF

# try / on error — place the try inside the body; the wrapper only adds
# the outer `tell application` frame.
moolah-tell 'try
  get balance of account "Nonexistent" of profile "Test"
on error errMsg
  return "ERROR: " & errMsg
end try'
```

#### `moolah-open` — URL-scheme runner

```bash
#!/usr/bin/env bash
# Open a moolah:// URL against the Moolah app built in the current worktree.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
app="$root/.build/Build/Products/Debug/Moolah.app"

if [ ! -d "$app" ]; then
    echo "error: Moolah.app not built at $app" >&2
    echo "       run 'just run-mac' in this worktree first" >&2
    exit 1
fi

exec open -a "$app" "$@"
```

Usage: `moolah-open "moolah://Test/analysis?history=12"`.

### Shared invariants

Both scripts:

- **Resolve the app path from `git rev-parse --show-toplevel`** + `/.build/Build/Products/Debug/Moolah.app`. This works identically in a worktree and in the primary `main` checkout — each maps to its own build directory.
- **Fail fast with a clear error** if the bundle is missing (`not built at <path>; run 'just run-mac' in this worktree first`). They never attempt to build.
- **Do not launch on their own.** `osascript` and `open -a` handle launch-on-first-call; the wrappers just route to the correct bundle.
- Are `set -euo pipefail` scripts with no dependencies beyond `git`, `osascript`, and `open` (all present on every dev machine).

### Invocation

Agents invoke the scripts by full relative path from the worktree root:

```bash
.claude/skills/automate-app/scripts/moolah-tell 'get name of every profile'
.claude/skills/automate-app/scripts/moolah-open "moolah://Test/analysis"
```

`SKILL.md` examples use the short names `moolah-tell` / `moolah-open` for readability, with a note near the top of the reference sections stating that each command is shorthand for the full path above. No `$PATH` mutation is required; agents that prefer the short form can `export PATH=".claude/skills/automate-app/scripts:$PATH"` themselves, but the canonical form in the skill is the full relative path.

### Why not the alternatives

Considered and rejected during brainstorming:

- **Shell-variable pattern (`MOOLAH_APP=…; osascript -e "tell application \"$MOOLAH_APP\" …"`).** Per-call boilerplate; shell-vs-AppleScript quoting is easy to get wrong on one-liners; trivially slips back to `tell application "Moolah"` on the next edit.
- **Distinct bundle identifier for Debug builds.** Would disambiguate natively, but changes CloudKit containers, entitlements, and keychain access group for every developer run — far outside the scope of a skill-level fix.
- **Auto-build on missing app.** Rejected for explicitness — `just run-mac` is slow and side-effectful; it should be a visible step the agent takes deliberately.

## Skill documentation changes

Edit `.claude/skills/automate-app/SKILL.md`:

- **Prerequisites section.** Add a short paragraph explaining why the wrappers exist: bare `tell application "Moolah"` and `open "moolah://..."` target the installed release build via LaunchServices; `moolah-tell` / `moolah-open` force the worktree bundle. Emphasise that raw `osascript` / `open` must not be used for Moolah automation.
- **AppleScript Reference section.** Rewrite every example from `osascript -e 'tell application "Moolah" to <body>'` to `moolah-tell '<body>'`. Multi-line blocks switch to `moolah-tell - <<'EOF' … EOF`.
- **URL Scheme Reference section.** Rewrite every `open "moolah://..."` to `moolah-open "moolah://..."`.
- **Common Test Workflows section.** Apply the same rewrites to worked examples.
- **Error Handling section.** Update the `try` / `on error` example to `moolah-tell 'try … on error … end try'` (try inside the body).
- **Tips section.** Add a one-line reminder: "Always use `moolah-tell` and `moolah-open` — raw `osascript` / `open` targets `/Applications/Moolah.app`, not your worktree build."

No other sections change.

## Verification

Done once manually after the change; no automated test.

1. In a worktree with a built app and the worktree's Moolah running, `moolah-tell 'get name of every profile'` returns the worktree instance's profile list.
2. With no debug build present, `moolah-tell 'get name of every profile'` exits non-zero with the "not built" message on stderr.
3. `moolah-open "moolah://<Profile>"` activates the worktree build's window (not the release build's).
4. Smoke-check one end-to-end workflow from the rewritten Common Test Workflows section (create account → create transaction → verify balance) against a throwaway test profile.

## Out of scope

- No bundle-ID change.
- No `MOOLAH_APP` shell-variable convention.
- No auto-build path in the wrappers.
- No changes to `just` targets or `project.yml`.
- No changes to iOS automation (the skill is macOS-only today).
