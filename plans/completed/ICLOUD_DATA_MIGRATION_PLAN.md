# iCloud Migration — Data Migration from moolah-server

**Date:** 2026-04-08
**Component:** Data Migration
**Parent plan:** [ICLOUD_MIGRATION_PLAN.md](./ICLOUD_MIGRATION_PLAN.md)

## Overview

This plan describes the **optional** migration of existing user data from a moolah-server or custom-server profile to a new iCloud profile using SwiftData/CloudKit storage. Migration is user-initiated — it is never automatic or forced. The original profile is preserved so the user can compare data and verify accuracy before deciding to stop using it.

This is the **highest-risk** part of the iCloud migration — data loss or corruption during migration would be unacceptable for a financial application. The non-destructive approach (keeping the original profile) significantly reduces this risk.

---

## Design Principles

1. **Optional:** Migration is never automatic. The user explicitly triggers it.
2. **Non-destructive:** The original profile is never modified or deleted (only its label changes).
3. **Verifiable:** Both profiles coexist, so the user can compare data side-by-side.
4. **Repeatable:** If the first attempt fails or produces incorrect results, the user can delete the new iCloud profile and try again.

---

## User Experience Flow

### Trigger

Migration is triggered from **Profile Settings** for a moolah-server or custom-server profile. A button labeled **"Migrate to iCloud"** appears in the profile's settings section. This button is only visible for remote-backend profiles (`.moolah` or `.custom`).

### Happy Path
1. User navigates to profile settings for their server-based profile
2. User taps **"Migrate to iCloud"**
3. Confirmation sheet explains: "This will create a new iCloud profile with a copy of all your data. Your current profile will be kept with '(Migrated)' added to its name."
4. User taps **"Start Migration"**
5. Progress indicator shows: "Downloading accounts... categories... earmarks... transactions (page 1 of N)..."
6. Progress indicator shows: "Saving to iCloud..."
7. **"Migration Complete"** screen with summary (X accounts, Y transactions, etc.)
8. User taps **"Continue"**
9. The app switches to the newly created iCloud profile
10. The original profile's label is updated to append " (Migrated)" (e.g., "My Finances" → "My Finances (Migrated)")
11. The new iCloud profile inherits the original label (e.g., "My Finances")

### Error Path
1. Migration fails at any step → error screen with details
2. User can tap **"Retry"** to restart from the beginning
3. All partial imports are rolled back (SwiftData context discarded without saving)
4. The original profile is untouched — no label change occurs on failure
5. Any partially created iCloud profile is cleaned up

### No Data Path
- User has no data on the server (fresh account)
- Migration completes instantly with "0 items migrated"
- New iCloud profile is created (empty) and original profile is renamed

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
  let investmentValues: [UUID: [InvestmentValue]]   // keyed by accountId
}

actor ServerDataExporter {
  private let accountRepo: AccountRepository
  private let categoryRepo: CategoryRepository
  private let earmarkRepo: EarmarkRepository
  private let transactionRepo: TransactionRepository
  private let investmentRepo: InvestmentRepository

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

    // 5. Investment values (paginated per investment account)
    progress(.downloading(step: "investment values"))
    let investmentAccounts = accounts.filter { $0.type == .investment }
    var investmentValues: [UUID: [InvestmentValue]] = [:]
    for account in investmentAccounts {
      investmentValues[account.id] = try await fetchAllInvestmentValues(accountId: account.id)
    }

    let data = ExportedData(
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      earmarkBudgets: budgets,
      transactions: transactions,
      investmentValues: investmentValues
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

  private func fetchAllInvestmentValues(accountId: UUID) async throws -> [InvestmentValue] {
    var allValues: [InvestmentValue] = []
    var page = 0
    let pageSize = 200

    while true {
      let result = try await investmentRepo.fetchValues(
        accountId: accountId,
        page: page,
        pageSize: pageSize
      )
      allValues.append(contentsOf: result.values)

      if result.values.count < pageSize {
        break
      }
      page += 1
    }

    return allValues
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

The importer receives a `profileId` and `currencyCode` to stamp on every record. This scopes all imported data to the target profile and stores currency for future multi-currency support.

```swift
struct ImportResult: Sendable {
  let accountCount: Int
  let categoryCount: Int
  let earmarkCount: Int
  let budgetItemCount: Int
  let transactionCount: Int
  let investmentValueCount: Int
}

actor CloudKitDataImporter {
  private let modelContainer: ModelContainer
  private let profileId: UUID
  private let currencyCode: String

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
        profileId: profileId,
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
        profileId: profileId,
        name: account.name,
        type: account.type.rawValue,
        position: account.position,
        isHidden: account.isHidden,
        currencyCode: currencyCode
      )
      context.insert(record)
    }

    // 3. Earmarks (no dependencies)
    progress(.importing(step: "earmarks", current: 0, total: data.earmarks.count))
    for earmark in data.earmarks {
      let record = EarmarkRecord(
        id: earmark.id,
        profileId: profileId,
        name: earmark.name,
        position: earmark.position,
        isHidden: earmark.isHidden,
        savingsTarget: earmark.savingsGoal?.cents,
        currencyCode: currencyCode,
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
          amount: item.amount.cents,
          currencyCode: currencyCode
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
        profileId: profileId,
        type: txn.type.rawValue,
        date: txn.date,
        accountId: txn.accountId,
        toAccountId: txn.toAccountId,
        amount: txn.amount.cents,
        currencyCode: currencyCode,
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

    // 6. Investment values (per investment account)
    let allInvestmentValues = data.investmentValues.values.flatMap { $0 }
    let totalValues = allInvestmentValues.count
    progress(.importing(step: "investment values", current: 0, total: totalValues))
    var investmentValueCount = 0
    for (accountId, values) in data.investmentValues {
      for value in values {
        let record = InvestmentValueRecord(
          id: value.id,
          profileId: profileId,
          accountId: accountId,
          date: value.date,
          value: value.value.cents,
          currencyCode: currencyCode
        )
        context.insert(record)
        investmentValueCount += 1
        if investmentValueCount % 100 == 0 {
          progress(.importing(step: "investment values", current: investmentValueCount, total: totalValues))
        }
      }
    }

    // 7. Save all at once (atomic)
    progress(.importing(step: "saving", current: 0, total: 1))
    try context.save()

    let result = ImportResult(
      accountCount: data.accounts.count,
      categoryCount: data.categories.count,
      earmarkCount: data.earmarks.count,
      budgetItemCount: budgetItemCount,
      transactionCount: data.transactions.count,
      investmentValueCount: investmentValueCount
    )
    progress(.importComplete(result))
    return result
  }
}
```

### Import Order

```
1. Categories          (referenced by transactions, earmark budgets)
2. Accounts            (referenced by transactions, investment values)
3. Earmarks            (referenced by transactions, budget items)
4. Budget Items        (references earmarks + categories)
5. Transactions        (references accounts, categories, earmarks)
6. Investment Values   (references accounts)
```

Since we use UUID foreign keys (not SwiftData relationships), the order is technically irrelevant — but importing in dependency order makes verification easier.

### Preserving UUIDs

**Critical:** All UUIDs from the server must be preserved exactly. The `id` fields on imported records must match the server's `id` values. This ensures:
- Transaction → Account references remain valid
- Transaction → Category references remain valid
- Transaction → Earmark references remain valid
- Category parent → child references remain valid
- Earmark → Budget item references remain valid
- Investment value → Account references remain valid

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

    // 1. Record counts (scoped to the new profile's profileId)
    let accountCount = try context.fetchCount(FetchDescriptor<AccountRecord>())
    let categoryCount = try context.fetchCount(FetchDescriptor<CategoryRecord>())
    let earmarkCount = try context.fetchCount(FetchDescriptor<EarmarkRecord>())
    let txnCount = try context.fetchCount(FetchDescriptor<TransactionRecord>())
    let investmentValueCount = try context.fetchCount(FetchDescriptor<InvestmentValueRecord>())

    let expectedInvestmentValueCount = exported.investmentValues.values.reduce(0) { $0 + $1.count }

    let countMatch = accountCount == exported.accounts.count
      && categoryCount == exported.categories.count
      && earmarkCount == exported.earmarks.count
      && txnCount == exported.transactions.count
      && investmentValueCount == expectedInvestmentValueCount

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
        transactions: exported.transactions.count,
        investmentValues: expectedInvestmentValueCount
      ),
      actualCounts: (
        accounts: accountCount,
        categories: categoryCount,
        earmarks: earmarkCount,
        transactions: txnCount,
        investmentValues: investmentValueCount
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
| Investment value count | `fetchCount` vs exported count | Must match exactly |
| Account balances | Local computation vs server balance | Must match exactly |
| Earmark balances | Local computation vs server balance | Must match exactly |

### Balance Mismatch Handling

Balance mismatches are treated as a **migration failure** — they are never silently accepted:

- The migration stops and the user is shown a clear error detailing which accounts/earmarks have mismatched balances and by how much
- The user is given two options:
  1. **"Keep for Review"** — the new iCloud profile is retained so the user can switch to it and inspect the data. The source profile is **not** renamed. Both profiles have distinct labels (the new one gets a " (Incomplete)" suffix).
  2. **"Delete and Retry"** — the new iCloud profile and all its data are deleted. The user can retry the migration from the source profile's settings.
- Likely causes: scheduled transaction inclusion/exclusion differences, transfer amount sign conventions, or missing transactions

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
    case verificationFailed(VerificationResult, newProfileId: UUID)
    case failed(MigrationError)
  }

  private(set) var state: State = .idle

  /// Migrates data from a remote profile to a new iCloud profile.
  ///
  /// - Parameters:
  ///   - sourceProfile: The remote profile to migrate from
  ///   - remoteBackend: The backend for the source profile
  ///   - modelContainer: The shared SwiftData model container
  ///   - profileStore: The profile store for creating the new profile and renaming the old one
  func migrate(
    sourceProfile: Profile,
    from remoteBackend: RemoteBackend,
    to modelContainer: ModelContainer,
    profileStore: ProfileStore
  ) async {
    state = .exporting(step: "Starting...")

    do {
      // 1. Export all data from the remote backend
      let exporter = ServerDataExporter(
        accountRepo: remoteBackend.accounts,
        categoryRepo: remoteBackend.categories,
        earmarkRepo: remoteBackend.earmarks,
        transactionRepo: remoteBackend.transactions,
        investmentRepo: remoteBackend.investments
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

      // 2. Create a new iCloud profile with the original label
      let newProfileId = UUID()
      let newProfile = try await profileStore.createProfile(
        id: newProfileId,
        label: sourceProfile.label,
        backendType: .cloudKit,
        currency: sourceProfile.currency,
        financialYearStartMonth: sourceProfile.financialYearStartMonth
      )

      // 3. Import data into the new profile
      let importer = CloudKitDataImporter(
        modelContainer: modelContainer,
        profileId: newProfileId,
        currencyCode: sourceProfile.currency.code
      )
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

      // 4. Verify imported data
      state = .verifying
      let verifier = MigrationVerifier()
      let verification = try await verifier.verify(
        exported: exported,
        modelContainer: modelContainer,
        profileId: newProfileId
      )

      if !verification.countMatch {
        // Don't delete the new profile — let the user review it
        // The UI will offer "Keep for Review" vs "Delete" options
        state = .verificationFailed(verification, newProfileId: newProfileId)
        return
      }

      // 5. Rename the source profile to indicate it has been migrated
      try await profileStore.updateProfile(
        id: sourceProfile.id,
        label: "\(sourceProfile.label) (Migrated)"
      )

      // 6. Switch to the new iCloud profile
      try await profileStore.switchToProfile(id: newProfileId)

      state = .succeeded(result)

    } catch {
      state = .failed(error as? MigrationError ?? .unexpected(error))
    }
  }
}
```

### Profile Creation (Not Backend Switching)

Unlike the original design, migration does **not** modify the source profile's backend type. Instead it creates a brand-new iCloud profile:

1. `MigrationCoordinator` calls `profileStore.createProfile()` with `backendType: .cloudKit`
2. All exported data is imported scoped to the new profile's `profileId`
3. On success, the source profile's label gets " (Migrated)" appended
4. The app switches to the new iCloud profile as the active profile
5. The source profile remains fully functional — the user can switch back at any time

This means both profiles coexist:
- **"My Finances"** — the new iCloud profile with migrated data
- **"My Finances (Migrated)"** — the original server profile, untouched

The user can compare data between the two profiles and delete the old one when satisfied.

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

Since migration creates a new profile without modifying the original, rollback is straightforward:

- **Export failure:** No data has been written locally. No new profile created. Simply show error and allow retry.
- **Import failure:** The `ModelContext` is discarded without calling `save()`. Delete the partially created profile. Clean rollback.
- **Verification failure:** Data was saved but counts/balances don't match. User chooses to either keep the new profile for review or delete it and retry.
- **Post-migration issues:** The source profile is still there with all its data. User can switch back at any time. No "switch back" mechanism needed — it's just profile switching.

### Retry

The migration can be retried at any time:
1. Delete the failed/incorrect iCloud profile (if one was created)
2. Re-run migration from the source profile's settings — creates a fresh iCloud profile
3. No need to manually clean up data — deleting the profile cleans up all scoped records

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

### Investment Values
- Fetched per-investment-account (paginated, 200 per page)
- Only accounts with `type == .investment` are queried
- Imported as `InvestmentValueRecord` with the new profile's `profileId`

### Session Expiry During Migration
- If the Google OAuth session expires mid-export, `APIClient` throws `BackendError.unauthenticated`
- Show "Session expired. Please sign in again to continue migration."
- After re-auth, retry the migration from the beginning

---

## UI Design

### MigrationView

Presented as a sheet from the profile settings screen when the user taps "Migrate to iCloud".

```swift
struct MigrationView: View {
  let sourceProfile: Profile
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
      case .verificationFailed(let verification, let newProfileId):
        verificationFailure(verification, newProfileId: newProfileId)
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
      Text("This will create a new iCloud profile with a copy of all your data from \"\(sourceProfile.label)\". Your current profile will be kept with \"(Migrated)\" added to its name so you can compare and verify the data.")
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
      Button("Start Migration") {
        Task { await coordinator.migrate(sourceProfile: sourceProfile, ...) }
      }
      .buttonStyle(.borderedProminent)
    }
  }
}
```

### Profile Settings Integration

The "Migrate to iCloud" button appears in the profile settings view for remote-backend profiles (`.moolah` or `.custom`):

- **Button visibility:** Only shown for profiles with `backendType` of `.moolah` or `.custom`
- **Button action:** Presents the `MigrationView` as a sheet
- **No status tracking needed:** The existence of a corresponding iCloud profile (with the original label) indicates migration was completed. The "(Migrated)" suffix on the source profile is also a visual indicator.

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
      transactionRepo: backend.transactions,
      investmentRepo: backend.investments
    )
    let data = try await exporter.export { _ in }
    #expect(data.accounts.count == expectedAccountCount)
    #expect(data.transactions.count == expectedTransactionCount)
    #expect(data.investmentValues.count == expectedInvestmentAccountCount)
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
| Profile settings integration | 1 hour |
| Unit tests | 3 hours |
| Integration tests | 2 hours |
| **Total** | **~18 hours** |

---

## Risks

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Data loss during migration | Critical | Low | Non-destructive: source profile preserved, atomic save, verification, retry |
| Session expires mid-export | Medium | Medium | Detect and prompt re-auth |
| Very large datasets (50K+ txns) | Medium | Low | Pagination, progress reporting, memory management |
| Balance mismatch after migration | Critical | Low | Migration fails, new profile deleted, detailed error shown to user |
| CloudKit unavailable during import | Medium | Low | Check iCloud availability before starting |
| Profile label collision | Low | Low | Check for existing profile with same label before creating |
