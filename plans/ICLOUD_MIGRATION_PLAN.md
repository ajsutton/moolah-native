# Moolah — iCloud Migration Plan

**Date:** 2026-04-08
**Status:** Draft

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

```
AccountRecord
  ├── id: UUID (unique)
  ├── name: String
  ├── type: String (raw value of AccountType)
  ├── position: Int
  ├── isHidden: Bool
  └── ← TransactionRecord.accountId / toAccountId (implicit)

TransactionRecord
  ├── id: UUID (unique)
  ├── type: String (raw value of TransactionType)
  ├── date: Date
  ├── accountId: UUID?
  ├── toAccountId: UUID?
  ├── amount: Int (cents)
  ├── payee: String?
  ├── notes: String?
  ├── categoryId: UUID?
  ├── earmarkId: UUID?
  ├── recurPeriod: String? (raw value of RecurPeriod)
  └── recurEvery: Int?

CategoryRecord
  ├── id: UUID (unique)
  ├── name: String
  └── parentId: UUID?

EarmarkRecord
  ├── id: UUID (unique)
  ├── name: String
  ├── position: Int
  ├── isHidden: Bool
  ├── savingsTarget: Int? (cents)
  ├── savingsStartDate: Date?
  └── savingsEndDate: Date?

EarmarkBudgetItemRecord
  ├── id: UUID (unique)
  ├── earmarkId: UUID
  ├── categoryId: UUID
  └── amount: Int (cents)
```

### CloudKit Considerations

- **Container:** Use the app's default CloudKit container
- **Database:** Private database only (no public or shared)
- **Record Zone:** Default zone (SwiftData manages this)
- **Indexes:** SwiftData automatically creates CloudKit indexes for `@Attribute` properties used in predicates
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

### Phase 5: Cleanup
13. **Remove RemoteBackend** — Once migration is complete and stable
14. **Remove Google Sign-In dependency** — No longer needed

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
├── CloudKitBackend.swift              # BackendProvider implementation
├── Auth/
│   └── CloudKitAuthProvider.swift     # Implicit iCloud auth
├── Models/
│   ├── AccountRecord.swift            # @Model for accounts
│   ├── TransactionRecord.swift        # @Model for transactions
│   ├── CategoryRecord.swift           # @Model for categories
│   ├── EarmarkRecord.swift            # @Model for earmarks
│   └── EarmarkBudgetItemRecord.swift  # @Model for earmark budgets
├── Repositories/
│   ├── CloudKitAccountRepository.swift
│   ├── CloudKitTransactionRepository.swift
│   ├── CloudKitCategoryRepository.swift
│   └── CloudKitEarmarkRepository.swift
└── Migration/
    ├── ServerDataExporter.swift        # Fetches all data from REST API
    └── CloudKitDataImporter.swift      # Writes data to SwiftData/CloudKit
```

---

## Out of Scope

- Shared databases / multi-user collaboration
- CloudKit subscriptions / push notifications for sync
- Offline write queue (SwiftData handles this automatically)
- Server-side changes to moolah-server
- Web app migration (web app continues to use moolah-server)
