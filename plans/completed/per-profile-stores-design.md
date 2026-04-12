# Per-Profile SwiftData Stores

## Problem

The app currently uses a single SwiftData store (`Moolah.store`) for all iCloud profiles. Every data record carries a `profileId` field, and every query includes a `profileId` predicate to partition data. This approach has drawbacks:

- **No database-level isolation** — a missing predicate leaks data across profiles
- **Expensive profile deletion** — `ProfileDataDeleter` must query and delete each record type individually (7 fetch+delete loops)
- **Redundant predicates** — ~50+ `profileId` filters across 7 repositories, adding noise to every query
- **CloudKit sync granularity** — all profiles share a single CloudKit record zone, so sync is all-or-nothing

## Design

Give each iCloud profile its own SwiftData store file and `ModelConfiguration`. SwiftData's `cloudKitDatabase: .automatic` maps each store to its own CloudKit record zone automatically, providing database-level isolation.

### Store Layout

```
~/Library/Application Support/
  Moolah.store              # Profile index (ProfileRecord only)
  Moolah-{profileId}.store  # Per-profile data (accounts, transactions, etc.)
```

- **Index store** — `Moolah.store` with `cloudKitDatabase: .automatic`. Contains only `ProfileRecord`. Syncs the profile list across devices.
- **Data stores** — One per iCloud profile, named `Moolah-{profileId}.store` with `cloudKitDatabase: .automatic`. Contains `AccountRecord`, `TransactionRecord`, `CategoryRecord`, `EarmarkRecord`, `EarmarkBudgetItemRecord`, `InvestmentValueRecord`. Each store gets its own CloudKit zone automatically.

### Schema Split

Two schemas replace the current single schema:

```swift
// Profile index — shared across app
let profileSchema = Schema([ProfileRecord.self])

// Per-profile data — one container per profile
let dataSchema = Schema([
    AccountRecord.self,
    TransactionRecord.self,
    CategoryRecord.self,
    EarmarkRecord.self,
    EarmarkBudgetItemRecord.self,
    InvestmentValueRecord.self,
])
```

### Container Management

A new `ProfileContainerManager` creates and caches `ModelContainer` instances per profile:

```swift
@MainActor
final class ProfileContainerManager {
    private let dataSchema: Schema
    private var containers: [UUID: ModelContainer] = [:]

    /// The shared index container for ProfileRecords.
    let indexContainer: ModelContainer

    /// Returns (or creates) the data container for a specific profile.
    func container(for profileId: UUID) throws -> ModelContainer

    /// Deletes the store files for a profile (called on profile removal).
    func deleteStore(for profileId: UUID) throws
}
```

- `MoolahApp.init()` creates the `ProfileContainerManager` instead of a single `ModelContainer`.
- `ProfileStore` receives the `indexContainer` for profile CRUD.
- `ProfileSession` calls `container(for: profileId)` to get the per-profile container.
- The manager caches containers in memory — they're created lazily on first access and reused for the session lifetime.

### CloudKitBackend Changes

`CloudKitBackend` drops `profileId` from its constructor and all repositories:

```swift
// Before
init(modelContainer: ModelContainer, profileId: UUID, currency: Currency, profileLabel: String)

// After
init(modelContainer: ModelContainer, currency: Currency, profileLabel: String)
```

Each repository drops its `profileId` field. Predicates simplify from:
```swift
#Predicate { $0.profileId == profileId && $0.accountId == accountId }
```
to:
```swift
#Predicate { $0.accountId == accountId }
```

### Model Record Changes

Remove `profileId` from all data records:
- `AccountRecord` — remove `profileId` property, `init` parameter, and `from()` parameter
- `TransactionRecord` — same
- `CategoryRecord` — same
- `EarmarkRecord` — same
- `EarmarkBudgetItemRecord` — same
- `InvestmentValueRecord` — same

`ProfileRecord` is unchanged (it never had `profileId`).

### Profile Deletion

Replace `ProfileDataDeleter` (7 fetch+delete loops) with:

```swift
func deleteProfile(_ id: UUID) {
    // 1. Remove ProfileRecord from index store
    // 2. Delete the store files: Moolah-{id}.store, .store-shm, .store-wal
    // 3. Evict from container cache
}
```

Deleting the store file removes all data atomically. CloudKit zone cleanup happens automatically when SwiftData detects the zone's store is gone.

### ProfileSession Changes

`ProfileSession` receives a per-profile `ModelContainer` instead of the shared one:

```swift
// Before
init(profile: Profile, modelContainer: ModelContainer? = nil)
// Creates CloudKitBackend(modelContainer: container, profileId: profile.id, ...)

// After
init(profile: Profile, modelContainer: ModelContainer? = nil)
// Creates CloudKitBackend(modelContainer: container, ...)
// The container itself is already scoped to this profile
```

The change is internal — the `modelContainer` parameter now receives the per-profile container from `ProfileContainerManager` instead of the shared one.

### MoolahApp Changes

```swift
// Before: single container
private let container: ModelContainer

// After: container manager
private let containerManager: ProfileContainerManager
```

The `.modelContainer(container)` modifier on `WindowGroup` changes to use the index container. Per-profile containers are passed through `ProfileSession`, not the SwiftUI environment.

### TestBackend Changes

`TestModelContainer.create()` returns a data-schema-only in-memory container (no `ProfileRecord`). This matches the per-profile store — tests already create isolated containers per test, so the pattern is unchanged.

`TestBackend.create()` drops the `profileId` parameter since it's no longer needed.

### Multi-Device Sync

Each store syncs independently via its own CloudKit zone:
- The index store syncs `ProfileRecord` — new profiles appear on other devices automatically via the existing `.NSPersistentStoreRemoteChange` observer in `ProfileStore`.
- When a new profile arrives on a second device, `ProfileContainerManager.container(for:)` creates the store file. SwiftData automatically pulls the profile's data from the corresponding CloudKit zone.
- Profile deletion on one device removes the `ProfileRecord` from the index store. Other devices detect this via the remote change observer and can clean up the local store file.

## Files Changed

| File | Change |
|------|--------|
| `App/MoolahApp.swift` | Replace single container with `ProfileContainerManager` |
| `App/ProfileSession.swift` | Receive per-profile container, drop profileId from backend init |
| `Backends/CloudKit/CloudKitBackend.swift` | Drop profileId parameter |
| `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift` | Drop profileId from all predicates |
| `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift` | Drop profileId from all predicates (~15 locations) |
| `Backends/CloudKit/Repositories/CloudKitCategoryRepository.swift` | Drop profileId from all predicates |
| `Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift` | Drop profileId from all predicates |
| `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift` | Drop profileId from all predicates |
| `Backends/CloudKit/Repositories/CloudKitInvestmentRepository.swift` | Drop profileId from all predicates |
| `Backends/CloudKit/Models/AccountRecord.swift` | Remove profileId field |
| `Backends/CloudKit/Models/TransactionRecord.swift` | Remove profileId field |
| `Backends/CloudKit/Models/CategoryRecord.swift` | Remove profileId field |
| `Backends/CloudKit/Models/EarmarkRecord.swift` | Remove profileId field |
| `Backends/CloudKit/Models/EarmarkBudgetItemRecord.swift` | Remove profileId field |
| `Backends/CloudKit/Models/InvestmentValueRecord.swift` | Remove profileId field |
| `Backends/CloudKit/ProfileDataDeleter.swift` | Replace with store file deletion |
| `MoolahTests/Support/TestModelContainer.swift` | Remove ProfileRecord from schema |
| `MoolahTests/Support/TestBackend.swift` | Drop profileId parameter |
| `MoolahTests/CloudKit/MultiProfileIsolationTests.swift` | Use separate containers instead of profileId |
| `MoolahTests/CloudKit/ProfileDataDeleterTests.swift` | Test store file deletion |
| All contract tests and store tests | Remove profileId from TestBackend.create() calls |
| **New:** `Shared/ProfileContainerManager.swift` | Container lifecycle management |
