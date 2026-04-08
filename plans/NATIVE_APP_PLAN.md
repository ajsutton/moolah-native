# Moolah — Native iOS/macOS App Plan

## Overview

Rebuild Moolah as a universal SwiftUI app targeting iOS 26+ and macOS 26+, producing a single binary that runs natively on both iPhone and Mac. The app is designed to support swappable backends: the initial implementation connects to the existing REST server, and the architecture is explicitly structured so a future iCloud/CloudKit backend can be substituted without touching UI or business logic.

---

## Architecture: Backend Abstraction

The app is layered such that every feature talks to **repository protocols** defined in the domain layer. No feature, store, or view ever imports a backend-specific module directly. Backends are concrete implementations of those protocols, assembled at the app's composition root and injected via SwiftUI's `@Environment`.

```
┌──────────────────────────────────────┐
│          Views / SwiftUI             │
└─────────────┬────────────────────────┘
              │ reads/writes @Observable stores
┌─────────────▼────────────────────────┐
│     Stores (@Observable)             │
│  AccountStore, TransactionStore, … │
└─────────────┬────────────────────────┘
              │ calls protocol methods
┌─────────────▼────────────────────────┐
│        Repository Protocols          │  ← Domain layer (pure Swift, no imports)
│  AccountRepository                   │
│  TransactionRepository               │
│  CategoryRepository                  │
│  EarmarkRepository                   │
│  InvestmentRepository                │
│  AnalysisRepository                  │
│  AuthProvider                        │
└──────┬────────────────────┬──────────┘
       │                    │
┌──────▼──────┐     ┌───────▼──────────┐
│   Remote    │     │  (future)        │
│   Backend   │     │  CloudKit        │
│             │     │  Backend         │
│ URLSession  │     │  CloudKit SDK    │
│ REST API    │     │  implicit auth   │
└─────────────┘     └──────────────────┘
```

### Key Rules

- **Domain models** (`Account`, `Transaction`, `Category`, etc.) are plain Swift structs in the `Domain` module. They are the only model types stores and views ever see.
- **Repository protocols** express operations in domain terms (`func fetchAccounts() async throws -> [Account]`). They know nothing about HTTP, JSON, or CloudKit.
- **Backend implementations** are in separate folders. The REST backend has its own `APIClient`, `DTOs`, and concrete repositories that translate DTOs ↔ domain models. A future CloudKit backend does the same against CloudKit records.
- **`BackendProvider` protocol** is the single injection point at the composition root. It vends all repository and auth instances. Switching backends means passing a different `BackendProvider` to `@Environment`.
- **`AuthProvider` is also a protocol.** The REST backend's implementation uses Google OAuth + session cookies. A CloudKit backend's implementation would use implicit Apple ID with no login UI. The `WelcomeView` asks `AuthProvider` whether explicit sign-in is required; it shows a sign-in button only when it is.

### Technology Choices

| Concern | Choice | Rationale |
|---|---|---|
| UI | SwiftUI | Single codebase for iOS + macOS |
| Language | Swift 6 | Strict concurrency, modern async/await |
| Testing | Swift Testing (`@Test`, `@Suite`) | First-party, expressive, parallel by default |
| Domain layer | Pure Swift structs + protocols | No framework coupling; easy to test |
| Remote networking | `URLSession` + `async/await` | No external dependencies |
| Local cache | SwiftData | Mirrors domain models locally for offline reads |
| Auth | `AuthProvider` protocol | Decouples Google OAuth from future implicit auth |
| Charts | Swift Charts | Native, zero deps |
| State | `@Observable` + `@Environment` | Replaces Pinia; native observation |
| DI / composition | `BackendProvider` via `@Environment` | Swap implementations without touching features |

### Repository Structure (new repo)

```
moolah-native/
├── App/                          # Entry point, composition root, BackendProvider assembly
│
├── Domain/                       # Pure Swift — no UIKit, SwiftUI, or backend imports
│   ├── Models/                   # Account, Transaction, Category, Earmark, …
│   └── Repositories/             # Protocol definitions only
│
├── Backends/
│   └── Remote/                   # REST API backend
│       ├── Auth/                 # RemoteAuthProvider (Google OAuth)
│       ├── APIClient/            # URLSession + request building
│       ├── DTOs/                 # Codable types matching server JSON
│       └── Repositories/         # RemoteAccountRepository, RemoteTransactionRepository, …
│
├── Features/
│   ├── Auth/                     # WelcomeView, UserMenuView, AuthStore
│   ├── Accounts/
│   ├── Transactions/
│   ├── Categories/
│   ├── Earmarks/
│   ├── Upcoming/
│   ├── Analysis/
│   ├── Reports/
│   └── Investments/
│
├── Shared/
│   ├── Components/               # Reusable views (CurrencyField, DateRangePicker, …)
│   └── Extensions/
│
└── MoolahTests/
    ├── Domain/                   # Pure logic tests (no backend)
    ├── Remote/                   # REST backend tests (URLProtocol stubs)
    ├── Features/                 # Store tests using InMemoryBackend fake
    ├── Support/
    │   ├── InMemoryBackend/      # In-memory BackendProvider for tests & Previews
    │   └── Fixtures/             # JSON fixture files
    └── UI/                       # Snapshot + XCUITest
```

**`InMemoryBackend`** is a full, non-networked implementation of every repository protocol that stores data in memory. It is used by every feature test and every SwiftUI Preview. It is **not** a mock — it has real business logic and supports CRUD, so tests exercise real store behaviour without any networking.

---

## Incremental Steps

Each step is a **vertical slice**: it adds domain types, InMemoryBackend implementation, RemoteBackend implementation, and UI together for a single feature. No step builds a backend layer that isn't yet consumed by UI — tests and Previews drive the InMemoryBackend, and the RemoteBackend is wired up at the same time so the app works end-to-end.

---

### Step 1 — Project Scaffolding & CI

**Goal:** A "Hello, Moolah" app that compiles and passes tests on both simulator targets.

#### Tasks
- Create a new Xcode project: multiplatform app, iOS 26 + macOS 26 deployment targets.
- Add Swift Testing target (`MoolahTests`).
- Create the `Domain`, `Backends/Remote`, `Features`, and `Shared` folder structure.
- Configure a minimal SwiftData `ModelContainer` (empty schema for now).
- Write a smoke test asserting the container initialises without error.
- Set up git repository with `.gitignore` for Xcode.
- Add `scripts/test.sh` that runs `xcodebuild test` for both destinations, with sandvault compatibility (see below).
- Add a CI workflow (GitHub Actions or CircleCI) that builds and tests on every push.

**`scripts/test.sh` must handle sandvault's nested-sandbox restriction.** macOS does not support recursive sandboxes; `swift` and `xcodebuild` create their own sandboxes and fail when already running inside sandvault. The script detects the `SV_SESSION_ID` environment variable and disables the inner sandbox:

```bash
#!/usr/bin/env bash
set -euo pipefail

XCODE_ARGS=(
  -scheme Moolah
  -IDEPackageSupportDisableManifestSandbox=1
  -IDEPackageSupportDisablePackageSandbox=1
  "OTHER_SWIFT_FLAGS=\$(inherited) -disable-sandbox"
)

export SWIFTPM_DISABLE_SANDBOX=1
export SWIFT_BUILD_USE_SANDBOX=0

# Destinations
IOS_DEST="platform=iOS Simulator,name=iPhone 17 Pro"
MACOS_DEST="platform=macOS"

xcodebuild test "${XCODE_ARGS[@]}" -destination "$IOS_DEST"
xcodebuild test "${XCODE_ARGS[@]}" -destination "$MACOS_DEST"
```

The same `SWIFTPM_DISABLE_SANDBOX`, `SWIFT_BUILD_USE_SANDBOX`, and `IDEPackageSupport*` flags must be set in the CI environment when running inside sandvault.

#### Definition of Done
- `scripts/test.sh` passes when run both inside and outside sandvault.
- `xcodebuild test -scheme Moolah -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` passes.
- `xcodebuild test -scheme Moolah -destination 'platform=macOS'` passes.

---

### Step 2 — Authentication

**Goal:** Users can sign in and out. The app shows their name when signed in. Establishes the backend infrastructure all later steps build on.

#### Domain types introduced
- `UserProfile` (id, givenName, familyName, pictureURL) — `Codable`, `Sendable`
- `BackendError` enum: `.unauthenticated`, `.serverError(Int)`, `.networkUnavailable`

#### Protocols introduced
- `AuthProvider`: `var requiresExplicitSignIn: Bool`, `func currentUser() async throws -> UserProfile?`, `func signIn() async throws -> UserProfile`, `func signOut() async throws`
- `BackendProvider`: `var auth: any AuthProvider { get }` *(grows a property each step)*

#### InMemoryBackend (auth only)
- `InMemoryAuthProvider`: configurable starting state (signed in with a fixture profile, or signed out); `signIn()` / `signOut()` toggle state.

#### RemoteBackend (auth only)
- `APIClient`: base URL injection, cookie session, `async throws` request → `Data`, HTTP error mapping to `BackendError`.
- `RemoteAuthProvider`: Google Sign-In SDK integration.
- `RemoteBackend: BackendProvider` (auth only for now).
- Wire `RemoteBackend` into the composition root.

#### UI
- `AuthStore` (`@Observable`): state `.loading` / `.signedOut` / `.signedIn(UserProfile)`.
- `AppRootView`: switches on auth state.
- `WelcomeView`: shows "Sign in with Google" only when `requiresExplicitSignIn == true`.
- `UserMenuView`: avatar, name, sign-out button.

#### Tests
- `AuthStore` transitions: `.loading` → `.signedIn` when `currentUser()` returns a profile.
- `AuthStore` transitions: `.loading` → `.signedOut` when `currentUser()` returns nil.
- `AuthStore` transitions: `.signedIn` → `.signedOut` on `signOut()`.
- Auth failure leaves store in `.signedOut` with error message.
- `WelcomeView` hides sign-in button when `requiresExplicitSignIn == false`.

#### Definition of Done
- Signing in shows the user's name. Signing out returns to `WelcomeView`.
- `InMemoryBackend` auth contract tests pass.

---

### Step 3 — Account List (Read-Only)

**Goal:** A signed-in user sees their accounts grouped by type in a sidebar/list, with totals.

#### Domain types introduced
- `Account` (id, name, type, balance, position, hidden) — `Codable`, `Sendable`
- `AccountType` enum matching server values

#### Protocols introduced
- `AccountRepository`: `func fetchAll() async throws -> [Account]`
- `BackendProvider` gains: `var accounts: any AccountRepository { get }`

#### InMemoryBackend
- `InMemoryAccountRepository`: stores `[UUID: Account]`; pre-seedable.

#### RemoteBackend
- `AccountDTO`: `Codable` matching server JSON.
- `RemoteAccountRepository`: GET `/accounts` → decode DTOs → map to domain models.
- Fixture JSON in `MoolahTests/Support/Fixtures/accounts.json`.

#### UI
- `AccountStore` (`@Observable`): `load()`, computed `currentAccounts`, `earmarkedTotal`, `investmentTotal`, `netWorth`.
- `SidebarView` (`NavigationSplitView`): Current Accounts, Earmarked Funds (placeholder), Investments.
- `AccountRowView`: name, balance, type icon.

#### Tests
- `AccountStore` populates from seeded accounts; subtotals correct; sorted by `position`.
- `RemoteAccountRepository` decodes fixture JSON; maps all fields.

#### Definition of Done
- Accounts display on both platforms. Subtotals accurate.

---

### Step 4 — Transaction List (Read-Only)

**Goal:** Tapping an account shows its paginated transaction list.

#### Domain types introduced
- `Transaction` (id, date, payee, amount, type, accountId, toAccountId, categoryId, earmarkId, notes, scheduled)
- `TransactionType` enum (income / expense / transfer)
- `TransactionFilter` (accountId, dateRange, scheduled) — grows each step

#### Protocols introduced
- `TransactionRepository`: `func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> [Transaction]`
- `BackendProvider` gains: `var transactions: any TransactionRepository { get }`

#### InMemoryBackend
- `InMemoryTransactionRepository`: in-memory filter + pagination.

#### RemoteBackend
- `TransactionDTO`: `Codable` matching server JSON.
- `RemoteTransactionRepository`: GET `/transactions` with query params → domain models.
- Fixture JSON.

#### UI
- `TransactionStore` (`@Observable`): paginated load, append, end-of-results detection.
- `TransactionListView`: rows with payee, date, amount (coloured by type), infinite scroll.
- `TransactionRowView`.

#### Tests
- Pagination: first page, append second page without duplicates, end-of-results.
- Filter by `accountId`.
- `RemoteTransactionRepository` decodes fixture; constructs correct URL params.

#### Definition of Done
- Large account transaction lists scroll correctly on both platforms.

---

### Step 5 — Create & Edit Transactions

**Goal:** Users can add, edit, and delete transactions.

#### Domain types introduced
- `Category` (id, name, parentId) — needed for category picker
- `Earmark` (id, name) — needed for earmark picker; full model comes in Step 8

#### Protocols introduced
- `TransactionRepository` gains: `func create(_:) async throws -> Transaction`, `func update(_:) async throws -> Transaction`, `func delete(id:) async throws`, `func fetchPayeeSuggestions(prefix:) async throws -> [String]`
- `CategoryRepository`: `func fetchAll() async throws -> [Category]`
- `BackendProvider` gains: `var categories: any CategoryRepository { get }`

#### InMemoryBackend
- Extend `InMemoryTransactionRepository` with mutations.
- `InMemoryCategoryRepository`.

#### RemoteBackend
- `RemoteCategoryRepository`: GET `/categories`.
- Extend `RemoteTransactionRepository` with POST/PUT/DELETE endpoints.
- Fixture JSON.

#### UI
- `TransactionFormView` (sheet): payee autocomplete, amount, date, type, transfer destination, category picker, notes, delete.
- `TransactionStore` gains `create`, `update`, `delete` with optimistic updates + rollback.

#### Tests
- Create → fetch → update → delete cycle.
- Optimistic rollback on error.
- Transfer creates two entries (one per account).
- Payee autocomplete from existing payees.

#### Definition of Done
- Full CRUD works end-to-end in tests via `InMemoryBackend`.

---

### Step 6 — All Transactions & Filtering

**Goal:** A global transactions view with date/category/payee/account/earmark filters.

#### Domain types extended
- `TransactionFilter` gains: `dateRange`, `categoryIds`, `payee`, `earmarkId`

#### InMemoryBackend
- Extend filter logic in `InMemoryTransactionRepository`.

#### RemoteBackend
- Extend query param construction.

#### UI
- `AllTransactionsView` (no account scoping).
- `TransactionFilterView` sheet: date range, category multi-select, payee text field, account picker, earmark picker, clear-all.
- Active filter badge.

#### Tests
- Each filter field narrows results in isolation and in combination.
- Clearing filter reloads unfiltered.

#### Definition of Done
- Filtering by every combination works.

---

### Step 7 — Category Management

**Goal:** Users can view, create, rename, merge, and delete categories.

#### Protocols introduced
- `CategoryRepository` gains: `func create(_:) async throws -> Category`, `func update(_:) async throws -> Category`, `func delete(id:withReplacement:) async throws`

#### InMemoryBackend / RemoteBackend
- Extend `InMemoryCategoryRepository` and `RemoteCategoryRepository` with mutations.

#### UI
- `CategoryStore`.
- `CategoriesView`: hierarchical tree.
- `CategoryDetailView`: rename, delete with replacement picker.

#### Tests
- Tree built from flat list with `parentId`. CRUD cycle.

#### Definition of Done
- Category tree renders with correct indentation. All CRUD tested.

---

### Step 8 — Earmarks

**Goal:** Users can view earmarks, see their transactions, and manage savings goals.

#### Domain types introduced
- `Earmark` full model (id, name, balance, saved, spent, hidden, position, savingsGoal?)
- `EarmarkBudgetItem` (categoryId, amount)

#### Protocols introduced
- `EarmarkRepository`: `fetchAll`, `create`, `update`, `fetchBudget`, `updateBudget`
- `BackendProvider` gains: `var earmarks: any EarmarkRepository { get }`

#### InMemoryBackend / RemoteBackend
- `InMemoryEarmarkRepository`, `RemoteEarmarkRepository`.

#### UI
- Earmarks section in `SidebarView`.
- `EarmarkDetailView`: Overview tab (balance, saved, spent, savings goal progress), Spending Breakdown tab.
- Transactions scoped to earmark (reuse `TransactionListView`).
- `TransactionFormView` gains earmark picker.

#### Tests
- Savings goal progress. Budget allocation. Earmark filter scopes transactions.

#### Definition of Done
- Full earmark lifecycle works and is tested.

---

### Step 9 — Upcoming / Scheduled Transactions

**Goal:** Users can view overdue and upcoming scheduled transactions and mark them paid.

#### Domain types introduced
- `Recurrence` (period: daily/weekly/monthly/yearly, every: Int)
- `Transaction` gains `recurrence` field

#### InMemoryBackend / RemoteBackend
- Update filter for `scheduled: true`.

#### UI
- `UpcomingView`: overdue highlighted in red, "Pay" action.
- `TransactionFormView` gains recurrence fields.

#### Tests
- Overdue classification. Pay action creates non-scheduled copy.

#### Definition of Done
- Overdue items visually distinct. Paying works.

---

### Step 10 — Analysis Dashboard

**Goal:** The home screen shows net-worth graph, expense breakdown, income/expense table, and upcoming summary.

#### Domain types introduced
- `DailyBalance` (date, balance, isForecast)
- `ExpenseBreakdown` (categoryId, amount, percentage)
- `MonthlyIncomeExpense` (month, income, expense)

#### Protocols introduced
- `AnalysisRepository`: `fetchDailyBalances(dateRange:)`, `fetchExpenseBreakdown(dateRange:)`, `fetchIncomeAndExpense(dateRange:)`
- `BackendProvider` gains: `var analysis: any AnalysisRepository { get }`

#### InMemoryBackend
- `InMemoryAnalysisRepository`: computes all three from in-memory transactions.

#### RemoteBackend
- `RemoteAnalysisRepository`: calls server analysis endpoints; fixture JSON.

#### UI
- `AnalysisStore`.
- `AnalysisView`: net-worth area chart, expense breakdown pie, income/expense table, upcoming widget.
- Financial-year picker + custom date range.

#### Tests
- Balances ordered by date. Forecast flagged correctly. Breakdown percentages sum to 100.

#### Definition of Done
- Dashboard renders real data on both platforms. Charts interactive.

---

### Step 11 — Reports

**Goal:** Income and expense breakdowns by category for any date range.

#### UI
- `ReportsView`: date range selector, income/expense by category tables with subcategory rows, totals.
- Reuses `AnalysisRepository`.

#### Tests
- Subcategory nesting. Totals match.

#### Definition of Done
- Reports readable on both form factors.

---

### Step 12 — Investment Tracking

**Goal:** Investment accounts show value history and allow manual value entries.

#### Domain types introduced
- `InvestmentValue` (accountId, date, value)

#### Protocols introduced
- `InvestmentRepository`: `fetchValues(accountId:page:)`, `setValue(_:)`, `deleteValue(id:)`
- `BackendProvider` gains: `var investments: any InvestmentRepository { get }`

#### InMemoryBackend / RemoteBackend
- `InMemoryInvestmentRepository`, `RemoteInvestmentRepository`.

#### UI
- `InvestmentValuesView` (inside `AccountDetailView` for investment accounts): line chart, list of entries, "Add Value" form.

#### Tests
- Pagination. Add / delete cycle.

#### Definition of Done
- Investment charts render correctly. CRUD for values works.

---

### Step 13 — Account Management (Create / Edit / Reorder)

**Goal:** Users can create, edit, and reorder accounts.

#### Protocols introduced
- `AccountRepository` gains: `func create(_:) async throws -> Account`, `func update(_:) async throws -> Account`, `func delete(id:) async throws`

#### InMemoryBackend / RemoteBackend
- Extend with mutations.

#### UI
- `CreateAccountView`, `EditAccountView`.
- Drag-and-drop reordering via `.onMove`.

#### Tests
- Create / update / delete / reorder cycle.

#### Definition of Done
- Full account CRUD with ordering works on both platforms.

---

### Step 14 — Platform Polish & Feature Parity (final)

**Goal:** Match remaining UX details; ensure both platforms feel native.

#### Tasks
- **macOS-specific:**
  - Three-column `NavigationSplitView` (sidebar / list / detail).
  - Keyboard shortcuts: ⌘N (new transaction), ⌘F (filter), ⌘, (preferences).
  - Right-click context menus on transaction rows (Edit, Delete, Pay).
  - Toolbar customisation.
- **iOS-specific:**
  - Swipe-to-delete on transaction rows.
  - Pull-to-refresh on all lists.
  - Tab bar navigation at compact width.
  - Haptic feedback on destructive actions.
- **Shared:**
  - Offline reads: SwiftData cache is populated on successful fetch; stale cache is served while network is unavailable.
  - Write queue: mutations made offline are queued and flushed when connectivity returns.
  - Empty states for all lists.
  - Accessibility: Dynamic Type, VoiceOver labels, accessibility identifiers.
  - Dark mode.
  - `String(localized:)` throughout.

**Tests:**
- Offline queue flushes in order on reconnect.
- Cache is served when repository throws `BackendError.networkUnavailable`.
- Accessibility identifiers present on key interactive elements.

#### Definition of Done
- App passes a manual feature-parity checklist against the web version.
- All tests pass on both platforms.

---

## Testing Strategy

### Layers

| Layer | Tool | What it tests |
|---|---|---|
| Domain unit | Swift Testing | Model logic, filter logic, `InMemoryBackend` contract |
| Remote unit | Swift Testing + `URLProtocol` stub | DTO decoding, request construction, error mapping |
| Feature unit | Swift Testing + `InMemoryBackend` | Store state transitions, optimistic updates, pagination |
| UI snapshot | `XCTest` + `swift-snapshot-testing` | Key views don't regress visually |
| End-to-end | `XCUITest` | Critical paths: sign in, add transaction, view dashboard |

### Conventions

- Test files are written **before** implementation files (TDD).
- Every repository protocol has a shared **contract test suite** that both `InMemoryBackend` and `RemoteBackend` must pass. This guarantees substitutability.
- **Before implementing any `InMemoryBackend` method**, read the corresponding route/controller in `../moolah-server/src/` to verify exact compatibility: filtering semantics, sort order, pagination contract, and computed values must match the server precisely.
- `InMemoryBackend` is used in all feature tests and all SwiftUI Previews.
- Fixture JSON files for every API response live in `MoolahTests/Support/Fixtures/`.
- Tests must pass in parallel.
- CI enforces ≥ 80% line coverage via `xcresult`.

---

## Dependency Policy

- No external dependencies for core logic (networking, state, persistence, domain).
- Allowed Swift Packages:
  - `google-signin-ios` — `RemoteAuthProvider` only; never imported outside `Backends/Remote/`.
  - `swift-snapshot-testing` — test target only.
- No third-party chart, layout, or utility libraries.

---

## Out of Scope (this plan)

- iCloud / CloudKit backend implementation.
- Importing data from bank feeds / Plaid.
- Widget / Lock Screen / Watch extensions.
- Server-side code changes.
