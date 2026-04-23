---
name: automate-app
description: Use when driving the running Moolah macOS app from the terminal — verifying a UI change end-to-end, inspecting account/transaction/earmark state, creating or tearing down a test profile's data, or opening the app to a specific view. Also use when a task mentions AppleScript (`osascript`) or the `moolah://` URL scheme.
---

# Automating the Moolah App

Drive the running Moolah macOS app via AppleScript (`osascript`) for data operations and `moolah://` URLs for navigation.

## CRITICAL: Profile Safety

**Before taking ANY automation action, you MUST confirm with the user which profile to use.** Never assume a profile. Never default to the first profile. Ask explicitly, every time, even if there's only one profile open. This is real financial data — testing operations must not be performed on important profiles.

**Recommended first step for testing:** Suggest creating a dedicated test profile via the app's UI or AppleScript.

## Prerequisites

The app must be built and running in **this worktree**. Use `just run-mac` to build and launch, or `just run-mac-with-logs` to also capture logs.

### Why the wrappers

Do **not** use raw `osascript -e 'tell application "Moolah" to …'` or bare `open "moolah://…"` for Moolah automation. Both resolve "Moolah" through LaunchServices, which picks `/Applications/Moolah.app` (the installed release build) over the worktree's debug build. Your automation will silently read from and write to the wrong app.

Use the wrappers bundled with this skill instead:

- `.claude/skills/automate-app/scripts/moolah-tell` — AppleScript runner; auto-wraps the body in `tell application "<worktree-abs-path>" … end tell`.
- `.claude/skills/automate-app/scripts/moolah-open` — URL-scheme runner; execs `open -a <worktree-abs-path>`.

Both resolve the bundle via `git rev-parse --show-toplevel` + `/.build/Build/Products/Debug/Moolah.app`, and fail fast with `error: Moolah.app not built at <path>; run 'just run-mac' in this worktree first` if the build is missing. They never build on your behalf — run `just run-mac` yourself first.

Examples below use the short names `moolah-tell` and `moolah-open` for readability. When copy-pasting, prefix each with the full relative path from the worktree root:

```bash
.claude/skills/automate-app/scripts/moolah-tell 'get name of every profile'
.claude/skills/automate-app/scripts/moolah-open "moolah://Test"
```

Or add the scripts dir to `$PATH` for the session:

```bash
export PATH="$PWD/.claude/skills/automate-app/scripts:$PATH"
```

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
- **`error: Moolah.app not built at <path>`** followed by **`run 'just run-mac' in this worktree first`** (two stderr lines) — emitted by `moolah-tell` / `moolah-open` themselves when the worktree's debug build is missing; run `just run-mac` and retry.
- **`error: moolah-tell must be run from inside a Moolah worktree`** or **`error: moolah-open must be run from inside a Moolah worktree`** — you're invoking the wrapper from outside any git repo; `cd` into the worktree first.

## Tips

- **Always use `moolah-tell` and `moolah-open`** — raw `osascript` / `open` target `/Applications/Moolah.app`, not your worktree build.
- **Use AppleScript (`moolah-tell`) for data operations** (CRUD, balance checks, queries).
- **Use the URL scheme (`moolah-open`) for navigation** (opening views, navigating to specific entities).
- **Always verify state after mutations** — read back the value you just changed.
- **Use the `run-mac-app-with-logs` skill** to capture app logs while running automation for debugging.
- **Amounts are Decimal** — expenses are negative, income is positive. Don't use `abs()`.
- **Profile must be open** — the profile needs to be open in a window for AppleScript to work with it.
