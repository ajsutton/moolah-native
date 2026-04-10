# iCloud Backend — Design Spec

**Date:** 2026-04-10
**Status:** Approved

## Overview

Add a CloudKit-backed backend as an additional option alongside the existing remote backend. Users can create iCloud profiles that store all data locally in SwiftData with automatic CloudKit sync across devices. Remote profiles (Moolah.rocks and custom server) continue to work unchanged.

This is **additive** — no existing functionality is removed. Future removal of the remote backend is out of scope (tracked separately).

---

## SwiftData Models

All `@Model` classes live in `Backends/CloudKit/Models/`. They are internal to the CloudKit backend — features never see them.

Every record includes `profileId: UUID` for multi-profile isolation. All queries filter by `profileId`. Records with monetary values include `currencyCode: String` (ISO code), initially set from profile currency.

### Models

| Model | Key Fields | Notes |
|-------|-----------|-------|
| `ProfileRecord` | id, label, currencyCode, financialYearStartMonth, createdAt | Syncs across devices via CloudKit |
| `AccountRecord` | id, profileId, name, type, position, isHidden, currencyCode | Balance computed from transactions |
| `TransactionRecord` | id, profileId, type, date, accountId, toAccountId, amount, currencyCode, payee, notes, categoryId, earmarkId, recurPeriod, recurEvery | Most fields optional |
| `CategoryRecord` | id, profileId, name, parentId | No monetary values |
| `EarmarkRecord` | id, profileId, name, position, isHidden, savingsTarget, currencyCode, savingsStartDate, savingsEndDate | Balance/saved/spent computed from transactions |
| `EarmarkBudgetItemRecord` | id, profileId, earmarkId, categoryId, amount, currencyCode | Links earmarks to category budgets |
| `InvestmentValueRecord` | id, profileId, accountId, date, value, currencyCode | Daily investment valuations |

Each model has `toDomain(currency:)` and `static from(domain:profileId:currencyCode:)` mapping methods.

### ModelContainer

- Single `ModelContainer` created in `MoolahApp.init()` with CloudKit configuration
- Schema includes all `@Model` types listed above
- Uses the app's default CloudKit container, private database
- Passed explicitly via init to `ProfileStore`, `SessionManager` (macOS), and `ProfileSession`
- For tests: `ModelConfiguration(isStoredInMemoryOnly: true)` without CloudKit

---

## Currency — System-Derived

All currency metadata (symbol, decimal places) is derived from the system via `NumberFormatter`:

```swift
extension Currency {
    static func from(code: String) -> Currency {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        return Currency(
            code: code,
            symbol: formatter.currencySymbol,
            decimals: formatter.maximumFractionDigits
        )
    }

    // Convenience constants (delegate to from(code:))
    static let AUD = Currency.from(code: "AUD")
    static let USD = Currency.from(code: "USD")
}
```

This replaces the current hardcoded `Currency` constants. Symbols and decimal places are locale-sensitive and correct for all currencies (e.g., JPY gets 0 decimals, BHD gets 3).

---

## CloudKit Repositories

Each repository implements the existing protocol, takes a `ModelContext` and `profileId: UUID` at init, and scopes all queries by `profileId`.

### CloudKitCategoryRepository

- `fetchAll()` — SwiftData fetch filtered by profileId, sorted by name
- `create/update` — insert/update `CategoryRecord`, save context, return domain model
- `delete(id:withReplacement:)` — re-parent children and re-assign transactions to replacement category before deleting

### CloudKitAccountRepository

- `fetchAll()` — fetch `AccountRecord`s by profileId, sorted by position
- Balance computed by summing `TransactionRecord`s for each account (matching `accountId`, with transfers via `toAccountId` contributing the negative)
- Standard CRUD

### CloudKitTransactionRepository

- `fetch(filter:page:pageSize:)` — build `#Predicate` from `TransactionFilter` fields + profileId. Sort by date descending. Apply offset/limit for pagination.
- `priorBalance` — sum amounts for all transactions older than the first in the page (scoped by account/earmark from filter)
- `fetchPayeeSuggestions(prefix:)` — distinct payee values matching prefix, limited to ~20 results
- Standard CRUD

### CloudKitEarmarkRepository

- `fetchAll()` — fetch `EarmarkRecord`s, compute `balance`/`saved`/`spent` from transactions with matching `earmarkId`
- `fetchBudget/setBudget` — CRUD on `EarmarkBudgetItemRecord`
- Standard CRUD on `EarmarkRecord`

### CloudKitAnalysisRepository

All four methods fetch transactions by profileId (with relevant filters), then compute in-memory — same algorithms as `InMemoryAnalysisRepository`:

- `fetchDailyBalances` — running balance chronologically, with forecast from scheduled transactions
- `fetchExpenseBreakdown` — group negative amounts by (categoryId, month)
- `fetchIncomeAndExpense` — group by month, split income/expense, earmarked/non-earmarked
- `fetchCategoryBalances` — sum by categoryId within date range

### CloudKitInvestmentRepository

- `fetchValues(accountId:page:pageSize:)` — fetch `InvestmentValueRecord`s sorted by date descending, paginated
- `setValue/removeValue` — CRUD on `InvestmentValueRecord`
- `fetchDailyBalances(accountId:)` — all investment values for account as `[AccountDailyBalance]`

### CloudKitAuthProvider

- `requiresExplicitSignIn` — `false`
- `currentUser()` — check `CKContainer.default().accountStatus()`, return `UserProfile` with the profile label as the display name (iCloud doesn't expose the user's real name via `CKContainer`)
- `signIn()` — no-op but verifies iCloud availability, throws if not signed in
- `signOut()` — no-op

### Error Mapping

SwiftData/CloudKit errors mapped to `BackendError`:

- `CKError.notAuthenticated` → `.unauthenticated`
- `CKError.networkUnavailable` → `.networkUnavailable`
- Model validation failures → `.validationFailed(...)`
- Record not found → `.notFound(...)`

---

## CloudKitBackend Assembly

```swift
final class CloudKitBackend: BackendProvider, Sendable {
    let auth: any AuthProvider
    let accounts: any AccountRepository
    let transactions: any TransactionRepository
    let categories: any CategoryRepository
    let earmarks: any EarmarkRepository
    let analysis: any AnalysisRepository
    let investments: any InvestmentRepository

    init(modelContext: ModelContext, profileId: UUID, currency: Currency)
}
```

Creates all `CloudKit*Repository` instances with the shared `modelContext` and `profileId`.

---

## BackendType & Profile Changes

### BackendType

```swift
enum BackendType: String, Codable, Sendable {
    case remote
    case moolah
    case cloudKit  // NEW
}
```

### Profile

No structural changes. Existing optional fields (`serverURL`, `cachedUserName`) are unused for cloudKit profiles.

---

## ProfileSession Integration

`ProfileSession` receives a `ModelContainer` at init (in addition to the existing `Profile`).

Backend creation branches on `profile.backendType`:

- `.remote` / `.moolah` → `RemoteBackend` (existing, ignores ModelContainer)
- `.cloudKit` → creates `ModelContext` from container, creates `CloudKitBackend(modelContext:profileId:currency:)`

### SessionManager (macOS)

`SessionManager` holds a `modelContainer: ModelContainer` reference, set at app launch. Passes it to `ProfileSession` when creating sessions.

### iOS

`ModelContainer` passed directly when creating `ProfileSession`.

---

## ProfileStore — Hybrid Profile Management

`ProfileStore` becomes a hybrid that merges two profile sources:

- **Remote profiles** → `UserDefaults` (unchanged)
- **iCloud profiles** → SwiftData `ProfileRecord` (synced via CloudKit)
- **Active profile ID** → `UserDefaults` (per-device, unchanged)

### Initialization

`ProfileStore` receives a `ModelContainer` at init. Creates a `ModelContext` for querying `ProfileRecord`s.

### Profile Discovery

On load:
1. Read remote profiles from `UserDefaults` (existing)
2. Fetch all `ProfileRecord`s from SwiftData
3. Map each `ProfileRecord` to `Profile` with `backendType: .cloudKit`
4. Combine into `profiles: [Profile]`

### Cross-Device Sync

Observe `NSPersistentStoreRemoteChange` notifications to detect profiles created/deleted on other devices. On notification, re-fetch `ProfileRecord`s and update the combined profile list.

### Adding an iCloud Profile

1. Validate iCloud availability via `CKContainer.default().accountStatus()`
2. Create `ProfileRecord` in SwiftData
3. `ProfileRecord.id` becomes the `profileId` for all data records

### Removing an iCloud Profile

1. Show confirmation: *"Delete [Profile Name]? This will permanently delete all accounts, transactions, and other data in this profile across all your devices. This cannot be undone."* (Delete button with `.destructive` role)
2. `ProfileDataDeleter` batch-deletes all records with matching `profileId` (transactions, accounts, categories, earmarks, budget items, investment values), then deletes the `ProfileRecord`
3. CloudKit propagates deletes to all devices

### Active Profile Deleted on Another Device

When `NSPersistentStoreRemoteChange` fires and the active profile no longer exists:

1. `ProfileStore` clears the active profile selection (or falls back to first available profile)
2. `SessionManager` (macOS) / iOS root view observes the change, tears down the orphaned session, navigates to profile selection
3. In-flight async work in the torn-down session fails gracefully (SwiftData queries for a deleted profileId return empty results)

### Editing an iCloud Profile

Update `ProfileRecord` in SwiftData. Changes sync via CloudKit.

---

## Add Profile UI

The existing "Add Profile" type picker gains **"iCloud"** as the first option (before "Moolah" and "Custom Server").

### iCloud Profile Form

- **Name** (required) — e.g., "Personal", "Business"
- **Currency** (required, default from device locale) — system currency picker
- **Financial Year Start Month** (optional, default July) — picker 1-12

Simpler than remote flow — no server URL or authentication step.

---

## Testing Strategy

### Contract Tests

Existing contract test suites for each repository protocol gain `CloudKitBackend` as a third target:

- Use `ModelConfiguration(isStoredInMemoryOnly: true)` — no CloudKit, no disk, fast
- Create `ModelContainer` with this config, pass to `CloudKitBackend` with a test `profileId`
- All existing contract tests pass without modification

### Multi-Profile Isolation Tests

- Two `CloudKitBackend` instances with different `profileId`s sharing the same `ModelContainer`
- Data written by one is invisible to the other
- Deletion of one profile's data doesn't affect the other

### ProfileStore Hybrid Tests

- Correctly merges remote (UserDefaults) and iCloud (SwiftData) profiles
- Removing an iCloud profile triggers `ProfileDataDeleter` and removes all associated records
- Active profile deleted externally handled gracefully

### ProfileDataDeleter Tests

- Create records across multiple profiles, delete one, verify only that profile's records removed

### Moolah-Server Test Audit

Audit tests in `../moolah-server/` to ensure CloudKit backend contract tests cover the same business logic edge cases — filtering semantics, sort orders, balance computation, pagination boundary conditions, deletion cascades, etc. The moolah-server is the source of truth for expected behavior since the CloudKit backend replicates that same logic locally.

### Not Tested (Manual)

- Actual CloudKit sync (requires real devices)
- `NSPersistentStoreRemoteChange` notification delivery (Apple framework behavior)

---

## Files to Create

```
Backends/CloudKit/
├── CloudKitBackend.swift
├── Auth/
│   └── CloudKitAuthProvider.swift
├── Models/
│   ├── ProfileRecord.swift
│   ├── AccountRecord.swift
│   ├── TransactionRecord.swift
│   ├── CategoryRecord.swift
│   ├── EarmarkRecord.swift
│   ├── EarmarkBudgetItemRecord.swift
│   └── InvestmentValueRecord.swift
├── Repositories/
│   ├── CloudKitAccountRepository.swift
│   ├── CloudKitTransactionRepository.swift
│   ├── CloudKitCategoryRepository.swift
│   ├── CloudKitEarmarkRepository.swift
│   ├── CloudKitAnalysisRepository.swift
│   └── CloudKitInvestmentRepository.swift
└── Migration/
    └── ProfileDataDeleter.swift
```

### Files to Modify

- `Domain/Models/Currency.swift` — replace hardcoded constants with system-derived `from(code:)`
- `Domain/Models/Profile.swift` — add `BackendType.cloudKit` case
- `App/MoolahApp.swift` — create `ModelContainer`, pass to `ProfileStore` and `SessionManager`/`ProfileSession`
- `App/ProfileSession.swift` — accept `ModelContainer`, branch on `backendType`
- `App/SessionManager.swift` — hold `ModelContainer`, pass to `ProfileSession`
- `Features/Profiles/ProfileStore.swift` — hybrid UserDefaults + SwiftData, observe remote changes
- `Features/Profiles/AddProfileView.swift` (or equivalent) — add iCloud option to type picker
- `project.yml` — add `CloudKit` entitlement and `Backends/CloudKit/` source path

---

## Implementation Order

### Phase 1: Foundation
1. Currency system changes (`Currency.from(code:)`)
2. SwiftData models (all `@Model` classes)
3. `BackendType.cloudKit` case
4. `ModelContainer` setup in `MoolahApp`

### Phase 2: Repositories
5. `CloudKitCategoryRepository` + contract tests
6. `CloudKitAccountRepository` + contract tests
7. `CloudKitTransactionRepository` + contract tests
8. `CloudKitEarmarkRepository` + contract tests
9. `CloudKitAnalysisRepository` + contract tests
10. `CloudKitInvestmentRepository` + contract tests
11. `CloudKitAuthProvider`

### Phase 3: Assembly & Integration
12. `CloudKitBackend` wiring
13. `ProfileSession` branching on backend type
14. `SessionManager` / `MoolahApp` plumbing
15. `ProfileStore` hybrid (UserDefaults + SwiftData)
16. `ProfileDataDeleter` + tests
17. Multi-profile isolation tests

### Phase 4: UI
18. Add "iCloud" option to profile type picker
19. iCloud profile creation form
20. Deletion confirmation dialog
21. Handle active profile deleted on another device

### Phase 5: Server Test Audit
22. Audit moolah-server tests for edge cases
23. Add missing contract test scenarios to CloudKit backend tests

---

## Out of Scope

- Data migration from remote to iCloud (separate plan: `ICLOUD_DATA_MIGRATION_PLAN.md`)
- Removal of remote backend (future, separate plan)
- Shared databases / multi-user collaboration
- CloudKit subscriptions / push notifications
- Web app changes
