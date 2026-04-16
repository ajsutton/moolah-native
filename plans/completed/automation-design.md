# Comprehensive App Automation Design

## Overview

Add three automation surfaces to Moolah — AppleScript, App Intents/Shortcuts, and URL scheme deep links — built on a shared operations layer. Plus an AI skill to help agents drive the app effectively.

### Goals

1. **User automation:** Enable users to build custom workflows, shortcuts, and scripts for fetching data (balances, reports) and adding data (transactions, investment values).
2. **AI testing:** Enable AI agents to trigger as much app functionality as possible — navigating views, creating/editing/deleting data, switching profiles, generating reports.

### Design Principles

- **Mac-native first:** AppleScript scripting dictionary is the power-user interface. Shortcuts and Siri provide discoverability and iOS support.
- **Shared core:** All three surfaces are thin wrappers around a single `AutomationService` layer. No duplicated logic.
- **Full CRUD from day one:** All major entities support create, read, update, and delete. This is a local app with the user's own data — no need to gate destructive operations.
- **Profile safety:** Profiles must be explicitly targeted. The AI skill requires confirmation of which profile to use before any action.

---

## Architecture

### Directory Structure

```
Automation/
  AutomationService.swift        — Shared operation layer
  ProfileSessionManager.swift    — Tracks and manages open ProfileSessions
  AppleScript/
    ScriptingBridge.swift         — NSApplication scripting delegate + command handlers
    Moolah.sdef                  — Scripting dictionary
  Intents/
    Entities/
      ProfileEntity.swift        — Profile entity + query
      AccountEntity.swift        — Account entity + query
      EarmarkEntity.swift        — Earmark entity + query
      CategoryEntity.swift       — Category entity + query
    GetNetWorthIntent.swift
    GetAccountBalanceIntent.swift
    ListAccountsIntent.swift
    CreateTransactionIntent.swift
    GetRecentTransactionsIntent.swift
    CreateEarmarkIntent.swift
    GetEarmarkBalanceIntent.swift
    AddInvestmentValueIntent.swift
    GetExpenseBreakdownIntent.swift
    GetMonthlySummaryIntent.swift
    OpenAccountIntent.swift
    RefreshDataIntent.swift
    MoolahShortcuts.swift        — AppShortcutsProvider
  URLScheme/
    URLSchemeHandler.swift       — Parses moolah:// URLs, navigates UI
```

### Shared Operations Layer

`AutomationService` is a `@MainActor` class that exposes every automatable operation as an async method. It depends on `ProfileSessionManager` to resolve profile targets into active `ProfileSession` instances.

`ProfileSessionManager` wraps the app's existing window-per-profile model. It tracks open `ProfileSession` instances by profile ID and can open a new profile (creating a window on macOS). Initially, profiles must be open (windowed) to be scripted. The design supports expanding to headless sessions later without API changes.

#### AutomationService Operations

**Profiles:**
- `listProfiles() -> [Profile]`
- `openProfile(id:) -> ProfileSession`
- `createProfile(label:currency:) -> Profile`
- `deleteProfile(id:)`

**Accounts:**
- `listAccounts(profile:) -> [Account]`
- `getAccount(profile:id:) -> Account`
- `createAccount(name:type:currency:) -> Account`
- `updateAccount(id:...) -> Account`
- `deleteAccount(id:)`
- `getNetWorth(profile:) -> MonetaryAmount`

**Transactions:**
- `listTransactions(profile:account:filter:) -> [Transaction]`
- `getTransaction(profile:id:) -> Transaction`
- `createTransaction(profile:payee:date:legs:) -> Transaction`
- `updateTransaction(profile:id:...) -> Transaction`
- `deleteTransaction(profile:id:)`
- `payScheduledTransaction(profile:id:) -> PayResult`

**Earmarks:**
- `listEarmarks(profile:) -> [Earmark]`
- `createEarmark(profile:name:targetAmount:savingsTargetDate:) -> Earmark`
- `updateEarmark(profile:id:...) -> Earmark`
- `deleteEarmark(profile:id:)`

**Categories:**
- `listCategories(profile:) -> [Category]`
- `createCategory(profile:name:parent:) -> Category`
- `updateCategory(profile:id:...) -> Category`
- `deleteCategory(profile:id:)`

**Investments:**
- `updateInvestmentValue(profile:account:value:) -> InvestmentValue`
- `getPositions(profile:account:) -> [Position]`

**Analysis:**
- `getMonthlyData(profile:history:forecast:) -> MonthlyAnalysis`
- `getExpenseBreakdown(profile:period:) -> ExpenseBreakdown`

**Navigation:**
- `navigate(profile:to:) -> Void` — opens window and navigates to a specific view

---

## AppleScript Scripting Dictionary (SDEF)

### Object Model

```
application "Moolah"
  ├── profiles (collection)
  │   └── profile
  │       ├── properties: id, name, currency, financial year start month
  │       ├── accounts (collection)
  │       │   └── account
  │       │       ├── properties: id, name, type, balance, investment value, is hidden
  │       │       ├── transactions (collection, filtered to this account)
  │       │       └── positions (collection, for investment accounts)
  │       ├── transactions (collection, all transactions in profile)
  │       │   └── transaction
  │       │       ├── properties: id, date, payee, notes, type, is scheduled
  │       │       └── legs (collection)
  │       │           └── leg: account, amount, category, earmark, type
  │       ├── earmarks (collection)
  │       │   └── earmark: id, name, balance, target amount, savings target date
  │       └── categories (collection)
  │           └── category: id, name, parent category
  │
  ├── commands:
  │   ├── create profile / account / transaction / earmark / category
  │   ├── delete profile / account / transaction / earmark / category
  │   ├── pay (scheduled transaction)
  │   ├── refresh (sync data)
  │   ├── navigate to (account/earmark/analysis/reports/categories)
  │   ├── net worth of (profile)
  │   ├── monthly summary of (profile) for (date range)
  │   └── expense breakdown of (profile) for (date range)
```

### Suites

**Standard Suite** (inherited): `open`, `close`, `quit`, `count`

**Moolah Suite**: All app-specific objects and commands listed above.

### Example Usage

```applescript
tell application "Moolah"
  -- List all profiles
  get name of every profile

  -- Get net worth
  get net worth of profile "Personal"

  -- Create a transaction
  tell profile "Personal"
    create transaction with payee "Woolworths" ¬
      amount -42.50 account "Everyday" ¬
      category "Groceries" date (current date)
  end tell

  -- Read balances
  tell profile "Personal"
    get balance of account "Savings"
    get balance of every account where type is bank
  end tell

  -- Navigate to a view
  navigate to account "Savings" of profile "Personal"

  -- Multi-leg transaction (transfer)
  tell profile "Personal"
    create transaction with payee "Transfer" ¬
      type transfer ¬
      legs { ¬
        {account: "Everyday", amount: -500.00}, ¬
        {account: "Savings", amount: 500.00} ¬
      } date (current date)
  end tell
end tell
```

The `create transaction` command supports two forms:
- **Simple (single leg):** `amount`, `account`, `category` as direct parameters. Covers the common case of a single expense/income.
- **Multi-leg:** A `legs` list for transfers and split transactions. Each leg specifies `account`, `amount`, and optionally `category`, `earmark`, and `type`.

### Implementation

The app registers as scriptable via `NSApplication` scripting support. A scripting delegate class translates AppleScript object specifiers into `AutomationService` calls. Each SDEF class (profile, account, transaction, etc.) maps to a lightweight `NSScriptCommand` subclass.

---

## App Intents (Shortcuts)

### Initial Intent Set (~12 intents)

| Intent | Parameters | Returns |
|--------|-----------|---------|
| `GetNetWorth` | profile | formatted amount |
| `GetAccountBalance` | profile, account | formatted amount |
| `ListAccounts` | profile, type filter (optional) | account names + balances |
| `CreateTransaction` | profile, payee, amount, account, category (optional), date (optional) | created transaction |
| `GetRecentTransactions` | profile, account (optional), count | transaction summaries |
| `CreateEarmark` | profile, name, target amount (optional) | created earmark |
| `GetEarmarkBalance` | profile, earmark | formatted amount |
| `AddInvestmentValue` | profile, account, value | confirmation |
| `GetExpenseBreakdown` | profile, period | category totals |
| `GetMonthlySummary` | profile, month/year | income, expenses, net |
| `OpenAccount` | profile, account | navigates UI |
| `RefreshData` | profile (optional) | confirmation |

### Entity Queries

Shortcuts resolves parameters by name using `EntityQuery`:

- `ProfileEntity` + `ProfileQuery` — find profiles by name
- `AccountEntity` + `AccountQuery` — find accounts by name within a profile
- `EarmarkEntity` + `EarmarkQuery` — find earmarks by name within a profile
- `CategoryEntity` + `CategoryQuery` — find categories by name within a profile

### AppShortcutsProvider

Starter shortcuts that appear in the Shortcuts gallery:

- "What's my net worth?" -> `GetNetWorth`
- "Add a transaction" -> `CreateTransaction`
- "Show my balances" -> `ListAccounts`

### Siri Phrases (up to 10)

1. "What's my net worth in Moolah?"
2. "Show my balances in Moolah"
3. "Add a transaction in Moolah"
4. "What's my *account* balance in Moolah?"
5. "How much is in *earmark* in Moolah?"
6. "What did I spend this month in Moolah?"
7. "Show my recent transactions in Moolah"

### Expansion Strategy

Each new intent is a thin wrapper over `AutomationService`. As users request more Shortcuts actions, adding them is trivial — define the intent, wire it to the existing service method, and optionally register a Siri phrase.

---

## URL Scheme

Navigation-focused deep links using the format `moolah://profile-name/destination/id`.

### URL Patterns

| URL | Action |
|-----|--------|
| `moolah://Personal` | Open/focus the Personal profile window |
| `moolah://Personal/accounts` | Navigate to account list |
| `moolah://Personal/account/{uuid}` | Navigate to specific account |
| `moolah://Personal/transaction/{uuid}` | Open transaction detail (in first leg's account context) |
| `moolah://Personal/earmarks` | Navigate to earmarks list |
| `moolah://Personal/earmark/{uuid}` | Navigate to specific earmark |
| `moolah://Personal/analysis` | Navigate to analysis view |
| `moolah://Personal/analysis?history=12&forecast=3` | Analysis with custom periods |
| `moolah://Personal/reports` | Navigate to reports view |
| `moolah://Personal/reports?from=2026-01-01&to=2026-03-31` | Reports with date range |
| `moolah://Personal/categories` | Navigate to categories view |
| `moolah://Personal/upcoming` | Navigate to upcoming transactions |

### Query Parameters

| View | Parameter | Type | Description |
|------|-----------|------|-------------|
| `/reports` | `from` | ISO 8601 date | Report start date |
| `/reports` | `to` | ISO 8601 date | Report end date |
| `/analysis` | `history` | integer | Months of history |
| `/analysis` | `forecast` | integer | Months to forecast |

Parameters are optional; views use their current/default values when omitted.

### Behaviour

- Profile name is URL-encoded in the path (e.g., `moolah://My%20Finances/analysis`)
- **Profile resolution:** Try matching by name first. If ambiguous or not found, try interpreting as a UUID. This keeps simple URLs readable while supporting programmatic use.
- If the profile isn't open, the app opens it in a new window first, then navigates
- If the profile is already open, the existing window comes to front and navigates
- Opening a specific transaction navigates to it within the first leg's account context
- Invalid profile names or entity IDs show a brief alert
- UUIDs are matched case-insensitively

### Implementation

A single `onOpenURL` modifier on the root scene parses the URL, resolves the profile via `ProfileSessionManager`, and sets the navigation state on the relevant `ContentView`. The navigation state change uses the same codepath the sidebar already uses — just driven by URL instead of click.

---

## AI Automation Skill

A skill at `.claude/skills/automate-app.md` that teaches AI agents how to drive Moolah.

### Trigger Conditions

The skill fires when:
- The user asks to test something in the running app
- The user asks to create test data
- The user asks to navigate to or verify a specific view
- Code changes touch UI that could be verified via automation

### Skill Contents

- **Safety requirement (hard gate):** Before taking any action via automation, the AI MUST confirm with the user which profile to use. Never assume a profile. Never default to the first profile. This is real financial data — testing operations must not be performed on important profiles. The skill should suggest creating a dedicated test profile as a first step when the intent is testing.
- **AppleScript recipes:** Copy-pasteable `osascript` examples for every major operation (listing/switching profiles, CRUD for all entities, reading balances/net worth/analysis, paying scheduled transactions, refreshing/syncing).
- **URL scheme reference:** Every URL pattern with examples for navigation and query parameters.
- **Common test workflows:** Multi-step recipes like "create a test account, add transactions, verify balance" and "navigate to analysis, verify it loads."
- **Error handling:** What AppleScript returns on failure, how to check for errors.
- **Best practices:** Use AppleScript for data operations, URL scheme for navigation. Always verify state after mutations.

---

## Future Expansion

- **Headless ProfileSessions:** Allow automation to address profiles without opening a window. The `AutomationService` API stays the same — `ProfileSessionManager` gains the ability to create background sessions.
- **More App Intents:** Each new intent is a thin wrapper over `AutomationService`. Add as users request.
- **Export/Import via automation:** AppleScript commands to export a profile to a file or import from one.
- **Batch operations:** AppleScript support for creating multiple transactions in one command.
