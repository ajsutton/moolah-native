# Per-Profile SwiftData Stores Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each iCloud profile its own SwiftData store file so data isolation is enforced at the database level, profileId predicates are eliminated, and profile deletion becomes an atomic file delete.

**Architecture:** A shared "index" store (`Moolah.store`) holds `ProfileRecord`s. Each iCloud profile gets a per-profile store (`Moolah-{id}.store`) containing all its data records. A `ProfileContainerManager` creates and caches `ModelContainer` instances per profile. All 6 data model records lose their `profileId` field, and all repositories lose their `profileId` predicates.

**Tech Stack:** SwiftData, CloudKit (automatic sync), Swift Testing

**Spec:** `plans/per-profile-stores-design.md`

---

### Task 1: Create ProfileContainerManager

The central new type that manages store lifecycle — index container for ProfileRecords, per-profile containers for data.

**Files:**
- Create: `Shared/ProfileContainerManager.swift`
- Test: `MoolahTests/App/ProfileContainerManagerTests.swift`

- [ ] **Step 1: Write tests for ProfileContainerManager**

```swift
// MoolahTests/App/ProfileContainerManagerTests.swift
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ProfileContainerManager")
struct ProfileContainerManagerTests {
  @Test("creates index container with ProfileRecord schema only")
  @MainActor
  func testIndexContainerSchema() throws {
    let manager = try ProfileContainerManager.forTesting()
    let context = ModelContext(manager.indexContainer)
    // ProfileRecord should be fetchable
    let descriptor = FetchDescriptor<ProfileRecord>()
    let profiles = try context.fetch(descriptor)
    #expect(profiles.isEmpty)
  }

  @Test("creates per-profile container with data schema only")
  @MainActor
  func testProfileContainerSchema() throws {
    let manager = try ProfileContainerManager.forTesting()
    let profileId = UUID()
    let container = try manager.container(for: profileId)
    let context = ModelContext(container)

    // Data records should be fetchable
    let accounts = try context.fetch(FetchDescriptor<AccountRecord>())
    #expect(accounts.isEmpty)
    let transactions = try context.fetch(FetchDescriptor<TransactionRecord>())
    #expect(transactions.isEmpty)
  }

  @Test("returns same container for same profile ID")
  @MainActor
  func testContainerCaching() throws {
    let manager = try ProfileContainerManager.forTesting()
    let profileId = UUID()
    let container1 = try manager.container(for: profileId)
    let container2 = try manager.container(for: profileId)
    #expect(container1 === container2)
  }

  @Test("returns different containers for different profiles")
  @MainActor
  func testContainerIsolation() throws {
    let manager = try ProfileContainerManager.forTesting()
    let container1 = try manager.container(for: UUID())
    let container2 = try manager.container(for: UUID())
    #expect(container1 !== container2)
  }

  @Test("deleteStore removes container from cache")
  @MainActor
  func testDeleteStore() throws {
    let manager = try ProfileContainerManager.forTesting()
    let profileId = UUID()
    let container1 = try manager.container(for: profileId)
    manager.deleteStore(for: profileId)
    let container2 = try manager.container(for: profileId)
    #expect(container1 !== container2)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test-mac`
Expected: FAIL — `ProfileContainerManager` not defined

- [ ] **Step 3: Implement ProfileContainerManager**

```swift
// Shared/ProfileContainerManager.swift
import Foundation
import SwiftData

@MainActor
final class ProfileContainerManager {
  let indexContainer: ModelContainer
  private let dataSchema: Schema
  private let cloudKitDatabase: ModelConfiguration.CloudKitDatabase
  private let inMemory: Bool
  private var containers: [UUID: ModelContainer] = [:]

  init(
    indexContainer: ModelContainer,
    dataSchema: Schema,
    cloudKitDatabase: ModelConfiguration.CloudKitDatabase = .automatic,
    inMemory: Bool = false
  ) {
    self.indexContainer = indexContainer
    self.dataSchema = dataSchema
    self.cloudKitDatabase = cloudKitDatabase
    self.inMemory = inMemory
  }

  func container(for profileId: UUID) throws -> ModelContainer {
    if let existing = containers[profileId] {
      return existing
    }
    let config: ModelConfiguration
    if inMemory {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    } else {
      let url = URL.applicationSupportDirectory
        .appending(path: "Moolah-\(profileId.uuidString).store")
      config = ModelConfiguration(url: url, cloudKitDatabase: cloudKitDatabase)
    }
    let container = try ModelContainer(for: dataSchema, configurations: [config])
    containers[profileId] = container
    return container
  }

  func deleteStore(for profileId: UUID) {
    containers.removeValue(forKey: profileId)

    guard !inMemory else { return }

    let base = URL.applicationSupportDirectory
      .appending(path: "Moolah-\(profileId.uuidString).store")
    let fm = FileManager.default
    for suffix in ["", "-shm", "-wal"] {
      let url = base.deletingLastPathComponent()
        .appending(path: base.lastPathComponent + suffix)
      try? fm.removeItem(at: url)
    }
  }

  /// Creates a test-only manager with in-memory stores.
  static func forTesting() throws -> ProfileContainerManager {
    let indexSchema = Schema([ProfileRecord.self])
    let indexConfig = ModelConfiguration(isStoredInMemoryOnly: true)
    let indexContainer = try ModelContainer(for: indexSchema, configurations: [indexConfig])

    let dataSchema = Schema([
      AccountRecord.self,
      TransactionRecord.self,
      CategoryRecord.self,
      EarmarkRecord.self,
      EarmarkBudgetItemRecord.self,
      InvestmentValueRecord.self,
    ])

    return ProfileContainerManager(
      indexContainer: indexContainer,
      dataSchema: dataSchema,
      inMemory: true
    )
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test-mac`
Expected: All ProfileContainerManager tests pass

- [ ] **Step 5: Commit**

```
feat: add ProfileContainerManager for per-profile SwiftData stores
```

---

### Task 2: Remove profileId from model records

Remove the `profileId` field from all 6 data model records. This is a schema change — the records will no longer carry profile scoping because the store itself provides isolation.

**Files:**
- Modify: `Backends/CloudKit/Models/AccountRecord.swift`
- Modify: `Backends/CloudKit/Models/TransactionRecord.swift`
- Modify: `Backends/CloudKit/Models/CategoryRecord.swift`
- Modify: `Backends/CloudKit/Models/EarmarkRecord.swift`
- Modify: `Backends/CloudKit/Models/EarmarkBudgetItemRecord.swift`
- Modify: `Backends/CloudKit/Models/InvestmentValueRecord.swift`

- [ ] **Step 1: Remove profileId from AccountRecord**

In `AccountRecord.swift`:
- Remove `var profileId: UUID` (line 9)
- Remove `profileId: UUID` from `init` parameter list and body
- Remove `profileId: UUID` from `static func from()` parameter list and body

- [ ] **Step 2: Remove profileId from TransactionRecord**

In `TransactionRecord.swift`:
- Remove `var profileId: UUID` (line 9)
- Remove `profileId: UUID` from `init` parameter list and body
- Remove `profileId: UUID` from `static func from()` parameter list — note this also means removing it from the `TransactionRecord(...)` call inside `from()`

- [ ] **Step 3: Remove profileId from CategoryRecord**

In `CategoryRecord.swift`:
- Remove `var profileId: UUID` (line 9)
- Remove `profileId: UUID` from `init` parameter list and body
- Remove `profileId: UUID` from `static func from()` parameter list and body

- [ ] **Step 4: Remove profileId from EarmarkRecord**

In `EarmarkRecord.swift`:
- Remove `var profileId: UUID` (line 9)
- Remove `profileId: UUID` from `init` parameter list and body
- Remove `profileId: UUID` from `static func from()` parameter list and body

- [ ] **Step 5: Remove profileId from EarmarkBudgetItemRecord**

In `EarmarkBudgetItemRecord.swift`:
- Remove `var profileId: UUID` (line 9)
- Remove `profileId: UUID` from `init` parameter list and body

- [ ] **Step 6: Remove profileId from InvestmentValueRecord**

In `InvestmentValueRecord.swift`:
- Remove `var profileId: UUID` (line 9)
- Remove `profileId: UUID` from `init` parameter list and body

- [ ] **Step 7: Do NOT build yet** — this will cause widespread compilation errors that are fixed in the next tasks. Commit the model changes:

```
refactor: remove profileId field from all data model records
```

---

### Task 3: Update CloudKitBackend and all repositories

Remove `profileId` from the backend constructor and all 6 repositories. Remove all `profileId` predicates from queries.

**Files:**
- Modify: `Backends/CloudKit/CloudKitBackend.swift`
- Modify: `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift`
- Modify: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift`
- Modify: `Backends/CloudKit/Repositories/CloudKitCategoryRepository.swift`
- Modify: `Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift`
- Modify: `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift`
- Modify: `Backends/CloudKit/Repositories/CloudKitInvestmentRepository.swift`

- [ ] **Step 1: Update CloudKitBackend**

Remove `profileId: UUID` from the `init` parameter. Update all repository constructor calls to drop `profileId`:

```swift
// CloudKitBackend.swift
init(modelContainer: ModelContainer, currency: Currency, profileLabel: String) {
    self.auth = CloudKitAuthProvider(profileLabel: profileLabel)
    self.accounts = CloudKitAccountRepository(
      modelContainer: modelContainer, currency: currency)
    self.transactions = CloudKitTransactionRepository(
      modelContainer: modelContainer, currency: currency)
    self.categories = CloudKitCategoryRepository(
      modelContainer: modelContainer)
    self.earmarks = CloudKitEarmarkRepository(
      modelContainer: modelContainer, currency: currency)
    self.analysis = CloudKitAnalysisRepository(
      modelContainer: modelContainer, currency: currency)
    self.investments = CloudKitInvestmentRepository(
      modelContainer: modelContainer, currency: currency)
}
```

- [ ] **Step 2: Update CloudKitAccountRepository**

- Remove `private let profileId: UUID` field
- Remove `profileId: UUID` from `init` parameters
- In every method, remove `$0.profileId == profileId` from all `#Predicate` expressions and remove `let profileId = self.profileId` local bindings
- Remove `profileId:` argument from `AccountRecord.from()` and `TransactionRecord(profileId:...)` calls — pass no profileId since the field no longer exists

Key locations to update:
- `fetchAll()`: Remove profileId from predicate (line 23)
- `create()`: Remove profileId from `AccountRecord.from()` (line 50) and `TransactionRecord(...)` (line 57)
- `update()`: Remove profileId from predicate (line 80)
- `delete()`: Remove profileId from predicate (line 110)
- `recomputeAllBalances()`: Remove profileId from predicate (line 138)
- `computeBalance()`: Remove profileId from predicates (lines 174, 183, 194)
- `latestInvestmentValue()`: Remove profileId from predicate (line 207)

- [ ] **Step 3: Update CloudKitCategoryRepository**

- Remove `private let profileId: UUID` field and `profileId: UUID` from `init`
- Remove `$0.profileId == profileId` from all predicates in `fetchAll()`, `create()`, `update()`, `delete()`
- Remove `profileId:` from `CategoryRecord.from()` call
- Remove `$0.profileId == profileId` from the child, budget item, and existing budget predicates in `delete()`

- [ ] **Step 4: Update CloudKitEarmarkRepository**

- Remove `private let profileId: UUID` field and `profileId: UUID` from `init`
- Remove all profileId predicates from `fetchAll()`, `create()`, `update()`, `fetchBudget()`, `setBudget()`, `computeEarmarkTotals()`
- Remove `profileId:` from `EarmarkRecord.from()` and `EarmarkBudgetItemRecord(...)` calls

- [ ] **Step 5: Update CloudKitInvestmentRepository**

- Remove `private let profileId: UUID` field and `profileId: UUID` from `init`
- Remove all profileId predicates from `fetchValues()`, `setValue()`, `removeValue()`, `fetchDailyBalances()`
- Remove `profileId:` from `InvestmentValueRecord(...)` call

- [ ] **Step 6: Update CloudKitAnalysisRepository**

- Remove `private let profileId: UUID` field and `profileId: UUID` from `init`
- Remove profileId from predicates in `fetchTransactions()` (line 75), `fetchAccounts()` (line 90), and `fetchAllInvestmentValues()` (line 203)

- [ ] **Step 7: Update CloudKitTransactionRepository**

This is the largest repository. The pattern is the same throughout:
- Remove `private let profileId: UUID` field and `profileId: UUID` from `init`
- Remove `let profileId = self.profileId` local bindings
- Remove `profileId: UUID` from `fetchRecords()` and `buildDescriptor()` parameter lists
- In `buildDescriptor()`, every `#Predicate` branch has `$0.profileId == profileId &&` — remove it from all ~20 predicate expressions
- Remove `profileId:` from `TransactionRecord.from()` and `TransactionRecord(...)` calls in `create()`, `update()`, `payScheduled()`, etc.

- [ ] **Step 8: Do NOT build yet** — test helpers and callers still need updating. Commit:

```
refactor: remove profileId from CloudKitBackend and all repositories
```

---

### Task 4: Update ProfileDataDeleter and ProfileStore

Replace record-by-record deletion with store file deletion. Update ProfileStore to use `ProfileContainerManager`.

**Files:**
- Modify: `Backends/CloudKit/ProfileDataDeleter.swift`
- Modify: `Features/Profiles/ProfileStore.swift`

- [ ] **Step 1: Simplify ProfileDataDeleter**

The deleter now only needs to remove the `ProfileRecord` from the index store. Data deletion happens by deleting the store file via `ProfileContainerManager.deleteStore()`.

```swift
// Backends/CloudKit/ProfileDataDeleter.swift
import Foundation
import SwiftData

/// Deletes a profile's ProfileRecord from the index store.
/// The per-profile data store is deleted separately via ProfileContainerManager.
struct ProfileDataDeleter {
  let modelContext: ModelContext

  @MainActor
  func deleteProfileRecord(for profileId: UUID) {
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    )
    if let records = try? modelContext.fetch(descriptor) {
      for record in records { modelContext.delete(record) }
    }
    try? modelContext.save()
  }
}
```

- [ ] **Step 2: Update ProfileStore to use ProfileContainerManager**

In `ProfileStore.swift`:
- Replace `private let modelContainer: ModelContainer?` with `private let containerManager: ProfileContainerManager?`
- Update `init` to accept `ProfileContainerManager?` instead of `ModelContainer?`
- In `addProfile()`, use `containerManager?.indexContainer` for the context
- In `removeProfile()`, call `containerManager?.deleteStore(for: id)` for CloudKit profiles, then delete the ProfileRecord from the index context
- In `loadCloudProfiles()`, use `containerManager?.indexContainer`
- In `updateProfile()`, use `containerManager?.indexContainer`
- In `observeRemoteChanges()`, use `containerManager?.indexContainer`

The key change in `removeProfile()`:

```swift
} else if let index = cloudProfiles.firstIndex(where: { $0.id == id }) {
    cloudProfiles.remove(at: index)

    if let containerManager {
        // Delete per-profile data store files
        containerManager.deleteStore(for: id)
        // Remove ProfileRecord from index store
        let context = ModelContext(containerManager.indexContainer)
        let deleter = ProfileDataDeleter(modelContext: context)
        deleter.deleteProfileRecord(for: id)
    }
}
```

- [ ] **Step 3: Commit**

```
refactor: update ProfileStore and ProfileDataDeleter for per-profile stores
```

---

### Task 5: Update ProfileSession, MoolahApp, and PreviewBackend

Wire the `ProfileContainerManager` through the app entry point and session creation.

**Files:**
- Modify: `App/MoolahApp.swift`
- Modify: `App/ProfileSession.swift`
- Modify: `App/ProfileRootView.swift`
- Modify: `App/ProfileWindowView.swift` (if it passes modelContainer)
- Modify: `Shared/PreviewBackend.swift`

- [ ] **Step 1: Update MoolahApp**

Replace the single `ModelContainer` with `ProfileContainerManager`:

```swift
@main
@MainActor
struct MoolahApp: App {
  private let containerManager: ProfileContainerManager
  @State private var profileStore: ProfileStore
  // ... rest unchanged

  init() {
    do {
      let profileSchema = Schema([ProfileRecord.self])
      let profileStoreURL = URL.applicationSupportDirectory.appending(path: "Moolah.store")
      let profileConfig = ModelConfiguration(
        url: profileStoreURL,
        cloudKitDatabase: .automatic
      )
      let indexContainer = try ModelContainer(for: profileSchema, configurations: [profileConfig])

      let dataSchema = Schema([
        AccountRecord.self,
        TransactionRecord.self,
        CategoryRecord.self,
        EarmarkRecord.self,
        EarmarkBudgetItemRecord.self,
        InvestmentValueRecord.self,
      ])

      let manager = ProfileContainerManager(
        indexContainer: indexContainer,
        dataSchema: dataSchema
      )
      containerManager = manager
    } catch {
      fatalError("Failed to initialize ModelContainer: \(error)")
    }

    let store = ProfileStore(validator: RemoteServerValidator(), containerManager: containerManager)
    _profileStore = State(initialValue: store)

    #if os(macOS)
      _sessionManager = State(initialValue: SessionManager(containerManager: containerManager))
    #endif
  }
```

Update the `body` to use `containerManager.indexContainer` for `.modelContainer()`:

```swift
.modelContainer(containerManager.indexContainer)
```

- [ ] **Step 2: Update ProfileSession**

Change to accept `ProfileContainerManager?` and get the per-profile container:

```swift
init(profile: Profile, containerManager: ProfileContainerManager? = nil) {
    self.profile = profile

    let backend: BackendProvider
    switch profile.backendType {
    case .remote, .moolah:
      // ... unchanged
    case .cloudKit:
      guard let containerManager else {
        fatalError("ProfileContainerManager is required for CloudKit profiles")
      }
      let profileContainer = try! containerManager.container(for: profile.id)
      backend = CloudKitBackend(
        modelContainer: profileContainer,
        currency: profile.currency,
        profileLabel: profile.label
      )
    }
    // ... rest unchanged
}
```

- [ ] **Step 3: Update ProfileRootView and ProfileWindowView**

These views create `ProfileSession` — update them to pass `containerManager` instead of `modelContext.container`. Look for where `ProfileSession(profile:, modelContainer:)` is called and change to `ProfileSession(profile:, containerManager:)`. The `containerManager` should be passed via `@Environment`.

In `MoolahApp`, add `.environment(containerManager)` to the view hierarchy.

- [ ] **Step 4: Update SessionManager (macOS)**

Check `App/SessionManager.swift` — update its `init` to accept `ProfileContainerManager` and pass it when creating sessions.

- [ ] **Step 5: Update PreviewBackend**

```swift
// Shared/PreviewBackend.swift
enum PreviewBackend {
  static func create(currency: Currency = .AUD) -> (CloudKitBackend, ModelContainer) {
    let schema = Schema([
      AccountRecord.self,
      TransactionRecord.self,
      CategoryRecord.self,
      EarmarkRecord.self,
      EarmarkBudgetItemRecord.self,
      InvestmentValueRecord.self,
    ])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: schema, configurations: [config])
    let backend = CloudKitBackend(
      modelContainer: container,
      currency: currency, profileLabel: "Preview"
    )
    return (backend, container)
  }
}
```

Note: `ProfileRecord` removed from schema (it's in the index store), `profileId` removed from `CloudKitBackend` init, and return tuple no longer includes `profileId`.

- [ ] **Step 6: Fix any remaining callers of old PreviewBackend signature**

Search for `PreviewBackend.create` across the codebase and update callers that destructure the tuple — they no longer get a `profileId`.

- [ ] **Step 7: Commit**

```
refactor: wire ProfileContainerManager through app entry point and sessions
```

---

### Task 6: Update migration code

The migration importer, verifier, and coordinator need to drop profileId.

**Files:**
- Modify: `Backends/CloudKit/Migration/CloudKitDataImporter.swift`
- Modify: `Backends/CloudKit/Migration/MigrationVerifier.swift`
- Modify: `Backends/CloudKit/Migration/MigrationCoordinator.swift`
- Modify: `Features/Migration/MigrationView.swift`

- [ ] **Step 1: Update CloudKitDataImporter**

- Remove `private let profileId: UUID` field
- Remove `profileId: UUID` from `init` parameters
- Remove all `profileId:` arguments from record constructor calls throughout `importData()`
- Remove the profileId-filtered verification query near the end (lines 157-163) — the store is already profile-scoped, so an unfiltered `FetchDescriptor<AccountRecord>()` is sufficient

- [ ] **Step 2: Update MigrationVerifier**

- Remove `profileId: UUID` from `verify()` parameter list
- Remove `$0.profileId == profileId` from all 5 predicate expressions — use unfiltered `FetchDescriptor` for each record type

- [ ] **Step 3: Update MigrationCoordinator**

- In `migrate()`, update `CloudKitDataImporter` construction to drop `profileId:` parameter
- Update `MigrationVerifier.verify()` call to drop `profileId:` parameter
- The coordinator should receive a `ProfileContainerManager` instead of a plain `ModelContainer`, and use `containerManager.container(for: newProfileId)` to get the target container

- [ ] **Step 4: Update MigrationView**

- Update the `CloudKitDataImporter` construction to drop `profileId:`

- [ ] **Step 5: Commit**

```
refactor: remove profileId from migration code
```

---

### Task 7: Update TestBackend, TestModelContainer, and all tests

This is the largest task by file count but is repetitive. Remove profileId from test infrastructure and all test call sites.

**Files:**
- Modify: `MoolahTests/Support/TestModelContainer.swift`
- Modify: `MoolahTests/Support/TestBackend.swift`
- Modify: `MoolahTests/CloudKit/MultiProfileIsolationTests.swift`
- Modify: `MoolahTests/CloudKit/ProfileDataDeleterTests.swift`
- Modify: All test files that call `TestBackend.create()` or `TestBackend.seed()`
- Modify: All migration test files

- [ ] **Step 1: Update TestModelContainer**

Remove `ProfileRecord` from the schema since data stores don't contain it:

```swift
enum TestModelContainer {
  static func create() throws -> ModelContainer {
    let schema = Schema([
      AccountRecord.self,
      TransactionRecord.self,
      CategoryRecord.self,
      EarmarkRecord.self,
      EarmarkBudgetItemRecord.self,
      InvestmentValueRecord.self,
    ])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
  }
}
```

- [ ] **Step 2: Update TestBackend**

Remove `profileId` from `create()` and all `seed()` methods:

```swift
enum TestBackend {
  static func create(
    currency: Currency = .defaultTestCurrency
  ) throws -> (backend: CloudKitBackend, container: ModelContainer) {
    let container = try TestModelContainer.create()
    let backend = CloudKitBackend(
      modelContainer: container,
      currency: currency,
      profileLabel: "Test"
    )
    return (backend, container)
  }

  @discardableResult
  static func seed(
    accounts: [Account],
    in container: ModelContainer,
    currency: Currency = .defaultTestCurrency
  ) -> [Account] {
    let context = ModelContext(container)
    for account in accounts {
      context.insert(AccountRecord.from(account, currencyCode: currency.code))
      if account.balance.cents != 0 {
        let txn = TransactionRecord(
          type: TransactionType.openingBalance.rawValue,
          date: Date(),
          accountId: account.id,
          amount: account.balance.cents,
          currencyCode: currency.code
        )
        context.insert(txn)
      }
    }
    try! context.save()
    return accounts
  }

  // Same pattern for all other seed methods — remove profileId parameter
  // and drop it from record constructor calls
}
```

Apply the same pattern to `seed(transactions:)`, `seed(earmarks:)`, `seedWithTransactions(earmarks:)`, `seed(categories:)`, `seed(investmentValues:)`, and `seedBudget()`.

- [ ] **Step 3: Update MultiProfileIsolationTests**

These tests now use separate containers instead of profileId:

```swift
@Suite("Multi-Profile Isolation")
struct MultiProfileIsolationTests {
  @Test("two CloudKit backends with separate containers see only their own data")
  @MainActor
  func testProfileIsolation() async throws {
    let (backendA, _) = try TestBackend.create()
    let (backendB, _) = try TestBackend.create()

    _ = try await backendA.categories.create(Moolah.Category(name: "Groceries"))
    _ = try await backendA.categories.create(Moolah.Category(name: "Transport"))
    _ = try await backendB.categories.create(Moolah.Category(name: "Entertainment"))

    let categoriesA = try await backendA.categories.fetchAll()
    #expect(categoriesA.count == 2)

    let categoriesB = try await backendB.categories.fetchAll()
    #expect(categoriesB.count == 1)
    #expect(categoriesB[0].name == "Entertainment")
  }

  @Test("deleting one profile's store doesn't affect another")
  @MainActor
  func testDeleteIsolation() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let profileA = UUID()
    let profileB = UUID()

    let containerA = try manager.container(for: profileA)
    let containerB = try manager.container(for: profileB)

    let backendA = CloudKitBackend(
      modelContainer: containerA, currency: .defaultTestCurrency, profileLabel: "A")
    let backendB = CloudKitBackend(
      modelContainer: containerB, currency: .defaultTestCurrency, profileLabel: "B")

    _ = try await backendA.categories.create(Moolah.Category(name: "A-Cat"))
    _ = try await backendB.categories.create(Moolah.Category(name: "B-Cat"))

    // Delete profile A's store
    manager.deleteStore(for: profileA)

    // Profile B should be unaffected
    let categoriesB = try await backendB.categories.fetchAll()
    #expect(categoriesB.count == 1)
    #expect(categoriesB[0].name == "B-Cat")
  }
}
```

- [ ] **Step 4: Update ProfileDataDeleterTests**

Update to test the simplified deleter (ProfileRecord deletion from index store only):

```swift
@Suite("ProfileDataDeleter")
struct ProfileDataDeleterTests {
  @Test("deletes ProfileRecord from index store")
  @MainActor
  func testDeleteProfileRecord() throws {
    let schema = Schema([ProfileRecord.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    let context = ModelContext(container)

    let profileId = UUID()
    let record = ProfileRecord(id: profileId, label: "Test", currencyCode: "AUD")
    context.insert(record)
    try context.save()

    let deleter = ProfileDataDeleter(modelContext: context)
    deleter.deleteProfileRecord(for: profileId)

    let descriptor = FetchDescriptor<ProfileRecord>()
    let remaining = try context.fetch(descriptor)
    #expect(remaining.isEmpty)
  }
}
```

- [ ] **Step 5: Update all feature store tests**

Every test file that calls `TestBackend.create()` currently destructures as:
```swift
let (backend, container, profileId) = try TestBackend.create()
```

Change all to:
```swift
let (backend, container) = try TestBackend.create()
```

Every `TestBackend.seed()` call currently passes `profileId:`. Remove that parameter from all calls. For example:
```swift
// Before
TestBackend.seed(accounts: [...], in: container, profileId: profileId)
// After
TestBackend.seed(accounts: [...], in: container)
```

Affected test files (update all `TestBackend.create()` and `TestBackend.seed()` calls):
- `MoolahTests/Features/AccountStoreTests.swift`
- `MoolahTests/Features/TransactionStoreTests.swift`
- `MoolahTests/Features/EarmarkStoreTests.swift`
- `MoolahTests/Features/InvestmentStoreTests.swift`
- `MoolahTests/Features/EarmarkBudgetTests.swift`
- `MoolahTests/Features/AuthStoreTests.swift`
- `MoolahTests/Features/AnalysisStoreTests.swift`
- `MoolahTests/Features/ProfileStoreTests.swift`
- `MoolahTests/Domain/AccountRepositoryContractTests.swift`
- `MoolahTests/Domain/TransactionRepositoryContractTests.swift`
- `MoolahTests/Domain/CategoryRepositoryContractTests.swift`
- `MoolahTests/Domain/EarmarkRepositoryContractTests.swift`
- `MoolahTests/Domain/InvestmentRepositoryContractTests.swift`
- `MoolahTests/Domain/AnalysisRepositoryContractTests.swift`
- `MoolahTests/App/SessionManagerTests.swift`

- [ ] **Step 6: Update migration tests**

Update all migration test files to remove `profileId` from `CloudKitDataImporter`, `MigrationVerifier`, and record constructor calls:
- `MoolahTests/Migration/CloudKitDataImporterTests.swift`
- `MoolahTests/Migration/MigrationVerifierTests.swift`
- `MoolahTests/Migration/MigrationIntegrationTests.swift`

- [ ] **Step 7: Commit**

```
refactor: remove profileId from all test code
```

---

### Task 8: Build, test, and fix

Verify everything compiles and all tests pass.

- [ ] **Step 1: Build for macOS**

Run: `just build-mac`
Expected: BUILD SUCCEEDED with no warnings

- [ ] **Step 2: Run full test suite**

Run: `just test`
Expected: All tests pass on both platforms

- [ ] **Step 3: Fix any remaining compilation errors or test failures**

Common issues to check:
- Any remaining `profileId` references the compiler flags
- Record constructors that still pass `profileId:`
- Predicates that still reference `$0.profileId`
- Preview providers that use the old `PreviewBackend` tuple shape

- [ ] **Step 4: Check for compiler warnings**

Use Xcode MCP: `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"` and fix any warnings in user code.

- [ ] **Step 5: Commit any fixes**

```
fix: resolve remaining compilation issues from profileId removal
```

---

### Task 9: Delete old Moolah.store and update existing store

Clean up the old single store that had all record types.

- [ ] **Step 1: Delete old store file from disk**

```bash
rm ~/Library/Application\ Support/Moolah.store*
```

The next app launch will create a fresh index-only `Moolah.store` and per-profile data stores as needed.

- [ ] **Step 2: Final verification — run the app from Xcode**

1. Launch the macOS app
2. Create an iCloud profile
3. Add an account and a transaction
4. Quit the app
5. Relaunch — verify the profile, account, and transaction all persist
6. Verify the store files exist:
   ```bash
   ls ~/Library/Application\ Support/Moolah*.store
   ```
   Expected: `Moolah.store` (index) and `Moolah-{uuid}.store` (data)

- [ ] **Step 3: Commit all changes**

```
feat: per-profile SwiftData stores with CloudKit zone isolation
```
