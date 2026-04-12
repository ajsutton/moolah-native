# Moolah — iCloud Migration Plan

**Date:** 2026-04-08
**Status:** Complete

## Executive Summary

This plan describes how to migrate moolah-native from the current `RemoteBackend` (REST API talking to moolah-server) to a fully local-first architecture using **SwiftData with CloudKit syncing**. The existing `BackendProvider` abstraction means the migration is a matter of creating a new `CloudKitBackend` implementation — no UI or feature code needs to change.

The moolah-server provides six major components that must be replicated locally:

1. **Authentication & User Identity**
2. **Accounts**
3. **Transactions** (including filtering, pagination, and balance computation)
4. **Categories** (including hierarchy)
5. **Earmarks / Savings Goals** (including budgets and computed balances)
6. **Scheduled Transactions & Forecasting**

Each component has a dedicated detailed plan in this directory.

---

## Architecture Overview

### Current Architecture (Remote Backend)

```
┌──────────────────────────┐
│     Views / Features     │
└────────────┬─────────────┘
             │ @Observable Stores
┌────────────▼─────────────┐
│   Repository Protocols   │  ← Domain layer
└──────┬───────────────────┘
       │
┌──────▼──────────────────┐
│   RemoteBackend         │
│   ├── APIClient         │  URLSession → moolah-server
│   ├── DTOs              │  JSON ↔ Domain models
│   └── Remote Repos      │  REST endpoints
└─────────────────────────┘
```

### Target Architecture (CloudKit Backend)

```
┌──────────────────────────┐
│     Views / Features     │  ← NO CHANGES
└────────────┬─────────────┘
             │ @Observable Stores
┌────────────▼─────────────┐
│   Repository Protocols   │  ← NO CHANGES
└──────┬───────────────────┘
       │
┌──────▼──────────────────┐
│   CloudKitBackend       │
│   ├── SwiftData Models  │  @Model classes with CloudKit sync
│   ├── Model Container   │  CloudKit-enabled ModelContainer
│   └── CloudKit Repos    │  SwiftData queries → Domain models
└──────┬──────────────────┘
       │ automatic sync
┌──────▼──────────────────┐
│   iCloud (CloudKit)     │  Private database, auto-sync
└─────────────────────────┘
```

### Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Persistence | SwiftData with CloudKit | First-party, automatic sync, no server to maintain |
| CloudKit Database | Private | User's own data, no sharing needed |
| Sync Strategy | Automatic (SwiftData handles it) | Minimal code, Apple-managed conflict resolution |
| Auth | Implicit iCloud account | No sign-in UI needed; `requiresExplicitSignIn = false` |
| Computed Values | Local computation | Balances, earmark totals computed from local transactions |
| Conflict Resolution | Last-writer-wins (CloudKit default) | Acceptable for single-user financial data |
| Migration | Export/import via REST API | One-time data transfer from server to iCloud |
| Multi-Profile | `profileId` field on every record | Multiple profiles share one iCloud private database; queries scoped by profileId |
| Currency Storage | `currencyCode` on monetary records | Initially set from profile currency; storage ready for per-account/transaction currencies in future |

---

## Multi-Profile Support

The existing app supports multiple profiles via `ProfileStore` (persisted in `UserDefaults`). Each profile currently points to a different server, with data isolation enforced by server-side auth. For iCloud, all profiles share a single CloudKit private database, so **data isolation must be enforced client-side via a `profileId` field on every record**.

### How It Works

1. **Profile creation**: When the user creates a new iCloud profile, a `ProfileRecord` is inserted into SwiftData. Its `id` becomes the `profileId` for all records belonging to that profile. CloudKit syncs the `ProfileRecord` to all devices.
2. **Profile discovery**: On launch, `ProfileStore` fetches all `ProfileRecord`s from SwiftData. Profiles created on other devices appear automatically via CloudKit sync.
3. **Backend initialization**: `CloudKitBackend` is initialized with a `profileId: UUID`. All repositories receive this ID and filter every query by it.
4. **ProfileSession integration**: `ProfileSession` already creates an isolated backend per profile. For iCloud profiles, it passes `profile.id` as the `profileId` to `CloudKitBackend`.
5. **No cross-profile queries**: Repositories never see data from other profiles. This mirrors the server isolation pattern.
6. **Profile deletion**: Deleting a profile deletes the `ProfileRecord` and all records with that `profileId` from SwiftData. CloudKit propagates the deletes to all devices.

### Profile Storage: SwiftData vs UserDefaults

iCloud profiles **must** be stored in SwiftData/CloudKit (not just `UserDefaults`) so they sync across devices. Without this, a profile created on device A would be invisible on device B — the data would sync via CloudKit but no profile would exist to access it.

| Data | Storage | Syncs? |
|------|---------|--------|
| iCloud profile metadata (name, currency, financial year) | SwiftData `ProfileRecord` → CloudKit | Yes, across all devices |
| Remote profile metadata (label, serverURL, currency) | `UserDefaults` (existing) | No (per-device, per-server) |
| Active profile selection | `UserDefaults` | No (per-device — each device can have a different active profile) |

### ProfileRecord SwiftData Model

```swift
@Model
final class ProfileRecord {
  #Unique<ProfileRecord>([\.id])

  @Attribute(.preserveValueOnDeletion)
  var id: UUID

  var label: String            // user-friendly name ("Personal", "Business")
  var currencyCode: String     // ISO code (AUD, USD, etc.)
  var financialYearStartMonth: Int  // 1-12
  var createdAt: Date

  init(id: UUID, label: String, currencyCode: String, financialYearStartMonth: Int = 7, createdAt: Date = .now) {
    self.id = id
    self.label = label
    self.currencyCode = currencyCode
    self.financialYearStartMonth = financialYearStartMonth
    self.createdAt = createdAt
  }
}
```

### ProfileStore Changes

`ProfileStore` currently reads/writes all profiles from `UserDefaults`. With iCloud support, it becomes a hybrid:

- **Remote profiles**: Continue using `UserDefaults` (unchanged)
- **iCloud profiles**: Read from SwiftData (`ProfileRecord`), observe for CloudKit sync changes
- **Active profile ID**: Stays in `UserDefaults` (per-device selection)

```swift
@Observable
@MainActor
final class ProfileStore {
  // Existing: remote profiles from UserDefaults
  private(set) var remoteProfiles: [Profile] { ... }

  // New: iCloud profiles from SwiftData (auto-discovered via CloudKit sync)
  private(set) var cloudProfiles: [Profile] { ... }

  // Combined view
  var profiles: [Profile] { remoteProfiles + cloudProfiles }

  // Per-device selection (UserDefaults)
  var activeProfileID: UUID? { ... }
}
```

### Profile Model Changes

`BackendType` needs a `.cloudKit` case. iCloud profiles don't have a `serverURL` — they store only the profile metadata (label, currency, financial year).

```swift
enum BackendType: String, Codable, Sendable {
  case remote    // existing moolah-server
  case cloudKit  // local SwiftData + iCloud sync
}
```

---

## Currency Storage Strategy

Currently, currency flows from `Profile.currency` → backend → `MonetaryAmount` on all domain objects. DTOs and records store only cents (`Int`). To support future per-account/earmark/transaction currencies, **all SwiftData records that store monetary amounts must also store a `currencyCode: String`**.

### Design

- Every record with an `amount`/`balance` field gets a `currencyCode: String` column.
- Initially, `currencyCode` is set from `profile.currency.code` for all records.
- Repository `toDomain()` mapping reads `currencyCode` from the record (not from the profile), constructing `Currency` from the stored code.
- This means the storage is ready for multi-currency without schema migration — only the business logic needs to change.

### Records Affected

| Record | Currency Fields |
|--------|----------------|
| `TransactionRecord` | `currencyCode` (for `amount`) |
| `AccountRecord` | `currencyCode` (for future per-account currency) |
| `EarmarkRecord` | `currencyCode` (for `savingsTarget` and computed values) |
| `EarmarkBudgetItemRecord` | `currencyCode` (for `amount`) |
| `CategoryRecord` | None (categories have no monetary values) |

### Currency Lookup

```swift
extension Currency {
  /// Construct Currency from a stored code. Falls back to a generic representation.
  static func from(code: String) -> Currency {
    switch code {
    case "AUD": return .AUD
    case "USD": return .USD
    default: return Currency(code: code, symbol: code, decimals: 2)
    }
  }
}
```

---

## Performance Analysis

### Transaction Volume Estimates

| User Type | Transactions/Month | 5 Years Total | Memory (~200 bytes/txn) |
|-----------|-------------------|---------------|------------------------|
| Light | 30-50 | 1,800-3,000 | < 1 MB |
| Typical | 100-200 | 6,000-12,000 | ~2 MB |
| Heavy | 300-500 | 18,000-30,000 | ~6 MB |
| Power user | 500+ | 30,000-60,000 | ~12 MB |

### In-Memory Processing Benchmarks (estimated)

All analysis queries fetch all non-scheduled transactions and compute in memory. This matches the existing `InMemoryAnalysisRepository` pattern (which uses `pageSize: 10000`).

| Operation | 10K txns | 30K txns | 50K txns |
|-----------|----------|----------|----------|
| SwiftData fetch (SQLite) | 10-30ms | 30-80ms | 50-150ms |
| Filter + sort (in-memory) | 1-3ms | 3-8ms | 5-15ms |
| Balance summation | < 1ms | < 1ms | 1-2ms |
| Total per query | ~15-35ms | ~35-90ms | ~60-170ms |

### Verdict

**For typical users (< 20K transactions): No performance concern.** Integer arithmetic over small structs is extremely fast. SwiftData's SQLite-backed fetch is the bottleneck, not computation.

**For power users (30K-50K+ transactions):** Acceptable but worth optimizing:

1. **Predicate push-down** — Push simple filters (scheduled, dateRange, accountId) into SwiftData predicates to reduce the fetch size. The plans already describe this.
2. **Cached account balances** — `AccountStore.applyTransactionDelta()` already maintains incremental balance updates. The full scan only happens on `load()` (app launch / pull-to-refresh).
3. **Background computation** — Run analysis queries on a background `ModelActor`, post results to the main actor. The `@ModelActor` macro already provides this isolation.
4. **Profile scoping** — The `profileId` predicate filter is always applied, which limits the working set to one profile's data. Users who split data across profiles will naturally have smaller per-profile datasets.

### Analysis Query Performance

The four `AnalysisRepository` methods all scan the full transaction set. With iCloud backend:

| Query | Scan Size | Notes |
|-------|-----------|-------|
| `fetchDailyBalances` | All non-scheduled txns | Sorted chronologically, running balance — O(n) |
| `fetchExpenseBreakdown` | All negative txns | Group by (category, month) — O(n) |
| `fetchIncomeAndExpense` | All txns | Group by month — O(n) |
| `fetchCategoryBalances` | Filtered txns | Date range + type filter reduces set significantly |

All are O(n) and embarrassingly parallelizable. The existing code runs these concurrently via `async let` in `AnalysisStore.loadAll()`. Even at 50K transactions, each query completes in under 200ms — well within acceptable UI latency for a data load triggered by tab switch or pull-to-refresh.

### Comparison: Server vs Local

| Aspect | RemoteBackend (current) | CloudKitBackend (proposed) |
|--------|------------------------|---------------------------|
| Latency per query | 200-800ms (network RTT) | 15-170ms (local SQLite) |
| Parallelism | Limited by server concurrency | Unlimited local threads |
| Offline | Fails | Works |
| Memory | Low (server computes) | Higher (all txns in memory) |

**Local computation is faster than network round-trips in virtually all cases.** The only scenario where the server wins is if it can use SQL aggregates (SUM, GROUP BY) to avoid transferring raw transaction data — but the current server endpoints return pre-computed results, so the app never downloads bulk transactions for analysis anyway. With iCloud, the local SQLite is the database, and the in-memory scan replaces the SQL aggregates.

---

## Major Components

### 1. Authentication & User Identity

**Server functionality being replaced:**
- Google OAuth sign-in flow
- Session cookie management
- User profile retrieval

**iCloud approach:**
- Use implicit Apple ID via `CKContainer.default().userRecordID()`
- `requiresExplicitSignIn = false` — no login screen needed
- User profile from `CKContainer.default().fetchShareParticipants()` or device owner info
- `CloudKitAuthProvider` implements existing `AuthProvider` protocol

**Detailed plan:** [`ICLOUD_AUTH_PLAN.md`](./ICLOUD_AUTH_PLAN.md)

---

### 2. Accounts

**Server functionality being replaced:**
- `GET /api/accounts/` — fetch all accounts
- Account balance computed from sum of transactions
- Sorting by position
- Account types: bank, cc, asset, investment

**iCloud approach:**
- `AccountRecord` SwiftData `@Model` class
- Balance computed locally from `TransactionRecord` queries
- Position-based ordering stored in the model
- `CloudKitAccountRepository` implements `AccountRepository` protocol

**Detailed plan:** [`ICLOUD_ACCOUNTS_PLAN.md`](./ICLOUD_ACCOUNTS_PLAN.md)

---

### 3. Transactions

**Server functionality being replaced:**
- `GET /api/transactions/` — paginated, filtered fetch
- `POST /PUT /DELETE /api/transactions/` — CRUD
- Complex filtering (account, earmark, scheduled, date range, category, payee)
- Pagination with offset/pageSize
- `priorBalance` computation
- Payee suggestions

**iCloud approach:**
- `TransactionRecord` SwiftData `@Model` class
- SwiftData `#Predicate` for filtering
- `FetchDescriptor` with sort and pagination
- `priorBalance` computed via aggregate query on older transactions
- Payee suggestions via distinct query on payee field
- `CloudKitTransactionRepository` implements `TransactionRepository` protocol

**Detailed plan:** [`ICLOUD_TRANSACTIONS_PLAN.md`](./ICLOUD_TRANSACTIONS_PLAN.md)

---

### 4. Categories

**Server functionality being replaced:**
- `GET /api/categories/` — fetch all categories
- `POST /PUT /DELETE /api/categories/` — CRUD
- Hierarchical parent-child relationships via `parentId`
- Deletion with replacement (re-parent children)

**iCloud approach:**
- `CategoryRecord` SwiftData `@Model` class
- Parent-child relationship modeled via optional `parentId` (or SwiftData relationship)
- Deletion with replacement logic in repository
- `CloudKitCategoryRepository` implements `CategoryRepository` protocol

**Detailed plan:** [`ICLOUD_CATEGORIES_PLAN.md`](./ICLOUD_CATEGORIES_PLAN.md)

---

### 5. Earmarks / Savings Goals

**Server functionality being replaced:**
- `GET /api/earmarks/` — fetch all with computed balance/saved/spent
- `POST /PUT /api/earmarks/` — CRUD
- `GET /PUT /api/earmarks/{id}/budget/` — budget management
- Balance = sum of transactions with this earmarkId
- Saved = sum of positive transaction amounts
- Spent = sum of absolute negative transaction amounts

**iCloud approach:**
- `EarmarkRecord` SwiftData `@Model` class
- `EarmarkBudgetItemRecord` SwiftData `@Model` class
- Balance/saved/spent computed locally from transactions at fetch time
- `CloudKitEarmarkRepository` implements `EarmarkRepository` protocol

**Detailed plan:** [`ICLOUD_EARMARKS_PLAN.md`](./ICLOUD_EARMARKS_PLAN.md)

---

### 6. Scheduled Transactions & Forecasting

**Server functionality being replaced:**
- Scheduled transaction filtering (`scheduled=true/false`)
- Next due date calculation
- Pay action orchestration (create paid copy + update/delete original)
- Transaction forecasting for analysis graphs

**iCloud approach:**
- Scheduled transactions are just `TransactionRecord` entries with `recurPeriod != nil`
- All recurrence logic already exists in `Domain/Models/Transaction.swift`
- Pay action orchestrated locally (same as current InMemoryBackend behavior)
- Forecasting computed locally from scheduled transactions
- No separate component needed — handled within `CloudKitTransactionRepository`

**Detailed plan:** [`ICLOUD_SCHEDULED_TRANSACTIONS_PLAN.md`](./ICLOUD_SCHEDULED_TRANSACTIONS_PLAN.md)

---

## Data Migration

Existing users with data on moolah-server need a one-time migration path to move their data into iCloud.

**Detailed plan:** [`ICLOUD_DATA_MIGRATION_PLAN.md`](./ICLOUD_DATA_MIGRATION_PLAN.md)

---

## SwiftData Model Design

All SwiftData `@Model` classes live in `Backends/CloudKit/Models/`. They are internal to the CloudKit backend — features never see them. Each repository maps between SwiftData models and domain models.

### Model Relationships

Every record includes `profileId: UUID` for multi-profile isolation. All queries filter by `profileId`.

Records with monetary values include `currencyCode: String` for future multi-currency support (initially set from profile currency).

```
ProfileRecord                          ← synced via CloudKit, discovered on all devices
  ├── id: UUID (unique)                ← this IS the profileId used by all other records
  ├── label: String
  ├── currencyCode: String
  ├── financialYearStartMonth: Int
  └── createdAt: Date

AccountRecord
  ├── id: UUID (unique)
  ├── profileId: UUID              ← multi-profile scoping
  ├── name: String
  ├── type: String (raw value of AccountType)
  ├── position: Int
  ├── isHidden: Bool
  ├── currencyCode: String         ← future per-account currency
  └── ← TransactionRecord.accountId / toAccountId (implicit)

TransactionRecord
  ├── id: UUID (unique)
  ├── profileId: UUID              ← multi-profile scoping
  ├── type: String (raw value of TransactionType)
  ├── date: Date
  ├── accountId: UUID?
  ├── toAccountId: UUID?
  ├── amount: Int (cents)
  ├── currencyCode: String         ← future per-transaction currency
  ├── payee: String?
  ├── notes: String?
  ├── categoryId: UUID?
  ├── earmarkId: UUID?
  ├── recurPeriod: String? (raw value of RecurPeriod)
  └── recurEvery: Int?

CategoryRecord
  ├── id: UUID (unique)
  ├── profileId: UUID              ← multi-profile scoping
  ├── name: String
  └── parentId: UUID?

EarmarkRecord
  ├── id: UUID (unique)
  ├── profileId: UUID              ← multi-profile scoping
  ├── name: String
  ├── position: Int
  ├── isHidden: Bool
  ├── savingsTarget: Int? (cents)
  ├── currencyCode: String         ← future per-earmark currency
  ├── savingsStartDate: Date?
  └── savingsEndDate: Date?

EarmarkBudgetItemRecord
  ├── id: UUID (unique)
  ├── earmarkId: UUID
  ├── categoryId: UUID
  ├── amount: Int (cents)
  └── currencyCode: String         ← future per-budget-item currency
```

### CloudKit Considerations

- **Container:** Use the app's default CloudKit container
- **Database:** Private database only (no public or shared)
- **Record Zone:** Default zone (SwiftData manages this)
- **Indexes:** SwiftData automatically creates CloudKit indexes for `@Attribute` properties used in predicates. `profileId` will be indexed automatically since it appears in every query predicate.
- **Size Limits:** CloudKit record size limit is 1MB — financial records are well within this
- **Rate Limits:** CloudKit has per-user rate limits; batch operations should be chunked appropriately during migration

---

## Implementation Order

The recommended implementation order minimizes risk and allows incremental testing:

### Phase 1: Foundation
1. **SwiftData Models** — Define all `@Model` classes
2. **CloudKit ModelContainer** — Configure CloudKit-enabled container
3. **CloudKitAuthProvider** — Simplest component; validates iCloud availability

### Phase 2: Core Repositories (order matters — transactions depend on accounts)
4. **CloudKitCategoryRepository** — No computed values, straightforward CRUD
5. **CloudKitAccountRepository** — Read-only initially (balance computed from transactions)
6. **CloudKitTransactionRepository** — Most complex; filtering, pagination, balance computation
7. **CloudKitEarmarkRepository** — Depends on transactions for computed values

### Phase 3: Assembly & Testing
8. **CloudKitBackend** — Wire all repositories into `BackendProvider`
9. **Contract Tests** — Run existing contract test suites against CloudKit backend
10. **Composition Root** — Add toggle to switch between Remote and CloudKit backends

### Phase 4: Migration
11. **Data Migration Tool** — Export from server, import to iCloud
12. **Migration UI** — In-app flow for existing users

### Phase 5: Cleanup — Skipped
~~13. **Remove RemoteBackend** — Once migration is complete and stable~~
~~14. **Remove Google Sign-In dependency** — No longer needed~~

> **Note:** Phase 5 is intentionally skipped. RemoteBackend is retained to support existing server-based profiles and the web app. The `ServerDataExporter` functionality originally planned here was implemented and then refactored into the general-purpose backup & export feature.

---

## Risk Assessment

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| CloudKit sync delays | Medium | Medium | Show sync status indicator; local-first means app always works |
| CloudKit quota limits | Low | Low | Financial data is small; well within free tier |
| Conflict resolution errors | Medium | Low | Last-writer-wins is acceptable; single user typically uses one device at a time |
| SwiftData/CloudKit bugs | High | Medium | Use latest iOS/macOS 26 APIs; file radars; keep RemoteBackend as fallback |
| Migration data loss | Critical | Low | Verify migration with checksums; keep server running during transition period |
| iCloud account not available | Medium | Low | Show clear error; require iCloud sign-in |

---

## Testing Strategy

- **All existing contract tests** must pass against `CloudKitBackend`
- **Use in-memory SwiftData container** (without CloudKit) for unit tests
- **Integration tests** with actual CloudKit container for sync verification
- **Migration tests** comparing exported server data with imported iCloud data
- **Multi-device sync tests** (manual) to verify eventual consistency

---

## Files to Create

```
Backends/CloudKit/
├── CloudKitBackend.swift              # BackendProvider implementation (takes profileId + currency)
├── Auth/
│   └── CloudKitAuthProvider.swift     # Implicit iCloud auth (profile-agnostic)
├── Models/
│   ├── ProfileRecord.swift             # @Model — profile metadata, synced across devices
│   ├── AccountRecord.swift            # @Model — includes profileId, currencyCode
│   ├── TransactionRecord.swift        # @Model — includes profileId, currencyCode
│   ├── CategoryRecord.swift           # @Model — includes profileId
│   ├── EarmarkRecord.swift            # @Model — includes profileId, currencyCode
│   └── EarmarkBudgetItemRecord.swift  # @Model — includes currencyCode
├── Repositories/
│   ├── CloudKitAccountRepository.swift     # All queries scoped by profileId
│   ├── CloudKitTransactionRepository.swift # All queries scoped by profileId
│   ├── CloudKitCategoryRepository.swift    # All queries scoped by profileId
│   ├── CloudKitEarmarkRepository.swift     # All queries scoped by profileId
│   └── CloudKitAnalysisRepository.swift    # All queries scoped by profileId
└── Migration/
    ├── ServerDataExporter.swift        # Fetches all data from REST API
    ├── CloudKitDataImporter.swift      # Writes data to SwiftData/CloudKit (stamps profileId + currencyCode)
    └── ProfileDataDeleter.swift        # Batch-deletes all records for a profileId
```

---

## Out of Scope

- Shared databases / multi-user collaboration
- CloudKit subscriptions / push notifications for sync
- Offline write queue (SwiftData handles this automatically)
- Server-side changes to moolah-server
- Web app migration (web app continues to use moolah-server)
