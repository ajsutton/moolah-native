# iCloud Migration — Data Migration from moolah-server

**Date:** 2026-04-08
**Component:** Data Migration
**Parent plan:** [ICLOUD_MIGRATION_PLAN.md](./ICLOUD_MIGRATION_PLAN.md)

## Overview

This plan describes the one-time migration of existing user data from the moolah-server REST API to the local SwiftData/CloudKit storage. This is the **highest-risk** part of the iCloud migration — data loss or corruption during migration would be unacceptable for a financial application.

---

## User Experience Flow

### Happy Path
1. User opens the app (currently signed in via Google OAuth to moolah-server)
2. App detects this is the first launch with iCloud backend available
3. App shows **"Migrate to iCloud"** screen explaining the change
4. User taps **"Start Migration"**
5. Progress indicator shows: "Downloading accounts... categories... earmarks... transactions (page 1 of N)..."
6. Progress indicator shows: "Saving to iCloud..."
7. **"Migration Complete"** screen with summary (X accounts, Y transactions, etc.)
8. User taps **"Continue"** → app switches to CloudKit backend
9. Old session cookies are cleared

### Error Path
1. Migration fails at any step → error screen with details
2. User can tap **"Retry"** to restart from the beginning
3. All partial imports are rolled back (SwiftData context discarded without saving)
4. User can also tap **"Skip for Now"** to continue using the server backend

### No Data Path
- User has no data on the server (fresh account)
- Migration completes instantly with "0 items migrated"
- App switches to CloudKit backend

---

## Architecture

### Code Structure

```
Backends/CloudKit/Migration/
├── ServerDataExporter.swift      # Fetches all data from REST API
├── CloudKitDataImporter.swift    # Writes data to SwiftData
└── MigrationCoordinator.swift    # Orchestrates the full flow

Features/Migration/
├── MigrationView.swift           # Migration UI
└── MigrationStore.swift          # @Observable state management
```

### Component Responsibilities

| Component | Input | Output |
|-----------|-------|--------|
| `ServerDataExporter` | Authenticated `APIClient` | `ExportedData` struct |
| `CloudKitDataImporter` | `ExportedData` + `ModelContext` | Imported record counts |
| `MigrationCoordinator` | Both of the above | Success/failure result |

---

## Phase 1: Export from Server

### ServerDataExporter

```swift
struct ExportedData: Sendable {
  let accounts: [Account]
  let categories: [Category]
  let earmarks: [Earmark]
  let earmarkBudgets: [UUID: [EarmarkBudgetItem]]  // keyed by earmarkId
  let transactions: [Transaction]
}

actor ServerDataExporter {
  private let accountRepo: AccountRepository
  private let categoryRepo: CategoryRepository
  private let earmarkRepo: EarmarkRepository
  private let transactionRepo: TransactionRepository

  enum ExportProgress: Sendable {
    case downloading(step: String)
    case downloadComplete(ExportedData)
    case failed(Error)
  }

  func export(
    progress: @escaping @Sendable (ExportProgress) -> Void
  ) async throws -> ExportedData {
    // 1. Accounts (single request)
    progress(.downloading(step: "accounts"))
    let accounts = try await accountRepo.fetchAll()

    // 2. Categories (single request)
    progress(.downloading(step: "categories"))
    let categories = try await categoryRepo.fetchAll()

    // 3. Earmarks + budgets
    progress(.downloading(step: "earmarks"))
    let earmarks = try await earmarkRepo.fetchAll()
    var budgets: [UUID: [EarmarkBudgetItem]] = [:]
    for earmark in earmarks {
      budgets[earmark.id] = try await earmarkRepo.fetchBudget(earmarkId: earmark.id)
    }

    // 4. Transactions (paginated — may require many requests)
    progress(.downloading(step: "transactions"))
    let transactions = try await fetchAllTransactions()

    let data = ExportedData(
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      earmarkBudgets: budgets,
      transactions: transactions
    )
    progress(.downloadComplete(data))
    return data
  }

  private func fetchAllTransactions() async throws -> [Transaction] {
    var allTransactions: [Transaction] = []
    var page = 0
    let pageSize = 200  // larger pages for bulk export

    while true {
      // Fetch ALL transactions (no filter) including scheduled
      let result = try await transactionRepo.fetch(
        filter: TransactionFilter(),
        page: page,
        pageSize: pageSize
      )
      allTransactions.append(contentsOf: result.transactions)

      if result.transactions.count < pageSize {
        break  // last page
      }
      page += 1
    }

    // Also fetch scheduled transactions explicitly
    // (the default filter may exclude them)
    var scheduledPage = 0
    while true {
      let result = try await transactionRepo.fetch(
        filter: TransactionFilter(scheduled: true),
        page: scheduledPage,
        pageSize: pageSize
      )

      // Add only transactions we haven't seen
      let existingIds = Set(allTransactions.map(\.id))
      let newTransactions = result.transactions.filter { !existingIds.contains($0.id) }
      allTransactions.append(contentsOf: newTransactions)

      if result.transactions.count < pageSize {
        break
      }
      scheduledPage += 1
    }

    return allTransactions
  }
}
```

### Pagination Handling

The server returns transactions in pages. A user with thousands of transactions may require dozens of requests. Key considerations:

- **Page size:** Use 200 (larger than the default 50) to minimize round-trips
- **Completeness check:** `transactions.count < pageSize` indicates the last page
- **Scheduled transactions:** Fetch separately with `scheduled: true` filter to ensure none are missed (the default fetch without `scheduled` filter returns all transactions on the server, but verify this)
- **Deduplication:** Use a `Set<UUID>` to avoid duplicates if both fetches return the same transactions

### Error Handling During Export

- **Network error on any request:** Throw `MigrationError.exportFailed(step, underlyingError)`
- **Authentication error:** User's Google session may have expired — show re-auth prompt
- **Retry logic:** The coordinator handles retry at the top level; individual requests use the existing `APIClient` error handling

---

## Phase 2: Import to SwiftData

### CloudKitDataImporter

```swift
struct ImportResult: Sendable {
  let accountCount: Int
  let categoryCount: Int
  let earmarkCount: Int
  let budgetItemCount: Int
  let transactionCount: Int
}

actor CloudKitDataImporter {
  private let modelContainer: ModelContainer

  enum ImportProgress: Sendable {
    case importing(step: String, current: Int, total: Int)
    case importComplete(ImportResult)
    case failed(Error)
  }

  func importData(
    _ data: ExportedData,
    progress: @escaping @Sendable (ImportProgress) -> Void
  ) async throws -> ImportResult {
    let context = ModelContext(modelContainer)

    // Order matters for referential integrity (though we use UUIDs, not relationships)

    // 1. Categories (no dependencies)
    progress(.importing(step: "categories", current: 0, total: data.categories.count))
    for (i, category) in data.categories.enumerated() {
      let record = CategoryRecord(
        id: category.id,
        name: category.name,
        parentId: category.parentId
      )
      context.insert(record)
      if i % 50 == 0 {
        progress(.importing(step: "categories", current: i, total: data.categories.count))
      }
    }

    // 2. Accounts (no dependencies)
    progress(.importing(step: "accounts", current: 0, total: data.accounts.count))
    for account in data.accounts {
      let record = AccountRecord(
        id: account.id,
        name: account.name,
        type: account.type.rawValue,
        position: account.position,
        isHidden: account.isHidden
      )
      context.insert(record)
    }

    // 3. Earmarks (no dependencies)
    progress(.importing(step: "earmarks", current: 0, total: data.earmarks.count))
    for earmark in data.earmarks {
      let record = EarmarkRecord(
        id: earmark.id,
        name: earmark.name,
        position: earmark.position,
        isHidden: earmark.isHidden,
        savingsTarget: earmark.savingsGoal?.cents,
        savingsStartDate: earmark.savingsStartDate,
        savingsEndDate: earmark.savingsEndDate
      )
      context.insert(record)
    }

    // 4. Earmark budget items
    var budgetItemCount = 0
    for (earmarkId, items) in data.earmarkBudgets {
      for item in items {
        let record = EarmarkBudgetItemRecord(
          id: item.id,
          earmarkId: earmarkId,
          categoryId: item.categoryId,
          amount: item.amount.cents
        )
        context.insert(record)
        budgetItemCount += 1
      }
    }

    // 5. Transactions (largest dataset — batch insert with progress)
    let totalTxns = data.transactions.count
    progress(.importing(step: "transactions", current: 0, total: totalTxns))
    for (i, txn) in data.transactions.enumerated() {
      let record = TransactionRecord(
        id: txn.id,
        type: txn.type.rawValue,
        date: txn.date,
        accountId: txn.accountId,
        toAccountId: txn.toAccountId,
        amount: txn.amount.cents,
        payee: txn.payee,
        notes: txn.notes,
        categoryId: txn.categoryId,
        earmarkId: txn.earmarkId,
        recurPeriod: txn.recurPeriod?.rawValue,
        recurEvery: txn.recurEvery
      )
      context.insert(record)

      if i % 100 == 0 {
        progress(.importing(step: "transactions", current: i, total: totalTxns))
      }
    }

    // 6. Save all at once (atomic)
    progress(.importing(step: "saving", current: 0, total: 1))
    try context.save()

    let result = ImportResult(
      accountCount: data.accounts.count,
      categoryCount: data.categories.count,
      earmarkCount: data.earmarks.count,
      budgetItemCount: budgetItemCount,
      transactionCount: data.transactions.count
    )
    progress(.importComplete(result))
    return result
  }
}
```

### Import Order

```
1. Categories    (referenced by transactions, earmark budgets)
2. Accounts      (referenced by transactions)
3. Earmarks      (referenced by transactions, budget items)
4. Budget Items  (references earmarks + categories)
5. Transactions  (references accounts, categories, earmarks)
```

Since we use UUID foreign keys (not SwiftData relationships), the order is technically irrelevant — but importing in dependency order makes verification easier.

### Preserving UUIDs

**Critical:** All UUIDs from the server must be preserved exactly. The `id` fields on imported records must match the server's `id` values. This ensures:
- Transaction → Account references remain valid
- Transaction → Category references remain valid
- Transaction → Earmark references remain valid
- Category parent → child references remain valid
- Earmark → Budget item references remain valid

The domain models already use `UUID` for IDs, and the import code passes them through directly.

### Batch Saving

All records are inserted into a single `ModelContext` and saved once at the end. This is:
- **Atomic:** Either all data is saved or none is
- **Efficient:** Single write transaction to SQLite
- **Safe:** If any insertion fails, nothing is persisted

For very large datasets (10,000+ transactions), memory usage during the batch insert may be a concern. If needed, batch in groups of 1,000 with intermediate saves — but this sacrifices atomicity.

---

## Phase 3: Verification

### Post-Migration Checks

```swift
struct MigrationVerifier {
  func verify(
    exported: ExportedData,
    modelContainer: ModelContainer
  ) async throws -> VerificationResult {
    let context = ModelContext(modelContainer)

    // 1. Record counts
    let accountCount = try context.fetchCount(FetchDescriptor<AccountRecord>())
    let categoryCount = try context.fetchCount(FetchDescriptor<CategoryRecord>())
    let earmarkCount = try context.fetchCount(FetchDescriptor<EarmarkRecord>())
    let txnCount = try context.fetchCount(FetchDescriptor<TransactionRecord>())

    let countMatch = accountCount == exported.accounts.count
      && categoryCount == exported.categories.count
      && earmarkCount == exported.earmarks.count
      && txnCount == exported.transactions.count

    // 2. Account balance verification
    // Compute balances locally and compare with server-provided balances
    var balanceMismatches: [(accountName: String, serverBalance: Int, localBalance: Int)] = []
    let allTxns = try context.fetch(FetchDescriptor<TransactionRecord>())

    for account in exported.accounts {
      let localBalance = allTxns
        .filter { $0.recurPeriod == nil }  // exclude scheduled
        .reduce(0) { sum, txn in
          var delta = 0
          if txn.accountId == account.id { delta += txn.amount }
          if txn.toAccountId == account.id { delta -= txn.amount }
          return sum + delta
        }

      if localBalance != account.balance.cents {
        balanceMismatches.append((
          accountName: account.name,
          serverBalance: account.balance.cents,
          localBalance: localBalance
        ))
      }
    }

    return VerificationResult(
      countMatch: countMatch,
      expectedCounts: (
        accounts: exported.accounts.count,
        categories: exported.categories.count,
        earmarks: exported.earmarks.count,
        transactions: exported.transactions.count
      ),
      actualCounts: (
        accounts: accountCount,
        categories: categoryCount,
        earmarks: earmarkCount,
        transactions: txnCount
      ),
      balanceMismatches: balanceMismatches
    )
  }
}
```

### What to Verify

| Check | How | Acceptable Difference |
|-------|-----|----------------------|
| Account count | `fetchCount` vs exported count | Must match exactly |
| Category count | `fetchCount` vs exported count | Must match exactly |
| Earmark count | `fetchCount` vs exported count | Must match exactly |
| Transaction count | `fetchCount` vs exported count | Must match exactly |
| Account balances | Local computation vs server balance | Must match exactly |
| Earmark balances | Local computation vs server balance | Must match (within rounding) |

### Balance Mismatch Handling

If balances don't match:
- Log the mismatches for debugging
- Show a warning to the user (not a blocker)
- Likely causes: scheduled transaction inclusion/exclusion differences, or transfer amount sign conventions
- The local computation is authoritative going forward — the server balance is just a verification check

---

## Phase 4: Switchover

### MigrationCoordinator

```swift
@Observable
@MainActor
final class MigrationCoordinator {
  enum State: Sendable {
    case idle
    case exporting(step: String)
    case importing(step: String, progress: Double)
    case verifying
    case succeeded(ImportResult)
    case failed(MigrationError)
  }

  private(set) var state: State = .idle

  func migrate(
    from remoteBackend: RemoteBackend,
    to modelContainer: ModelContainer
  ) async {
    state = .exporting(step: "Starting...")

    do {
      // 1. Export
      let exporter = ServerDataExporter(
        accountRepo: remoteBackend.accounts,
        categoryRepo: remoteBackend.categories,
        earmarkRepo: remoteBackend.earmarks,
        transactionRepo: remoteBackend.transactions
      )
      let exported = try await exporter.export { [weak self] progress in
        Task { @MainActor in
          switch progress {
          case .downloading(let step):
            self?.state = .exporting(step: step)
          default: break
          }
        }
      }

      // 2. Import
      let importer = CloudKitDataImporter(modelContainer: modelContainer)
      let result = try await importer.importData(exported) { [weak self] progress in
        Task { @MainActor in
          switch progress {
          case .importing(let step, let current, let total):
            let pct = total > 0 ? Double(current) / Double(total) : 0
            self?.state = .importing(step: step, progress: pct)
          default: break
          }
        }
      }

      // 3. Verify
      state = .verifying
      let verifier = MigrationVerifier()
      let verification = try await verifier.verify(
        exported: exported,
        modelContainer: modelContainer
      )

      if !verification.countMatch {
        throw MigrationError.verificationFailed(verification)
      }

      // 4. Cleanup
      CookieKeychain().clear()  // Remove Google OAuth cookies

      state = .succeeded(result)

    } catch {
      state = .failed(error as? MigrationError ?? .unexpected(error))
    }
  }
}
```

### Backend Switching

After successful migration:
1. Store a flag in `UserDefaults`: `iCloudMigrationCompleted = true`
2. On next app launch, the composition root checks this flag
3. If `true`: create `CloudKitBackend` instead of `RemoteBackend`
4. If `false`: create `RemoteBackend` (or show migration prompt)

```swift
// In MoolahApp.swift (composition root)
@main
struct MoolahApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(backend)
    }
  }

  var backend: any BackendProvider {
    if UserDefaults.standard.bool(forKey: "iCloudMigrationCompleted") {
      return CloudKitBackend()
    } else {
      return RemoteBackend(baseURL: serverURL)
    }
  }
}
```

---

## Error Handling & Rollback

### Error Types

```swift
enum MigrationError: Error, Sendable {
  case exportFailed(step: String, underlying: Error)
  case importFailed(underlying: Error)
  case verificationFailed(VerificationResult)
  case iCloudUnavailable
  case unexpected(Error)
}
```

### Rollback Strategy

- **Export failure:** No data has been written locally. Simply show error and allow retry.
- **Import failure:** The `ModelContext` is discarded without calling `save()`. No data persists. Clean rollback.
- **Verification failure:** Data was saved but counts don't match. Two options:
  1. Delete all imported records and retry
  2. Show warning but allow user to proceed (balances may differ slightly)
- **Post-switchover issues:** Keep the `RemoteBackend` code available for a transition period. Add a "Switch back to server" option in settings.

### Retry

The migration can be retried from scratch at any time. Before retrying:
1. Delete all existing records from the SwiftData container (clean slate)
2. Re-run the full export → import → verify cycle

---

## Edge Cases

### User with No Data
- Export returns empty arrays for all entities
- Import inserts nothing
- Verification passes (0 == 0)
- Migration completes instantly

### User with Thousands of Transactions
- Export paginates through all transactions (200 per page)
- For 10,000 transactions: ~50 requests
- Progress indicator shows page count
- Import inserts all 10,000 in a single batch
- Memory usage: ~10,000 `TransactionRecord` objects in memory — acceptable (~1-2 MB)

### Scheduled Transactions
- Exported like any other transaction (they have `recurPeriod != nil`)
- Imported into the same `TransactionRecord` table
- No special handling needed

### Earmark Budgets
- Fetched per-earmark (one request each)
- For 10 earmarks: 10 additional requests
- Budget items imported as `EarmarkBudgetItemRecord`

### Categories with Parent-Child Relationships
- Parent and child categories are both in the exported flat list
- `parentId` references are preserved by UUID
- Import order doesn't matter (UUID foreign keys, not SwiftData relationships)

### Session Expiry During Migration
- If the Google OAuth session expires mid-export, `APIClient` throws `BackendError.unauthenticated`
- Show "Session expired. Please sign in again to continue migration."
- After re-auth, retry the migration from the beginning

---

## UI Design

### MigrationView

```swift
struct MigrationView: View {
  @State private var coordinator = MigrationCoordinator()

  var body: some View {
    VStack(spacing: 24) {
      switch coordinator.state {
      case .idle:
        migrationPrompt
      case .exporting(let step):
        ProgressView("Downloading \(step)...")
      case .importing(let step, let progress):
        ProgressView("Importing \(step)...", value: progress)
      case .verifying:
        ProgressView("Verifying data integrity...")
      case .succeeded(let result):
        migrationSuccess(result)
      case .failed(let error):
        migrationFailure(error)
      }
    }
    .padding()
  }

  private var migrationPrompt: some View {
    VStack(spacing: 16) {
      Image(systemName: "icloud.and.arrow.up")
        .font(.system(size: 48))
        .foregroundStyle(.tint)
      Text("Migrate to iCloud")
        .font(.title)
      Text("Your data will be moved from the Moolah server to iCloud. This enables offline access and removes the dependency on the server.")
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
      Button("Start Migration") {
        Task { await coordinator.migrate(...) }
      }
      .buttonStyle(.borderedProminent)
    }
  }
}
```

### Settings Integration
- Add "Data Migration" section in settings
- Show migration status (completed / not started)
- Allow re-triggering migration if needed
- Show "Switch back to server" option during transition period

---

## Testing Strategy

### Unit Tests

```swift
@Suite("ServerDataExporter")
struct ServerDataExporterTests {
  @Test("exports all data from InMemory backend")
  func exportAll() async throws {
    let backend = InMemoryBackend(/* seeded with test data */)
    let exporter = ServerDataExporter(
      accountRepo: backend.accounts,
      categoryRepo: backend.categories,
      earmarkRepo: backend.earmarks,
      transactionRepo: backend.transactions
    )
    let data = try await exporter.export { _ in }
    #expect(data.accounts.count == expectedAccountCount)
    #expect(data.transactions.count == expectedTransactionCount)
  }
}

@Suite("CloudKitDataImporter")
struct CloudKitDataImporterTests {
  @Test("imports exported data preserving all UUIDs")
  func importPreservesIds() async throws {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: allModelTypes, configurations: config)
    let importer = CloudKitDataImporter(modelContainer: container)

    let exported = ExportedData(/* test data */)
    let result = try await importer.importData(exported) { _ in }

    #expect(result.transactionCount == exported.transactions.count)
    // Verify UUIDs match
  }
}

@Suite("MigrationVerifier")
struct MigrationVerifierTests {
  @Test("verification passes when counts match")
  func countsMatch() async throws { ... }

  @Test("verification fails when transaction count mismatches")
  func countMismatch() async throws { ... }

  @Test("balance verification catches mismatches")
  func balanceMismatch() async throws { ... }
}
```

### Integration Test

```swift
@Test("full migration round-trip: InMemory → SwiftData → verify")
func fullMigration() async throws {
  // 1. Seed InMemoryBackend with realistic data
  let backend = InMemoryBackend(/* accounts, categories, earmarks, transactions */)

  // 2. Export
  let exporter = ServerDataExporter(backend: backend)
  let exported = try await exporter.export { _ in }

  // 3. Import to in-memory SwiftData
  let config = ModelConfiguration(isStoredInMemoryOnly: true)
  let container = try ModelContainer(for: allModelTypes, configurations: config)
  let importer = CloudKitDataImporter(modelContainer: container)
  let result = try await importer.importData(exported) { _ in }

  // 4. Verify
  let verifier = MigrationVerifier()
  let verification = try await verifier.verify(exported: exported, modelContainer: container)
  #expect(verification.countMatch == true)
  #expect(verification.balanceMismatches.isEmpty)

  // 5. Read back through CloudKit repositories and compare
  let cloudAccounts = CloudKitAccountRepository(modelContainer: container)
  let accounts = try await cloudAccounts.fetchAll()
  #expect(accounts.count == exported.accounts.count)
}
```

---

## Files to Create

| File | Purpose |
|------|---------|
| `Backends/CloudKit/Migration/ServerDataExporter.swift` | Export from REST API |
| `Backends/CloudKit/Migration/CloudKitDataImporter.swift` | Import to SwiftData |
| `Backends/CloudKit/Migration/MigrationCoordinator.swift` | Orchestration |
| `Backends/CloudKit/Migration/MigrationVerifier.swift` | Post-import verification |
| `Backends/CloudKit/Migration/MigrationError.swift` | Error types |
| `Features/Migration/MigrationView.swift` | Migration UI |
| `Features/Migration/MigrationStore.swift` | UI state (or use coordinator directly) |
| `MoolahTests/Migration/ServerDataExporterTests.swift` | Export tests |
| `MoolahTests/Migration/CloudKitDataImporterTests.swift` | Import tests |
| `MoolahTests/Migration/MigrationVerifierTests.swift` | Verification tests |
| `MoolahTests/Migration/MigrationIntegrationTests.swift` | End-to-end test |

---

## Estimated Effort

| Task | Estimate |
|------|----------|
| `ServerDataExporter` (with pagination) | 3 hours |
| `CloudKitDataImporter` (batch insert) | 3 hours |
| `MigrationVerifier` (counts + balances) | 2 hours |
| `MigrationCoordinator` (orchestration) | 2 hours |
| `MigrationView` UI | 2 hours |
| Backend switching in composition root | 1 hour |
| Unit tests | 3 hours |
| Integration tests | 2 hours |
| **Total** | **~18 hours** |

---

## Risks

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Data loss during migration | Critical | Low | Atomic save, verification, retry capability |
| Session expires mid-export | Medium | Medium | Detect and prompt re-auth |
| Very large datasets (50K+ txns) | Medium | Low | Pagination, progress reporting, memory management |
| Balance mismatch after migration | Medium | Low | Detailed verification logging; local computation is authoritative |
| User declines migration | Low | Medium | Keep RemoteBackend working; prompt again later |
| CloudKit unavailable during import | Medium | Low | Check iCloud availability before starting |
