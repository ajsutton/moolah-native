# Automate-App Worktree Targeting — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `automate-app` automation hitting `/Applications/Moolah.app` instead of the worktree's debug build by routing every AppleScript and `moolah://` URL through path-scoped wrapper scripts.

**Architecture:** Two small bash wrappers (`moolah-tell`, `moolah-open`) live inside the skill at `.claude/skills/automate-app/scripts/`. Each resolves the current worktree's `Moolah.app` via `git rev-parse --show-toplevel`, fails fast if unbuilt, and targets that bundle by absolute path. `SKILL.md` is rewritten so every example uses the wrappers — no raw `osascript -e 'tell application "Moolah"'` or bare `open "moolah://…"` remains.

**Tech Stack:** Bash 3.2+ (`set -euo pipefail`), `git`, macOS `osascript`, macOS `open -a`.

**Reference spec:** `plans/2026-04-23-automate-app-worktree-targeting-design.md`

---

## File Structure

- **Create:** `.claude/skills/automate-app/scripts/moolah-tell` — AppleScript runner, ~20 lines, executable.
- **Create:** `.claude/skills/automate-app/scripts/moolah-open` — `moolah://` URL runner, ~15 lines, executable.
- **Modify:** `.claude/skills/automate-app/SKILL.md` — rewrite Prerequisites, AppleScript Reference, URL Scheme Reference, Common Test Workflows, Error Handling, and Tips sections to use the wrappers.

No other files are touched. No Xcode project, Swift code, or `just` target changes.

---

## Task 1: Create `moolah-tell`

**Files:**
- Create: `.claude/skills/automate-app/scripts/moolah-tell`

- [ ] **Step 1: Create the directory**

Run:
```bash
mkdir -p .claude/skills/automate-app/scripts
```

- [ ] **Step 2: Write the script**

Write `.claude/skills/automate-app/scripts/moolah-tell`:

```bash
#!/usr/bin/env bash
# Run AppleScript against the Moolah app built in the current worktree.
# Auto-wraps the body in `tell application "<abs-path>" ... end tell` so the
# command targets the worktree's debug build, not /Applications/Moolah.app.
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

- [ ] **Step 3: Make it executable and stage the executable bit**

Run:
```bash
chmod +x .claude/skills/automate-app/scripts/moolah-tell
git add .claude/skills/automate-app/scripts/moolah-tell
git update-index --chmod=+x .claude/skills/automate-app/scripts/moolah-tell
```

- [ ] **Step 4: Verify the missing-app error path**

Temporarily point the script at a non-existent bundle to confirm the error branch. Run:
```bash
MOOLAH_TEST_APP_OVERRIDE=/tmp/nonexistent-moolah.app bash -c '
  root=$(git rev-parse --show-toplevel)
  app="$MOOLAH_TEST_APP_OVERRIDE"
  [ ! -d "$app" ] && echo "error: Moolah.app not built at $app" >&2 && echo "       run just run-mac in this worktree first" >&2 && exit 1
'; echo "exit=$?"
```
Expected output on stderr:
```
error: Moolah.app not built at /tmp/nonexistent-moolah.app
       run just run-mac in this worktree first
```
Expected: `exit=1`.

(Cross-check by running the real script against the real path:)

```bash
if [ ! -d .build/Build/Products/Debug/Moolah.app ]; then
    .claude/skills/automate-app/scripts/moolah-tell 'get name of every profile' || echo "exit=$? (expected 1)"
fi
```
Expected: the real script emits the exact "error: Moolah.app not built at …/.build/Build/Products/Debug/Moolah.app" message and exits 1 when the bundle does not exist.

- [ ] **Step 5: Commit**

Run:
```bash
git commit -m "$(cat <<'EOF'
feat(automate-app): add moolah-tell AppleScript wrapper

Auto-wraps the body in tell application "<worktree-abs-path>" ... end
tell so automation targets the worktree's debug build, not the installed
/Applications/Moolah.app.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Create `moolah-open`

**Files:**
- Create: `.claude/skills/automate-app/scripts/moolah-open`

- [ ] **Step 1: Write the script**

Write `.claude/skills/automate-app/scripts/moolah-open`:

```bash
#!/usr/bin/env bash
# Open a moolah:// URL against the Moolah app built in the current worktree.
# Uses `open -a <abs-path>` so LaunchServices does not route to
# /Applications/Moolah.app.
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

- [ ] **Step 2: Make it executable and stage the executable bit**

Run:
```bash
chmod +x .claude/skills/automate-app/scripts/moolah-open
git add .claude/skills/automate-app/scripts/moolah-open
git update-index --chmod=+x .claude/skills/automate-app/scripts/moolah-open
```

- [ ] **Step 3: Verify the missing-app error path**

Run:
```bash
if [ ! -d .build/Build/Products/Debug/Moolah.app ]; then
    .claude/skills/automate-app/scripts/moolah-open 'moolah://Test' || echo "exit=$? (expected 1)"
fi
```
Expected: the script emits the same "error: Moolah.app not built at …/.build/Build/Products/Debug/Moolah.app" message and exits 1 when the bundle does not exist.

If a build is already present at `.build/Build/Products/Debug/Moolah.app`, skip this step — the verification is documented for the no-build condition.

- [ ] **Step 4: Shellcheck both wrappers**

Run:
```bash
shellcheck .claude/skills/automate-app/scripts/moolah-tell .claude/skills/automate-app/scripts/moolah-open
```
Expected: exit 0, no output. (If `shellcheck` isn't installed, note it and skip — not a blocker.)

- [ ] **Step 5: Commit**

Run:
```bash
git commit -m "$(cat <<'EOF'
feat(automate-app): add moolah-open URL-scheme wrapper

Routes moolah:// URLs through `open -a <worktree-abs-path>` so
LaunchServices targets the worktree's debug build instead of the
installed /Applications/Moolah.app.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Rewrite `SKILL.md` to use the wrappers

**Files:**
- Modify: `.claude/skills/automate-app/SKILL.md`

The existing `SKILL.md` has the following top-level sections, in order:

1. Profile Safety
2. Prerequisites
3. AppleScript Reference (Profile / Account / Transaction / Earmark / Category / Refresh and Navigation)
4. URL Scheme Reference
5. Common Test Workflows
6. Error Handling
7. Tips

This task rewrites every section from #2 onwards. #1 is unchanged.

- [ ] **Step 1: Replace the Prerequisites section**

Locate the existing section:
```markdown
## Prerequisites

The app must be running. Use `just run-mac` to build and launch, or `just run-mac-with-logs` to also capture logs.
```

Replace with:
```markdown
## Prerequisites

The app must be built and running in **this worktree**. Use `just run-mac` to build and launch, or `just run-mac-with-logs` to also capture logs.

### Why the wrappers

Do **not** use raw `osascript -e 'tell application "Moolah" to …'` or bare `open "moolah://…"` for Moolah automation. Both resolve "Moolah" through LaunchServices, which picks `/Applications/Moolah.app` (the installed release build) over the worktree's debug build. Your automation will silently read from and write to the wrong app.

Use the wrappers bundled with this skill instead:

- `.claude/skills/automate-app/scripts/moolah-tell` — AppleScript runner; auto-wraps the body in `tell application "<worktree-abs-path>" … end tell`.
- `.claude/skills/automate-app/scripts/moolah-open` — URL-scheme runner; execs `open -a <worktree-abs-path>`.

Both resolve the bundle via `git rev-parse --show-toplevel` + `/.build/Build/Products/Debug/Moolah.app`, and fail fast with `error: Moolah.app not built at <path>; run 'just run-mac' in this worktree first` if the build is missing. They never build on your behalf — run `just run-mac` yourself first.

Examples below use the short names `moolah-tell` and `moolah-open` for readability; invoke them by their full relative path from the worktree root.
```

- [ ] **Step 2: Rewrite the AppleScript Reference section**

Replace the entire `## AppleScript Reference` block (from that heading down to the start of `## URL Scheme Reference`) with:

````markdown
## AppleScript Reference

Each example uses `moolah-tell` (full path: `.claude/skills/automate-app/scripts/moolah-tell`). The wrapper adds the outer `tell application` frame.

### Profile Operations

```bash
# List all open profiles
moolah-tell 'get name of every profile'

# Get profile currency
moolah-tell 'get currency of profile "Test"'

# Count profiles
moolah-tell 'count profiles'
```

### Account Operations

```bash
# List all accounts
moolah-tell 'get name of every account of profile "Test"'

# Get account balance
moolah-tell 'get balance of account "Savings" of profile "Test"'

# Get all account names and balances
moolah-tell 'get {name, balance} of every account of profile "Test"'

# Get net worth
moolah-tell 'net worth of profile "Test"'

# Create account
moolah-tell 'tell profile "Test" to create account name "New Account" type "bank"'
# Types: bank, cc, asset, investment

# Delete account
moolah-tell 'delete account "New Account" of profile "Test"'
```

### Transaction Operations

```bash
# Create a simple expense
moolah-tell 'tell profile "Test" to create transaction with payee "Woolworths" amount -42.50 account "Everyday" category "Groceries"'

# Create with date and notes
moolah-tell 'tell profile "Test" to create transaction with payee "Rent" amount -2000.00 account "Everyday" date (date "2026-04-01") notes "April rent"'

# Create income
moolah-tell 'tell profile "Test" to create transaction with payee "Employer" amount 5000.00 account "Everyday" category "Salary"'

# List transactions (payee and amount)
moolah-tell 'get {payee, amount} of every transaction of profile "Test"'

# Get transaction details
moolah-tell 'get {payee, date, amount, transaction type} of every transaction of profile "Test"'

# Delete a transaction
moolah-tell 'delete transaction id "UUID-HERE" of profile "Test"'

# Pay a scheduled transaction
moolah-tell 'pay transaction id "UUID-HERE" of profile "Test"'
```

### Earmark Operations

```bash
# List earmarks
moolah-tell 'get {name, balance} of every earmark of profile "Test"'

# Create earmark with target
moolah-tell 'tell profile "Test" to create earmark name "Holiday" target 5000.00'

# Create earmark without target
moolah-tell 'tell profile "Test" to create earmark name "Emergency Fund"'

# Get earmark balance
moolah-tell 'get balance of earmark "Holiday" of profile "Test"'
```

### Category Operations

```bash
# List categories
moolah-tell 'get name of every category of profile "Test"'

# Create category
moolah-tell 'tell profile "Test" to create category name "Groceries"'

# Create subcategory
moolah-tell 'tell profile "Test" to create category name "Fruit" parent "Groceries"'
```

### Refresh and Navigation

```bash
# Refresh data from backend
moolah-tell 'refresh profile "Test"'

# Navigate to a specific account
moolah-tell 'navigate to account "Savings" of profile "Test"'
```

### Multi-line scripts

Pipe the body in on stdin (use `-` or omit the arg):

```bash
moolah-tell - <<'EOF'
tell profile "Test"
  set accts to {name, balance} of every account
  set cats to name of every category
  return {accts, cats}
end tell
EOF
```
````

- [ ] **Step 3: Rewrite the URL Scheme Reference section**

Replace the entire `## URL Scheme Reference` block with:

````markdown
## URL Scheme Reference

Use `moolah-open` (full path: `.claude/skills/automate-app/scripts/moolah-open`) to route the URL to the worktree build. The app opens/focuses the profile window and navigates to the destination.

```bash
# Open a profile window
moolah-open "moolah://Test"

# Navigate to a specific account
moolah-open "moolah://Test/account/ACCOUNT-UUID-HERE"

# Navigate to a specific transaction (opens in first leg's account context)
moolah-open "moolah://Test/transaction/TRANSACTION-UUID-HERE"

# Navigate to analysis with custom periods
moolah-open "moolah://Test/analysis?history=12&forecast=3"

# Navigate to reports with date range
moolah-open "moolah://Test/reports?from=2026-01-01&to=2026-03-31"

# Navigate to specific views
moolah-open "moolah://Test/categories"
moolah-open "moolah://Test/upcoming"
moolah-open "moolah://Test/earmarks"
moolah-open "moolah://Test/earmark/EARMARK-UUID-HERE"
moolah-open "moolah://Test/accounts"

# URL-encode profile names with spaces
moolah-open "moolah://My%20Finances/analysis"
```

**Profile resolution:** Tries name match (case-insensitive) first, then UUID. If the profile isn't open, a new window opens for it.
````

- [ ] **Step 4: Rewrite the Common Test Workflows section**

Replace the entire `## Common Test Workflows` block with:

````markdown
## Common Test Workflows

### Verify account balance updates after transaction

```bash
# 1. Check initial balance
moolah-tell 'get balance of account "Everyday" of profile "Test"'

# 2. Create a transaction
moolah-tell 'tell profile "Test" to create transaction with payee "Test Purchase" amount -25.00 account "Everyday"'

# 3. Verify balance changed
moolah-tell 'get balance of account "Everyday" of profile "Test"'
```

### Verify UI navigation

```bash
# Navigate to analysis view and verify visually
moolah-open "moolah://Test/analysis?history=6&forecast=3"

# Navigate to specific account
moolah-open "moolah://Test/account/ACCOUNT-UUID"
```

### Create a full test environment

```bash
moolah-tell - <<'EOF'
tell profile "AI Test"
  create account name "Checking" type "bank"
  create account name "Savings" type "bank"
  create account name "Credit Card" type "cc"
  create category name "Food"
  create category name "Transport"
  create category name "Salary"
  create earmark name "Emergency Fund" target 10000.00
  create transaction with payee "Employer" amount 5000.00 account "Checking" category "Salary"
  create transaction with payee "Groceries" amount -150.00 account "Checking" category "Food"
  create transaction with payee "Gas" amount -60.00 account "Credit Card" category "Transport"
end tell
EOF
```

### Verify data integrity after code changes

```bash
moolah-tell - <<'EOF'
tell profile "AI Test"
  set accts to {name, balance} of every account
  set cats to name of every category
  set earmarks to {name, balance} of every earmark
  return {accts, cats, earmarks}
end tell
EOF
```
````

- [ ] **Step 5: Rewrite the Error Handling section**

Replace the entire `## Error Handling` block with:

````markdown
## Error Handling

Put `try` / `on error` **inside** the body — `moolah-tell` supplies the outer `tell application`:

```bash
moolah-tell 'try
  get balance of account "Nonexistent" of profile "Test"
on error errMsg
  return "ERROR: " & errMsg
end try'
```

Common errors:
- **"Profile not found"** — profile isn't open or name is misspelled
- **"Account not found"** — account name doesn't match (matching is case-insensitive)
- **"Operation failed"** — backend error, check app logs with `run-mac-app-with-logs` skill
- **"error: Moolah.app not built at …"** — emitted by `moolah-tell` / `moolah-open` themselves; run `just run-mac` in this worktree first.
````

- [ ] **Step 6: Rewrite the Tips section**

Replace the entire `## Tips` block with:

```markdown
## Tips

- **Always use `moolah-tell` and `moolah-open`** — raw `osascript` / `open` target `/Applications/Moolah.app`, not your worktree build.
- **Use AppleScript (`moolah-tell`) for data operations** (CRUD, balance checks, queries).
- **Use the URL scheme (`moolah-open`) for navigation** (opening views, navigating to specific entities).
- **Always verify state after mutations** — read back the value you just changed.
- **Use the `run-mac-app-with-logs` skill** to capture app logs while running automation for debugging.
- **Amounts are Decimal** — expenses are negative, income is positive. Don't use `abs()`.
- **Profile must be open** — the profile needs to be open in a window for AppleScript to work with it.
```

- [ ] **Step 7: Verify the edits**

Run:
```bash
grep -n "tell application \"Moolah\"" .claude/skills/automate-app/SKILL.md && echo "FAIL: raw tell application still present" || echo "OK: no raw tell application"
grep -nE '^\s*open "moolah://' .claude/skills/automate-app/SKILL.md && echo "FAIL: bare open moolah:// still present" || echo "OK: no bare open moolah://"
grep -c "moolah-tell" .claude/skills/automate-app/SKILL.md
grep -c "moolah-open" .claude/skills/automate-app/SKILL.md
```
Expected:
- Line 1: prints `OK: no raw tell application`.
- Line 2: prints `OK: no bare open moolah://`.
- Line 3: a count ≥ 25 (the number of `moolah-tell` invocations across the rewritten sections).
- Line 4: a count ≥ 10 (URL-scheme examples).

- [ ] **Step 8: Commit**

Run:
```bash
git add .claude/skills/automate-app/SKILL.md
git commit -m "$(cat <<'EOF'
docs(automate-app): rewrite SKILL.md to use moolah-tell/moolah-open

Every AppleScript and moolah:// example now routes through the wrappers
so the skill targets the worktree's debug build instead of
/Applications/Moolah.app. Prerequisites section explains why; Tips
section warns against falling back to raw osascript / open.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Smoke-test the wrappers end to end

**Files:** None.

This is a manual verification task. Skip the steps that require a running app if `just run-mac` is not feasible in this environment; record which steps were skipped in the final report.

- [ ] **Step 1: Build and launch the worktree app**

Run:
```bash
just run-mac
```
Expected: app window opens; the dock icon is the worktree build (its path is under `.build/Build/Products/Debug/Moolah.app`, verifiable via `lsappinfo info -only bundlepath <pid>` or Activity Monitor → Open Files).

- [ ] **Step 2: Confirm `moolah-tell` reaches the worktree instance**

Run:
```bash
.claude/skills/automate-app/scripts/moolah-tell 'get name of every profile'
```
Expected: returns the profile list of the worktree app (not the release app's profile list, if it happens to be running too).

- [ ] **Step 3: Confirm `moolah-open` activates the worktree window**

Pick any profile visible in the previous step (call it `<ProfileName>`, URL-encoded if needed). Run:
```bash
.claude/skills/automate-app/scripts/moolah-open "moolah://<ProfileName>"
```
Expected: the worktree build's window for that profile comes to the foreground. No new `/Applications/Moolah.app` process is spawned (verify with `ps aux | grep Moolah.app | grep -v grep`).

- [ ] **Step 4: Confirm the missing-app error path**

Temporarily rename the build directory to trigger the error branch:
```bash
mv .build/Build/Products/Debug/Moolah.app .build/Build/Products/Debug/Moolah.app.bak
.claude/skills/automate-app/scripts/moolah-tell 'get name of every profile'; echo "exit=$?"
.claude/skills/automate-app/scripts/moolah-open "moolah://Test"; echo "exit=$?"
mv .build/Build/Products/Debug/Moolah.app.bak .build/Build/Products/Debug/Moolah.app
```
Expected: both commands print
```
error: Moolah.app not built at <abs-path>/.build/Build/Products/Debug/Moolah.app
       run 'just run-mac' in this worktree first
```
to stderr and exit 1. After the `mv` back, re-run Step 2 to confirm the happy path again.

- [ ] **Step 5: No commit**

Smoke tests are verification only — no files change. If anything fails, fix the offending script or doc section in place and amend the most recent relevant commit. If everything passes, report completion.

---

## Self-review checklist (author)

- **Spec coverage:** every design-doc section has a task.
  - Problem / rationale → captured in commit messages and `SKILL.md` Prerequisites rewrite (Task 3 Step 1).
  - `moolah-tell` script → Task 1.
  - `moolah-open` script → Task 2.
  - Shared invariants (path resolution, fail-fast, no auto-build, no auto-launch) → Tasks 1/2 Steps 2 and 4 verify.
  - Invocation convention (full relative path) → Task 3 Step 1 documents.
  - SKILL.md rewrites (6 sections) → Task 3 Steps 1–6.
  - Verification list from the spec → Task 4 Steps 1–4.
  - Out-of-scope assertions → no task touches `project.yml`, `just` targets, or Swift code.
- **Placeholders:** none. Every step has exact commands, full script content, full replacement markdown, and expected output.
- **Type consistency:** script names `moolah-tell` / `moolah-open` are used identically in every task, spec, and commit message. Paths `.claude/skills/automate-app/scripts/…` and `.build/Build/Products/Debug/Moolah.app` match the spec.
