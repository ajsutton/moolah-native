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

Each step produces a runnable app that builds on the last. Steps are sized to be completable independently and deliver tangible value on their own.

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

### Step 2 — Domain Models, Repository Protocols & InMemoryBackend

**Goal:** The entire domain vocabulary exists as pure Swift types with no backend coupling. A fully functional in-memory backend is available for all future tests and Previews.

#### Tasks

**Domain models** (plain structs, `Identifiable`, `Equatable`, `Sendable`):
- `Account` (id, name, type, balance, position, hidden)
- `Transaction` (id, date, payee, amount, type, accountId, toAccountId, categoryId, earmarkId, notes, recurrence, scheduled)
- `Category` (id, name, parentId)
- `Earmark` (id, name, balance, saved, spent, hidden, position, savingsGoal?)
- `InvestmentValue` (accountId, date, value)
- `DailyBalance` (date, balance, isForecast)
- `ExpenseBreakdown` (categoryId, amount, percentage)
- `MonthlyIncomeExpense` (month, income, expense)
- `UserProfile` (id, givenName, familyName, pictureURL)
- `TransactionFilter` (dateRange, categoryIds, payee, accountId, earmarkId, scheduled)
- `Recurrence` (period: daily/weekly/monthly/yearly, every: Int)

**Repository protocols** (in `Domain/Repositories/`):
- `AuthProvider`: `func currentUser() async throws -> UserProfile?`, `func signIn() async throws -> UserProfile`, `func signOut() async throws`
- `AccountRepository`: fetch all, create, update, delete
- `TransactionRepository`: fetch (with filter + pagination), create, update, delete, fetchPayeeSuggestions
- `CategoryRepository`: fetch all, create, update, delete (withReplacement:)
- `EarmarkRepository`: fetch all, create, update, fetchBudget, updateBudget
- `InvestmentRepository`: fetchValues (paginated), setValue, deleteValue
- `AnalysisRepository`: fetchDailyBalances, fetchExpenseBreakdown, fetchIncomeAndExpense

**`BackendProvider` protocol** (in `Domain/`):
```swift
protocol BackendProvider {
    var auth: any AuthProvider { get }
    var accounts: any AccountRepository { get }
    var transactions: any TransactionRepository { get }
    var categories: any CategoryRepository { get }
    var earmarks: any EarmarkRepository { get }
    var investments: any InvestmentRepository { get }
    var analysis: any AnalysisRepository { get }
}
```

**`InMemoryBackend`** (in `MoolahTests/Support/InMemoryBackend/`):
- Implements `BackendProvider` + all protocols using `[ID: Model]` dictionaries.
- Supports pre-seeding with fixture data.
- `TransactionRepository.fetch` applies filter + pagination in memory.
- `AnalysisRepository` computes breakdowns from in-memory transactions.

**Tests:**
- Every domain model encodes/decodes round-trips via `Codable` (for future persistence).
- `InMemoryBackend` CRUD operations behave correctly (create → fetch → update → delete cycle).
- Filter logic: each `TransactionFilter` field is tested in isolation and in combination.
- Pagination: returns correct page slices and stops at the final page.

#### Definition of Done
- All domain types exist with no backend imports.
- `InMemoryBackend` passes all repository contract tests.
- No UI changes.

---

### Step 3 — Remote Backend (REST API Implementation)

**Goal:** A concrete `RemoteBackend` that satisfies every repository protocol by talking to the existing REST server.

#### Tasks
- Implement `APIClient` (internal to `Backends/Remote/`) using `URLSession`:
  - Base URL configuration (injected, not hard-coded).
  - Cookie-based session management.
  - `async throws` request method returning `Data`.
  - HTTP error mapping: 401 → `BackendError.unauthenticated`, 5xx → `BackendError.serverError(Int)`, network failure → `BackendError.networkUnavailable`.
- Define all `Codable` DTO types matching server JSON (in `Backends/Remote/DTOs/`).
- Implement `RemoteAuthProvider` (Google Sign-In SDK).
- Implement each `Remote*Repository`, translating DTOs ↔ domain models.
- Implement `RemoteBackend: BackendProvider`.
- Register `RemoteBackend` in the app's composition root (`App/`).

**Tests** (using `URLProtocol` stubs — no live network):
- Each repository method constructs the correct URL, method, and request body.
- Each repository method decodes fixture JSON into the correct domain model.
- Each error case (`401`, `500`, network failure) surfaces as the correct `BackendError`.
- DTO ↔ domain model translation is tested for every field, including optional fields and edge cases.

#### Definition of Done
- All API model types decode correctly from fixture JSON.
- All error cases are covered by tests.
- No UI changes; `RemoteBackend` is wired up but not yet exercised by views.

---

### Step 4 — Authentication

**Goal:** Users can sign in (via `AuthProvider`) and the app shows their name. Sign-out works. The sign-in UI is only shown when the active backend requires it.

#### Tasks
- Implement `AuthStore` (`@Observable`):
  - State: `.loading`, `.signedOut`, `.signedIn(UserProfile)`.
  - On launch: calls `auth.currentUser()` to restore session.
  - `signIn()` / `signOut()` delegate to `AuthProvider`.
- Build `WelcomeView`:
  - Asks `AuthProvider` whether explicit sign-in is required (`var requiresExplicitSignIn: Bool`).
  - Shows "Sign in with Google" button only when required (REST backend: yes; future CloudKit backend: no).
- Build `UserMenuView` (avatar + name + sign-out).
- Implement `AppRootView` switching on auth state.

**Tests** (using `InMemoryBackend`'s auth provider):
- `AuthStore` transitions: `.loading` → `.signedIn` when `currentUser()` returns a profile.
- `AuthStore` transitions: `.loading` → `.signedOut` when `currentUser()` returns nil.
- `AuthStore` transitions: `.signedIn` → `.signedOut` on `signOut()`.
- Auth failure (`BackendError.networkUnavailable`) leaves store in `.signedOut` with error message.
- `WelcomeView` hides sign-in button when `requiresExplicitSignIn == false`.

#### Definition of Done
- Signing in shows the user's name.
- Signing out returns to `WelcomeView`.
- Tests cover all `AuthStore` transitions using `InMemoryBackend`.

---

### Step 5 — Account List (Read-Only)

**Goal:** A signed-in user sees their accounts grouped by type in a sidebar/list, with totals.

#### Tasks
- Implement `AccountStore` (`@Observable`) using `AccountRepository`:
  - `func load() async throws`
  - Computed: `currentAccounts`, `earmarkedTotal`, `investmentTotal`, `netWorth`.
- Define SwiftData `AccountCache` for offline reads.
- Build `SidebarView` (`NavigationSplitView`):
  - Current Accounts section (bank + credit card) with subtotal.
  - Earmarked Funds placeholder.
  - Investments section with net-worth total.
- Build `AccountRowView` (name, balance, type icon, color).
- Handle loading and error states (skeleton / error banner).

**Tests** (using `InMemoryBackend`):
- `AccountStore` populates correctly from seeded accounts.
- Correct subtotals computed for each section.
- Store exposes `.error` state on repository failure.
- Accounts sorted by `position`.

#### Definition of Done
- Accounts display on both iPhone (list) and Mac (sidebar).
- Subtotals are accurate.
- Tests pass using `InMemoryBackend`.

---

### Step 6 — Transaction List (Read-Only)

**Goal:** Tapping an account shows its paginated transaction list with running balance.

#### Tasks
- Implement `TransactionStore` (`@Observable`) using `TransactionRepository`:
  - `func load(filter: TransactionFilter, page: Int) async throws`
  - Appends pages; deduplicates by id.
  - Detects end-of-results when page returns fewer rows than `pageSize`.
- Build `TransactionListView`:
  - Rows: payee, date, amount (coloured by type), running balance.
  - Infinite scroll triggering next page load.
- Build `TransactionRowView`.

**Tests** (using `InMemoryBackend`):
- First-page load populates store correctly.
- Appending second page does not duplicate rows.
- Transfer transactions show correct sign on each side.
- End-of-results detection.
- Empty state shown when no transactions.

#### Definition of Done
- Large accounts scroll without duplicate entries on both platforms.

---

### Step 7 — Create & Edit Transactions

**Goal:** Users can add, edit, and delete transactions.

#### Tasks
- Build `TransactionFormView` (sheet / detail panel):
  - Payee field with autocomplete (via `TransactionRepository.fetchPayeeSuggestions`).
  - Amount input.
  - Date picker.
  - Transaction type segmented control (Income / Expense / Transfer).
  - Transfer destination account picker.
  - Category picker (flat list for now).
  - Notes field.
  - Delete button with confirmation.
- `TransactionStore` mutations: `create`, `update`, `delete` with optimistic updates and rollback on error.

**Tests** (using `InMemoryBackend`):
- Creating a transaction adds it to the repository and to the store.
- Editing updates the repository and the store.
- Deleting removes from repository and store.
- Optimistic rollback: store reverts when repository throws.
- Transfer creates two entries (one per account).
- Payee autocomplete returns suggestions from existing transaction payees.

#### Definition of Done
- Full CRUD cycle works end-to-end on both platforms via `InMemoryBackend` in tests.
- All tests pass.

---

### Step 8 — All Transactions View & Filtering

**Goal:** A global transactions view with date/category/payee/account/earmark filters.

#### Tasks
- Build `AllTransactionsView` (reuses `TransactionListView` with no account scoping).
- Build `TransactionFilterView` sheet:
  - Date range pickers.
  - Category multi-select.
  - Payee text field.
  - Account picker.
  - Earmark picker.
  - Clear-all button.
- Show active filter badge when any filter is set.
- `TransactionStore` is re-loaded with the updated `TransactionFilter`.

**Tests** (using `InMemoryBackend`):
- Each filter field narrows results correctly (in-memory filter logic tested in Step 2; here test store correctly passes filter through).
- Clearing filter reloads unfiltered list.
- Filter badge visibility reflects active state.

#### Definition of Done
- Filtering by every combination works.
- The active filter is clearly indicated.

---

### Step 9 — Category Management

**Goal:** Users can view, create, rename, merge, and delete categories.

#### Tasks
- Implement `CategoryStore` using `CategoryRepository`.
- Build `CategoriesView`: hierarchical tree (`List` with `children` key path built from `parentId`).
- Build `CategoryDetailView`: rename field, delete action (with "Replace with…" picker when transactions exist).
- All CRUD operations routed through `CategoryRepository`.

**Tests** (using `InMemoryBackend`):
- Tree built correctly from flat list with `parentId` relationships.
- Creating a subcategory sets `parentId`.
- Deleting with replacement invokes `delete(withReplacement:)` on the repository.
- Renaming updates the correct node in the tree.

#### Definition of Done
- Category tree renders with correct indentation.
- All CRUD operations work and are tested.

---

### Step 10 — Earmarks

**Goal:** Users can view earmarks, see their transactions, and manage savings goals.

#### Tasks
- Implement `EarmarkStore` using `EarmarkRepository`.
- Add earmarks section to `SidebarView`.
- Build `EarmarkDetailView`:
  - **Overview tab**: balance, saved, spent; savings goal progress bar.
  - **Spending Breakdown tab**: category allocations via `EarmarkRepository.fetchBudget`.
- Show transactions filtered to the earmark (reuse `TransactionListView`).
- Create / edit earmark dialogs.
- Update `TransactionFormView` to include earmark picker.

**Tests** (using `InMemoryBackend`):
- Savings goal progress: `saved / savingsTarget`.
- Spending breakdown data populates correctly.
- Earmark filter correctly scopes transaction list.
- Budget allocation update calls repository correctly.

#### Definition of Done
- Full earmark lifecycle works.
- Savings progress is accurate.

---

### Step 11 — Upcoming / Scheduled Transactions

**Goal:** Users can view overdue and upcoming scheduled transactions and mark them paid.

#### Tasks
- Build `UpcomingView` fetching with `TransactionFilter(scheduled: true)`.
- Overdue = `date < today`; highlight in red.
- "Pay" action: create a non-scheduled copy dated today via `TransactionRepository.create`.
- `TransactionFormView` extended with recurrence fields: period + interval.

**Tests** (using `InMemoryBackend`):
- Overdue classification (date < today).
- Pay action creates a new non-scheduled transaction and does not delete the original scheduled one.
- Recurrence fields round-trip through create/update.

#### Definition of Done
- Overdue items are visually distinct.
- Paying a scheduled transaction works.

---

### Step 12 — Analysis Dashboard

**Goal:** The home screen shows net-worth graph, expense breakdown, income/expense table, and upcoming summary.

#### Tasks
- Implement `AnalysisStore` using `AnalysisRepository`.
- Build `AnalysisView`:
  - **Net Worth Graph** (Swift Charts area mark): `AnalysisRepository.fetchDailyBalances` with forecast series.
  - **Expense Breakdown** (Swift Charts sector mark): `AnalysisRepository.fetchExpenseBreakdown`.
  - **Income vs. Expense Table**: `AnalysisRepository.fetchIncomeAndExpense`.
  - **Upcoming widget**: next 5 scheduled transactions.
- Financial-year picker + custom date range controls.

**Tests** (using `InMemoryBackend` — analysis methods compute from in-memory transactions):
- Daily balance series is ordered by date.
- Forecast data points are flagged `isForecast = true`.
- Expense breakdown percentages sum to 100.
- Income/expense totals match sum of in-memory transactions for the period.

#### Definition of Done
- Dashboard renders real data on both platforms.
- Charts are interactive.

---

### Step 13 — Reports

**Goal:** Users can view income and expense breakdowns by category for any date range.

#### Tasks
- Build `ReportsView`:
  - Date range / financial-year selector.
  - Income by category table (expandable subcategory rows).
  - Expenses by category table.
  - Totals row.
- Reuses `AnalysisRepository.fetchExpenseBreakdown` and `fetchIncomeAndExpense`.

**Tests**:
- Subcategory rows nest under correct parents.
- Totals match sum of category amounts.
- Changing date range triggers fresh repository fetch.

#### Definition of Done
- Reports are readable on both form factors.

---

### Step 14 — Investment Tracking

**Goal:** Investment accounts show value history and allow manual value entries.

#### Tasks
- Build `InvestmentValuesView` (inside `AccountDetailView` for investment accounts):
  - Line chart of value over time.
  - List of entries (date + amount) with delete.
  - "Add Value" form.
- All operations via `InvestmentRepository`.

**Tests** (using `InMemoryBackend`):
- Pagination loads all pages without duplicates.
- Adding a value inserts it into the repository.
- Deleting removes the entry and the chart updates.

#### Definition of Done
- Investment charts render correctly.
- CRUD for values works.

---

### Step 15 — Account Management (Create / Edit / Reorder)

**Goal:** Users can create, edit, and reorder accounts.

#### Tasks
- Build `CreateAccountView` sheet (name, type, initial balance, hidden toggle).
- Build `EditAccountView` (adds closed toggle).
- Drag-and-drop reordering in sidebar via `.onMove`; persist updated `position` via `AccountRepository.update`.
- Reorder is debounced to batch updates.

**Tests** (using `InMemoryBackend`):
- Create adds account to repository.
- Edit updates repository.
- Reorder assigns correct `position` values to all affected accounts.
- Closing an account sets `hidden = true` and removes it from active sections.

#### Definition of Done
- Full account CRUD with ordering works on both platforms.

---

### Step 16 — Platform Polish & Feature Parity

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
