---
name: automate-app
description: Use when you need to interact with the running Moolah app — testing UI changes, verifying data, creating test fixtures, or navigating to specific views via AppleScript or URL scheme
---

# Automating the Moolah App

Drive the running Moolah macOS app via AppleScript (`osascript`) for data operations and `moolah://` URLs for navigation.

## CRITICAL: Profile Safety

**Before taking ANY automation action, you MUST confirm with the user which profile to use.** Never assume a profile. Never default to the first profile. Ask explicitly, every time, even if there's only one profile open. This is real financial data — testing operations must not be performed on important profiles.

**Recommended first step for testing:** Suggest creating a dedicated test profile via the app's UI or AppleScript.

## Prerequisites

The app must be running. Use `just run-mac` to build and launch, or `just run-mac-with-logs` to also capture logs.

## AppleScript Reference

All commands use `osascript -e '...'` from the terminal. The app must be running and the target profile must be open in a window.

### Profile Operations

```bash
# List all open profiles
osascript -e 'tell application "Moolah" to get name of every profile'

# Get profile currency
osascript -e 'tell application "Moolah" to get currency of profile "Test"'

# Count profiles
osascript -e 'tell application "Moolah" to count profiles'
```

### Account Operations

```bash
# List all accounts
osascript -e 'tell application "Moolah" to get name of every account of profile "Test"'

# Get account balance
osascript -e 'tell application "Moolah" to get balance of account "Savings" of profile "Test"'

# Get all account names and balances
osascript -e 'tell application "Moolah" to get {name, balance} of every account of profile "Test"'

# Get net worth
osascript -e 'tell application "Moolah" to net worth of profile "Test"'

# Create account
osascript -e 'tell application "Moolah" to tell profile "Test" to create account name "New Account" type "bank"'
# Types: bank, cc, asset, investment

# Delete account
osascript -e 'tell application "Moolah" to delete account "New Account" of profile "Test"'
```

### Transaction Operations

```bash
# Create a simple expense
osascript -e 'tell application "Moolah" to tell profile "Test" to create transaction with payee "Woolworths" amount -42.50 account "Everyday" category "Groceries"'

# Create with date and notes
osascript -e 'tell application "Moolah" to tell profile "Test" to create transaction with payee "Rent" amount -2000.00 account "Everyday" date (date "2026-04-01") notes "April rent"'

# Create income
osascript -e 'tell application "Moolah" to tell profile "Test" to create transaction with payee "Employer" amount 5000.00 account "Everyday" category "Salary"'

# List transactions (payee and amount)
osascript -e 'tell application "Moolah" to get {payee, amount} of every transaction of profile "Test"'

# Get transaction details
osascript -e 'tell application "Moolah" to get {payee, date, amount, transaction type} of every transaction of profile "Test"'

# Delete a transaction
osascript -e 'tell application "Moolah" to delete transaction id "UUID-HERE" of profile "Test"'

# Pay a scheduled transaction
osascript -e 'tell application "Moolah" to pay transaction id "UUID-HERE" of profile "Test"'
```

### Earmark Operations

```bash
# List earmarks
osascript -e 'tell application "Moolah" to get {name, balance} of every earmark of profile "Test"'

# Create earmark with target
osascript -e 'tell application "Moolah" to tell profile "Test" to create earmark name "Holiday" target 5000.00'

# Create earmark without target
osascript -e 'tell application "Moolah" to tell profile "Test" to create earmark name "Emergency Fund"'

# Get earmark balance
osascript -e 'tell application "Moolah" to get balance of earmark "Holiday" of profile "Test"'
```

### Category Operations

```bash
# List categories
osascript -e 'tell application "Moolah" to get name of every category of profile "Test"'

# Create category
osascript -e 'tell application "Moolah" to tell profile "Test" to create category name "Groceries"'

# Create subcategory
osascript -e 'tell application "Moolah" to tell profile "Test" to create category name "Fruit" parent "Groceries"'
```

### Refresh and Navigation

```bash
# Refresh data from backend
osascript -e 'tell application "Moolah" to refresh profile "Test"'

# Navigate to a specific account
osascript -e 'tell application "Moolah" to navigate to account "Savings" of profile "Test"'
```

## URL Scheme Reference

Use `open` command to trigger navigation. The app opens/focuses the profile window and navigates to the destination.

```bash
# Open a profile window
open "moolah://Test"

# Navigate to a specific account
open "moolah://Test/account/ACCOUNT-UUID-HERE"

# Navigate to a specific transaction (opens in first leg's account context)
open "moolah://Test/transaction/TRANSACTION-UUID-HERE"

# Navigate to analysis with custom periods
open "moolah://Test/analysis?history=12&forecast=3"

# Navigate to reports with date range
open "moolah://Test/reports?from=2026-01-01&to=2026-03-31"

# Navigate to specific views
open "moolah://Test/categories"
open "moolah://Test/upcoming"
open "moolah://Test/earmarks"
open "moolah://Test/earmark/EARMARK-UUID-HERE"
open "moolah://Test/accounts"

# URL-encode profile names with spaces
open "moolah://My%20Finances/analysis"
```

**Profile resolution:** Tries name match (case-insensitive) first, then UUID. If the profile isn't open, a new window opens for it.

## Common Test Workflows

### Verify account balance updates after transaction

```bash
# 1. Check initial balance
osascript -e 'tell application "Moolah" to get balance of account "Everyday" of profile "Test"'

# 2. Create a transaction
osascript -e 'tell application "Moolah" to tell profile "Test" to create transaction with payee "Test Purchase" amount -25.00 account "Everyday"'

# 3. Verify balance changed
osascript -e 'tell application "Moolah" to get balance of account "Everyday" of profile "Test"'
```

### Verify UI navigation

```bash
# Navigate to analysis view and verify visually
open "moolah://Test/analysis?history=6&forecast=3"

# Navigate to specific account
open "moolah://Test/account/ACCOUNT-UUID"
```

### Create a full test environment

```bash
osascript -e '
tell application "Moolah"
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
end tell
'
```

### Verify data integrity after code changes

```bash
# Get a snapshot of all state
osascript -e '
tell application "Moolah"
  tell profile "AI Test"
    set accts to {name, balance} of every account
    set cats to name of every category
    set earmarks to {name, balance} of every earmark
    return {accts, cats, earmarks}
  end tell
end tell
'
```

## Error Handling

```bash
# Wrap in try block to capture errors
osascript -e '
try
  tell application "Moolah" to get balance of account "Nonexistent" of profile "Test"
on error errMsg
  return "ERROR: " & errMsg
end try
'
```

Common errors:
- **"Profile not found"** — profile isn't open or name is misspelled
- **"Account not found"** — account name doesn't match (matching is case-insensitive)
- **"Operation failed"** — backend error, check app logs with `run-mac-app-with-logs` skill

## Tips

- **Use AppleScript for data operations** (CRUD, balance checks, queries)
- **Use URL scheme for navigation** (opening views, navigating to specific entities)
- **Always verify state after mutations** — read back the value you just changed
- **Use `run-mac-app-with-logs` skill** to capture app logs while running automation for debugging
- **Amounts are Decimal** — expenses are negative, income is positive. Don't use `abs()`.
- **Profile must be open** — the profile needs to be open in a window for AppleScript to work with it
