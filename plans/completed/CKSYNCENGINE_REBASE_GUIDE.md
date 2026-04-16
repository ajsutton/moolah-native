# CKSyncEngine Rebase Guide — multi-instrument branch

## Context

The `main` branch is getting CKSyncEngine support (see `plans/CKSYNCENGINE_MIGRATION_PLAN.md` on main). This replaces SwiftData's automatic CloudKit sync (`cloudKitDatabase: .automatic`) with manual sync via `CKSyncEngine`, giving each iCloud profile its own CloudKit record zone.

When rebasing `feature/multi-instrument` onto main after that work lands, the sync infrastructure will need to be updated for the schema changes on this branch. This document describes what needs to change.

## Schema Differences

The multi-instrument branch made significant schema changes that affect the CKRecord ↔ SwiftData mapping layer (`Backends/CloudKit/Sync/RecordMapping.swift` on main).

### New Record Types

Two new SwiftData models need CKRecord mappings:

**`InstrumentRecord`** — represents a currency, stock, or crypto token
| Field | Type | Notes |
|-------|------|-------|
| `id` | `String` | Not UUID — uses currency codes like `"AUD"`, ticker symbols, etc. |
| `kind` | `String` | Raw value of `Instrument.Kind` (fiatCurrency, stock, crypto) |
| `name` | `String` | |
| `decimals` | `Int` | Default 2 |
| `ticker` | `String?` | |
| `exchange` | `String?` | |
| `chainId` | `Int?` | |
| `contractAddress` | `String?` | |

**`TransactionLegRecord`** — represents one leg of a multi-leg transaction
| Field | Type | Notes |
|-------|------|-------|
| `id` | `UUID` | |
| `transactionId` | `UUID` | FK to TransactionRecord |
| `accountId` | `UUID` | FK to AccountRecord |
| `instrumentId` | `String` | FK to InstrumentRecord |
| `quantity` | `Int64` | Stored as value × 10^8 |
| `type` | `String` | Raw value of TransactionType |
| `categoryId` | `UUID?` | |
| `earmarkId` | `UUID?` | |
| `sortOrder` | `Int` | |

### Changed Record Types

**`TransactionRecord`** — massive simplification, 7 fields removed:
- **Removed:** `type`, `accountId`, `toAccountId`, `amount`, `currencyCode`, `categoryId`, `earmarkId`
- **Retained:** `id`, `date`, `payee`, `notes`, `recurPeriod`, `recurEvery`
- All per-leg financial data moved to `TransactionLegRecord`

**`AccountRecord`**:
- **Removed:** `currencyCode`, `cachedBalance`
- **Added:** `usesPositionTracking: Bool`

**`EarmarkRecord`**:
- **Removed:** `currencyCode`
- **Added:** `savingsTargetInstrumentId: String?`
- **Changed:** `savingsTarget` from `Int?` (cents) to `Int64?` (× 10^8)

**`EarmarkBudgetItemRecord`**:
- **Removed:** `currencyCode`
- **Added:** `instrumentId: String`
- **Changed:** `amount` from `Int` (cents) to `Int64` (× 10^8)

**`InvestmentValueRecord`**:
- **Removed:** `currencyCode`
- **Added:** `instrumentId: String`
- **Changed:** `value` from `Int` (cents) to `Int64` (× 10^8)

**Unchanged:** `CategoryRecord`, `ProfileRecord`

### Monetary Storage Change

All monetary values changed from `Int` (cents, × 10^2) to `Int64` (× 10^8) to support fractional quantities for stocks and crypto. The CKRecord field mappings must use `Int64` for these fields, not `Int`.

### Currency → Instrument Migration

The `currencyCode: String` field was removed from 5 record types. Currency identity is now carried by `instrumentId: String` referencing an `InstrumentRecord`. The CKRecord mapping for affected types must:
- Map `instrumentId` instead of `currencyCode`
- Ensure `InstrumentRecord` is synced before records that reference it

## What Needs to Change on Rebase

### 1. Update RecordMapping.swift

Add `CloudKitRecordConvertible` conformance for:
- `InstrumentRecord` — new record type
- `TransactionLegRecord` — new record type

Update mappings for:
- `TransactionRecord` — remove 7 field mappings, keep only header fields
- `AccountRecord` — remove `currencyCode`/`cachedBalance`, add `usesPositionTracking`
- `EarmarkRecord` — remove `currencyCode`, add `savingsTargetInstrumentId`, change `savingsTarget` to Int64
- `EarmarkBudgetItemRecord` — remove `currencyCode`, add `instrumentId`, change `amount` to Int64
- `InvestmentValueRecord` — remove `currencyCode`, add `instrumentId`, change `value` to Int64

### 2. Update ProfileSyncEngine Sync Ordering

When syncing from CloudKit, records must be applied in dependency order:
1. `InstrumentRecord` — no dependencies
2. `CategoryRecord` — no dependencies
3. `AccountRecord` — no dependencies
4. `EarmarkRecord` — references instruments
5. `EarmarkBudgetItemRecord` — references earmarks and instruments
6. `TransactionRecord` — header only, no dependencies
7. `TransactionLegRecord` — references transactions, accounts, instruments

When uploading, `TransactionRecord` and its `TransactionLegRecord`s should be sent together to avoid orphaned legs on the server.

### 3. Update ChangeTracker

The change tracker must handle `TransactionLegRecord` changes. When a transaction is saved, its legs may also be inserted/updated/deleted. The tracker should detect changes to both `TransactionRecord` and `TransactionLegRecord` and queue them as a unit.

### 4. Update project.yml

Ensure `InstrumentRecord` and `TransactionLegRecord` are included in the data schema passed to `ProfileContainerManager`. (This is likely already done on the multi-instrument branch for local persistence, but verify the sync files reference them too.)

### 5. Handle Old CloudKit Data

Since this is a pre-release app, the old `com.apple.coredata.cloudkit.zone` has already been deleted. No backward-compatible field mapping is needed for the old schema. The CKSyncEngine zones will start fresh with the multi-instrument schema.

If users on TestFlight have data from the main-branch CKSyncEngine (with the old schema), a one-time migration would be needed to convert:
- `TransactionRecord` CKRecords (with leg fields) → `TransactionRecord` + `TransactionLegRecord`
- `currencyCode` fields → `instrumentId` references with auto-created `InstrumentRecord`s
- `Int` monetary values → `Int64` (multiply by 10^6 to convert from cents to × 10^8)

Whether this migration is needed depends on timing — if multi-instrument merges before any TestFlight build ships with CKSyncEngine, it's not needed.

## Testing

- Update all `RecordMapping` round-trip tests for the new schema
- Add round-trip tests for `InstrumentRecord` and `TransactionLegRecord`
- Test that transaction + legs sync as a unit (no orphaned legs)
- Test sync ordering: instrument records must arrive before records that reference them
- Verify the existing migration integration tests still pass with CKSyncEngine disabled locally
