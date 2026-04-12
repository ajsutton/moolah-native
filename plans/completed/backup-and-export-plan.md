# Backup and Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add automatic daily store-file backups (macOS only) and user-facing JSON import/export (both platforms), sharing infrastructure with the existing migration feature.

**Architecture:** Two features built in layers. First, refactor the existing migration exporter/importer into shared types (`DataExporter`, `ExportedData` with JSON support). Then build the automatic backup as a standalone `StoreBackupManager` using `replacePersistentStore`. Finally, wire up import/export UI in File menu (macOS) and profile list (both platforms).

**Tech Stack:** SwiftData, Core Data (`NSPersistentStoreCoordinator`), Swift Testing, SwiftUI Commands

**Design spec:** `plans/backup-and-export-design.md`

---

### Task 1: Move ExportedData to Shared and Add JSON Support

Extract `ExportedData` from the migration directory into `Shared/` and add `Codable` conformance with profile metadata fields.

**Files:**
- Create: `Shared/ExportedData.swift`
- Modify: `Backends/CloudKit/Migration/ServerDataExporter.swift` (remove `ExportedData` definition)
- Test: `MoolahTests/Export/ExportedDataTests.swift`

- [ ] **Step 1: Write test for ExportedData JSON round-trip**

Create `MoolahTests/Export/ExportedDataTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("ExportedData JSON")
struct ExportedDataTests {

  private let currency = Currency.defaultTestCurrency

  @Test("round-trips through JSON encoder/decoder")
  func jsonRoundTrip() throws {
    let original = ExportedData(
      version: 1,
      exportedAt: Date(),
      profileLabel: "Test",
      currencyCode: currency.code,
      financialYearStartMonth: 7,
      accounts: [
        Account(
          name: "Checking", type: .bank,
          balance: MonetaryAmount(cents: 10000, currency: currency)
        ),
      ],
      categories: [
        Category(name: "Food"),
      ],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [
        Transaction(
          type: .income, date: Date(),
          accountId: UUID(),
          amount: MonetaryAmount(cents: 5000, currency: currency),
          payee: "Employer"
        ),
      ],
      investmentValues: [:]
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ExportedData.self, from: data)

    #expect(decoded.version == 1)
    #expect(decoded.profileLabel == "Test")
    #expect(decoded.currencyCode == currency.code)
    #expect(decoded.financialYearStartMonth == 7)
    #expect(decoded.accounts.count == 1)
    #expect(decoded.accounts[0].name == "Checking")
    #expect(decoded.categories.count == 1)
    #expect(decoded.transactions.count == 1)
    #expect(decoded.transactions[0].payee == "Employer")
  }

  @Test("version field is present in JSON output")
  func versionInJSON() throws {
    let data = ExportedData(
      version: 1,
      exportedAt: Date(),
      profileLabel: "P",
      currencyCode: "AUD",
      financialYearStartMonth: 1,
      accounts: [],
      categories: [],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [],
      investmentValues: [:]
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let json = try encoder.encode(data)
    let dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]
    #expect(dict["version"] as? Int == 1)
    #expect(dict["profileLabel"] as? String == "P")
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test`
Expected: Compilation error — `ExportedData` does not have `version`, `profileLabel`, etc. fields and is not `Codable`.

- [ ] **Step 3: Create Shared/ExportedData.swift**

Create `Shared/ExportedData.swift`:

```swift
import Foundation

/// All data exported from a profile, in a backend-agnostic format.
/// Used by migration, user export, and user import.
struct ExportedData: Codable, Sendable {
  let version: Int
  let exportedAt: Date
  let profileLabel: String
  let currencyCode: String
  let financialYearStartMonth: Int
  let accounts: [Account]
  let categories: [Category]
  let earmarks: [Earmark]
  let earmarkBudgets: [UUID: [EarmarkBudgetItem]]
  let transactions: [Transaction]
  let investmentValues: [UUID: [InvestmentValue]]
}
```

- [ ] **Step 4: Remove ExportedData from ServerDataExporter.swift**

In `Backends/CloudKit/Migration/ServerDataExporter.swift`, remove lines 4–11 (the `ExportedData` struct definition). The `ServerDataExporter` actor itself stays — we'll rename it in Task 2.

- [ ] **Step 5: Update ServerDataExporter to populate new fields**

In `ServerDataExporter.export()`, update the `ExportedData` construction (around line 96) to include the new fields. The exporter needs to accept these values — add `profileLabel`, `currencyCode`, and `financialYearStartMonth` parameters to `export()`:

```swift
func export(
  profileLabel: String,
  currencyCode: String,
  financialYearStartMonth: Int,
  progress: @escaping @Sendable (ExportProgress) -> Void
) async throws -> ExportedData {
```

And update the construction:

```swift
let data = ExportedData(
  version: 1,
  exportedAt: Date(),
  profileLabel: profileLabel,
  currencyCode: currencyCode,
  financialYearStartMonth: financialYearStartMonth,
  accounts: accounts,
  categories: categories,
  earmarks: earmarks,
  earmarkBudgets: budgets,
  transactions: transactions,
  investmentValues: investmentValues
)
```

- [ ] **Step 6: Update MigrationCoordinator to pass new fields**

In `Backends/CloudKit/Migration/MigrationCoordinator.swift`, update the `exporter.export()` call (around line 47) to pass the profile metadata:

```swift
let exported = try await exporter.export(
  profileLabel: sourceProfile.label,
  currencyCode: sourceProfile.currencyCode,
  financialYearStartMonth: sourceProfile.financialYearStartMonth
) { [weak self] progress in
```

- [ ] **Step 7: Update MigrationIntegrationTests**

In `MoolahTests/Migration/MigrationIntegrationTests.swift`, update all `exporter.export` calls to pass the new parameters:

```swift
let exported = try await exporter.export(
  profileLabel: "Test",
  currencyCode: currency.code,
  financialYearStartMonth: 7
) { _ in }
```

There are three test methods that call `exporter.export` — update all three.

- [ ] **Step 8: Run tests to verify everything passes**

Run: `just test`
Expected: All tests pass, including the new `ExportedDataTests`.

- [ ] **Step 9: Commit**

```bash
git add Shared/ExportedData.swift MoolahTests/Export/ExportedDataTests.swift \
  Backends/CloudKit/Migration/ServerDataExporter.swift \
  Backends/CloudKit/Migration/MigrationCoordinator.swift \
  MoolahTests/Migration/MigrationIntegrationTests.swift
git commit -m "refactor: move ExportedData to Shared with Codable and profile metadata"
```

---

### Task 2: Rename ServerDataExporter to DataExporter

Rename and move the exporter to `Shared/` since it's backend-agnostic. Simplify the constructor to accept a `BackendProvider` directly.

**Files:**
- Create: `Shared/DataExporter.swift`
- Delete: `Backends/CloudKit/Migration/ServerDataExporter.swift`
- Modify: `Backends/CloudKit/Migration/MigrationCoordinator.swift`
- Modify: `MoolahTests/Migration/MigrationIntegrationTests.swift`

- [ ] **Step 1: Create Shared/DataExporter.swift**

Copy `Backends/CloudKit/Migration/ServerDataExporter.swift` to `Shared/DataExporter.swift`. Rename the actor from `ServerDataExporter` to `DataExporter`. Change the constructor to accept a `BackendProvider`:

```swift
import Foundation

/// Exports all data from any BackendProvider into an ExportedData snapshot.
actor DataExporter {
  private let backend: any BackendProvider

  enum ExportProgress: Sendable {
    case downloading(step: String)
    case downloadComplete(ExportedData)
    case failed(Error)
  }

  init(backend: any BackendProvider) {
    self.backend = backend
  }

  func export(
    profileLabel: String,
    currencyCode: String,
    financialYearStartMonth: Int,
    progress: @escaping @Sendable (ExportProgress) -> Void
  ) async throws -> ExportedData {
    // 1. Accounts
    progress(.downloading(step: "accounts"))
    let accounts: [Account]
    do {
      accounts = try await backend.accounts.fetchAll()
    } catch {
      throw MigrationError.exportFailed(step: "accounts", underlying: error)
    }

    // 2. Categories
    progress(.downloading(step: "categories"))
    let categories: [Category]
    do {
      categories = try await backend.categories.fetchAll()
    } catch {
      throw MigrationError.exportFailed(step: "categories", underlying: error)
    }

    // 3. Earmarks + budgets
    progress(.downloading(step: "earmarks"))
    let earmarks: [Earmark]
    var budgets: [UUID: [EarmarkBudgetItem]] = [:]
    do {
      earmarks = try await backend.earmarks.fetchAll()
      for earmark in earmarks {
        budgets[earmark.id] = try await backend.earmarks.fetchBudget(earmarkId: earmark.id)
      }
    } catch {
      throw MigrationError.exportFailed(step: "earmarks", underlying: error)
    }

    // 4. Transactions (paginated)
    progress(.downloading(step: "transactions"))
    let transactions: [Transaction]
    do {
      transactions = try await fetchAllTransactions()
    } catch {
      throw MigrationError.exportFailed(step: "transactions", underlying: error)
    }

    // 5. Investment values (per investment account)
    progress(.downloading(step: "investment values"))
    let investmentAccounts = accounts.filter { $0.type == .investment }
    var investmentValues: [UUID: [InvestmentValue]] = [:]
    do {
      for account in investmentAccounts {
        investmentValues[account.id] = try await fetchAllInvestmentValues(accountId: account.id)
      }
    } catch {
      throw MigrationError.exportFailed(step: "investment values", underlying: error)
    }

    let data = ExportedData(
      version: 1,
      exportedAt: Date(),
      profileLabel: profileLabel,
      currencyCode: currencyCode,
      financialYearStartMonth: financialYearStartMonth,
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
    let pageSize = 200

    while true {
      let result = try await backend.transactions.fetch(
        filter: TransactionFilter(),
        page: page,
        pageSize: pageSize
      )
      allTransactions.append(contentsOf: result.transactions)

      if result.transactions.count < pageSize {
        break
      }
      page += 1
    }

    var scheduledPage = 0
    while true {
      let result = try await backend.transactions.fetch(
        filter: TransactionFilter(scheduled: true),
        page: scheduledPage,
        pageSize: pageSize
      )

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
      let result = try await backend.investments.fetchValues(
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

- [ ] **Step 2: Delete ServerDataExporter.swift**

```bash
rm Backends/CloudKit/Migration/ServerDataExporter.swift
```

- [ ] **Step 3: Update MigrationCoordinator to use DataExporter**

In `Backends/CloudKit/Migration/MigrationCoordinator.swift`, replace the `ServerDataExporter` construction (around line 40):

```swift
// Before:
let exporter = ServerDataExporter(
  accountRepo: backend.accounts,
  categoryRepo: backend.categories,
  earmarkRepo: backend.earmarks,
  transactionRepo: backend.transactions,
  investmentRepo: backend.investments
)
let exported = try await exporter.export(
  profileLabel: sourceProfile.label,
  currencyCode: sourceProfile.currencyCode,
  financialYearStartMonth: sourceProfile.financialYearStartMonth
) { [weak self] progress in

// After:
let exporter = DataExporter(backend: backend)
let exported = try await exporter.export(
  profileLabel: sourceProfile.label,
  currencyCode: sourceProfile.currencyCode,
  financialYearStartMonth: sourceProfile.financialYearStartMonth
) { [weak self] progress in
```

- [ ] **Step 4: Update MigrationIntegrationTests**

Replace all `ServerDataExporter(accountRepo:...)` calls with `DataExporter(backend:)`:

```swift
// Before:
let exporter = ServerDataExporter(
  accountRepo: backend.accounts,
  categoryRepo: backend.categories,
  earmarkRepo: backend.earmarks,
  transactionRepo: backend.transactions,
  investmentRepo: backend.investments
)

// After:
let exporter = DataExporter(backend: backend)
```

Update all three test methods (`fullMigration`, `preservesCategoryHierarchy`, `preservesEarmarkBudgets`).

- [ ] **Step 5: Run tests**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add Shared/DataExporter.swift \
  Backends/CloudKit/Migration/MigrationCoordinator.swift \
  MoolahTests/Migration/MigrationIntegrationTests.swift
git rm Backends/CloudKit/Migration/ServerDataExporter.swift
git commit -m "refactor: rename ServerDataExporter to DataExporter and move to Shared"
```

---

### Task 3: Add Export and Import Methods to MigrationCoordinator

Add `exportToFile` and `importFromFile` methods to `MigrationCoordinator`.

**Files:**
- Modify: `Backends/CloudKit/Migration/MigrationCoordinator.swift`
- Test: `MoolahTests/Export/ExportImportIntegrationTests.swift`

- [ ] **Step 1: Write export-to-file test**

Create `MoolahTests/Export/ExportImportIntegrationTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("Export/Import Integration")
@MainActor
struct ExportImportIntegrationTests {

  private let currency = Currency.defaultTestCurrency

  private func makeSeededBackend() async throws -> (CloudKitBackend, ModelContainer) {
    let (backend, container) = try TestBackend.create(currency: currency)

    _ = try await backend.accounts.create(
      Account(
        name: "Checking", type: .bank,
        balance: MonetaryAmount(cents: 50000, currency: currency)
      )
    )
    let food = try await backend.categories.create(Category(name: "Food"))
    _ = try await backend.categories.create(Category(name: "Groceries", parentId: food.id))

    let holiday = try await backend.earmarks.create(
      Earmark(name: "Holiday", balance: .zero(currency: currency))
    )
    try await backend.earmarks.setBudget(earmarkId: holiday.id, categoryId: food.id, amount: 3000)

    let accounts = try await backend.accounts.fetchAll()
    _ = try await backend.transactions.create(
      Transaction(
        type: .income, date: Date(),
        accountId: accounts[0].id,
        amount: MonetaryAmount(cents: 50000, currency: currency),
        payee: "Employer"
      )
    )

    return (backend, container)
  }

  @Test("export to JSON file and import into new profile")
  func exportImportRoundTrip() async throws {
    let (backend, _) = try await makeSeededBackend()
    let coordinator = MigrationCoordinator()

    let profile = Profile(
      label: "Test",
      backendType: .cloudKit,
      currencyCode: currency.code,
      financialYearStartMonth: 7
    )

    // Export
    let tempURL = FileManager.default.temporaryDirectory
      .appending(path: "\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    try await coordinator.exportToFile(
      url: tempURL,
      backend: backend,
      profile: profile
    )

    // Verify file exists and is valid JSON
    let jsonData = try Data(contentsOf: tempURL)
    let decoded = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: jsonData)
    #expect(decoded.version == 1)
    #expect(decoded.accounts.count == 1)
    #expect(decoded.categories.count == 2)
    #expect(decoded.earmarks.count == 1)
    #expect(decoded.transactions.count == 1)
    #expect(decoded.profileLabel == "Test")
    #expect(decoded.currencyCode == currency.code)
    #expect(decoded.financialYearStartMonth == 7)
  }

  @Test("import from JSON file creates new profile with correct data")
  func importFromFile() async throws {
    let (backend, _) = try await makeSeededBackend()
    let coordinator = MigrationCoordinator()

    let profile = Profile(
      label: "Original",
      backendType: .cloudKit,
      currencyCode: currency.code,
      financialYearStartMonth: 7
    )

    // Export first
    let tempURL = FileManager.default.temporaryDirectory
      .appending(path: "\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    try await coordinator.exportToFile(
      url: tempURL,
      backend: backend,
      profile: profile
    )

    // Import into a fresh container
    let destContainer = try TestModelContainer.create()
    let result = try await coordinator.importFromFile(
      url: tempURL,
      modelContainer: destContainer
    )

    #expect(result.accountCount == 1)
    #expect(result.categoryCount == 2)
    #expect(result.earmarkCount == 1)
    #expect(result.transactionCount == 1)

    // Verify data is readable through CloudKit repositories
    let destBackend = CloudKitBackend(
      modelContainer: destContainer,
      currency: currency,
      profileLabel: "Test"
    )
    let accounts = try await destBackend.accounts.fetchAll()
    #expect(accounts.count == 1)
    #expect(accounts[0].name == "Checking")

    let categories = try await destBackend.categories.fetchAll()
    #expect(categories.count == 2)

    // Verify category hierarchy preserved
    let groceries = categories.first { $0.name == "Groceries" }
    let food = categories.first { $0.name == "Food" }
    #expect(groceries?.parentId == food?.id)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test`
Expected: Compilation error — `exportToFile`, `importFromFile`, and `JSONDecoder.exportDecoder` don't exist.

- [ ] **Step 3: Add JSON encoder/decoder helpers**

Add to `Shared/ExportedData.swift`:

```swift
extension JSONEncoder {
  /// Encoder configured for Moolah export files.
  static var exportEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  /// Decoder configured for Moolah export files.
  static var exportDecoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
```

- [ ] **Step 4: Add exportToFile and importFromFile to MigrationCoordinator**

In `Backends/CloudKit/Migration/MigrationCoordinator.swift`, add these methods after the existing `migrate()` method:

```swift
/// Exports all data from a profile to a JSON file.
func exportToFile(
  url: URL,
  backend: any BackendProvider,
  profile: Profile
) async throws {
  state = .exporting(step: "Starting...")

  let exporter = DataExporter(backend: backend)
  let exported = try await exporter.export(
    profileLabel: profile.label,
    currencyCode: profile.currencyCode,
    financialYearStartMonth: profile.financialYearStartMonth
  ) { [weak self] progress in
    Task { @MainActor in
      switch progress {
      case .downloading(let step):
        self?.state = .exporting(step: step)
      default: break
      }
    }
  }

  let data = try JSONEncoder.exportEncoder.encode(exported)
  try data.write(to: url, options: .atomic)
  state = .idle
}

/// Imports data from a JSON file into a new SwiftData store.
/// Returns the import result. The caller is responsible for creating the profile
/// in ProfileStore and wiring it up.
func importFromFile(
  url: URL,
  modelContainer: ModelContainer
) async throws -> ImportResult {
  state = .importing(step: "reading file", progress: 0)

  let jsonData = try Data(contentsOf: url)
  let exported: ExportedData
  do {
    exported = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: jsonData)
  } catch {
    throw MigrationError.importFailed(underlying: error)
  }

  state = .importing(step: "saving", progress: 0.3)

  let importer = CloudKitDataImporter(
    modelContainer: modelContainer,
    currencyCode: exported.currencyCode
  )

  let result: ImportResult
  do {
    result = try importer.importData(exported)
  } catch {
    throw MigrationError.importFailed(underlying: error)
  }

  // Verify
  state = .verifying
  let verifier = MigrationVerifier()
  let verification = try await verifier.verify(
    exported: exported,
    modelContainer: modelContainer
  )

  if !verification.countMatch {
    state = .idle
    throw MigrationError.verificationFailed(verification)
  }

  state = .idle
  return result
}
```

- [ ] **Step 5: Update ExportedDataTests to use the encoder/decoder helpers**

In `MoolahTests/Export/ExportedDataTests.swift`, replace the manual encoder/decoder setup with the helpers:

```swift
// In jsonRoundTrip():
let data = try JSONEncoder.exportEncoder.encode(original)
let decoded = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: data)

// In versionInJSON():
let json = try JSONEncoder.exportEncoder.encode(data)
```

- [ ] **Step 6: Run tests**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add Backends/CloudKit/Migration/MigrationCoordinator.swift \
  Shared/ExportedData.swift \
  MoolahTests/Export/ExportImportIntegrationTests.swift \
  MoolahTests/Export/ExportedDataTests.swift
git commit -m "feat: add exportToFile and importFromFile to MigrationCoordinator"
```

---

### Task 4: Automatic Store Backup (macOS only)

Build `StoreBackupManager` that copies per-profile store files daily with 7-day retention.

**Files:**
- Create: `Shared/StoreBackupManager.swift`
- Test: `MoolahTests/Backup/StoreBackupManagerTests.swift`
- Modify: `App/MoolahApp.swift`

- [ ] **Step 1: Write tests for StoreBackupManager**

Create `MoolahTests/Backup/StoreBackupManagerTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("StoreBackupManager")
@MainActor
struct StoreBackupManagerTests {

  private func makeTestManager(
    backupDir: URL? = nil
  ) throws -> (StoreBackupManager, URL) {
    let dir = backupDir ?? FileManager.default.temporaryDirectory
      .appending(path: "moolah-backup-test-\(UUID().uuidString)")
    let manager = StoreBackupManager(backupDirectory: dir)
    return (manager, dir)
  }

  @Test("backup directory is created on first backup")
  func createsBackupDirectory() throws {
    let (manager, dir) = try makeTestManager()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Create a dummy store file to back up
    let storeURL = FileManager.default.temporaryDirectory
      .appending(path: "\(UUID().uuidString).store")
    FileManager.default.createFile(atPath: storeURL.path(), contents: Data("test".utf8))
    defer { try? FileManager.default.removeItem(at: storeURL) }

    let profileId = UUID()
    try manager.backupStore(at: storeURL, profileId: profileId)

    let profileDir = dir.appending(path: profileId.uuidString)
    #expect(FileManager.default.fileExists(atPath: profileDir.path()))
  }

  @Test("skips backup if today's backup already exists")
  func skipsIfAlreadyBackedUp() throws {
    let (manager, dir) = try makeTestManager()
    defer { try? FileManager.default.removeItem(at: dir) }

    let storeURL = FileManager.default.temporaryDirectory
      .appending(path: "\(UUID().uuidString).store")
    FileManager.default.createFile(atPath: storeURL.path(), contents: Data("test".utf8))
    defer { try? FileManager.default.removeItem(at: storeURL) }

    let profileId = UUID()
    try manager.backupStore(at: storeURL, profileId: profileId)
    // Second call should not throw and should not create a duplicate
    try manager.backupStore(at: storeURL, profileId: profileId)

    let profileDir = dir.appending(path: profileId.uuidString)
    let contents = try FileManager.default.contentsOfDirectory(atPath: profileDir.path())
    let storeFiles = contents.filter { $0.hasSuffix(".store") }
    #expect(storeFiles.count == 1)
  }

  @Test("prunes backups older than retention period")
  func prunesOldBackups() throws {
    let (manager, dir) = try makeTestManager()
    defer { try? FileManager.default.removeItem(at: dir) }

    let profileId = UUID()
    let profileDir = dir.appending(path: profileId.uuidString)
    try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

    // Create fake old backups
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    for daysAgo in 0..<10 {
      let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
      let filename = "\(formatter.string(from: date)).store"
      let fileURL = profileDir.appending(path: filename)
      FileManager.default.createFile(atPath: fileURL.path(), contents: Data("test".utf8))
    }

    manager.pruneBackups(profileId: profileId)

    let contents = try FileManager.default.contentsOfDirectory(atPath: profileDir.path())
    let storeFiles = contents.filter { $0.hasSuffix(".store") }
    #expect(storeFiles.count == 7)
  }

  @Test("todayBackupExists returns correct value")
  func todayBackupExists() throws {
    let (manager, dir) = try makeTestManager()
    defer { try? FileManager.default.removeItem(at: dir) }

    let profileId = UUID()
    #expect(manager.hasBackupForToday(profileId: profileId) == false)

    let profileDir = dir.appending(path: profileId.uuidString)
    try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let filename = "\(formatter.string(from: Date())).store"
    let fileURL = profileDir.appending(path: filename)
    FileManager.default.createFile(atPath: fileURL.path(), contents: Data("test".utf8))

    #expect(manager.hasBackupForToday(profileId: profileId) == true)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test`
Expected: Compilation error — `StoreBackupManager` doesn't exist.

- [ ] **Step 3: Implement StoreBackupManager**

Create `Shared/StoreBackupManager.swift`:

```swift
#if os(macOS)
  import CoreData
  import Foundation
  import OSLog

  /// Manages daily backups of per-profile SwiftData store files.
  /// Uses NSPersistentStoreCoordinator.replacePersistentStore on a temporary
  /// coordinator to safely copy live stores while CloudKit sync is active.
  @MainActor
  final class StoreBackupManager {
    private let backupDirectory: URL
    private let retentionDays: Int
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.moolah.app", category: "Backup")

    private static let dateFormatter: DateFormatter = {
      let f = DateFormatter()
      f.dateFormat = "yyyy-MM-dd"
      return f
    }()

    init(
      backupDirectory: URL = URL.applicationSupportDirectory
        .appending(path: "Moolah/Backups"),
      retentionDays: Int = 7,
      fileManager: FileManager = .default
    ) {
      self.backupDirectory = backupDirectory
      self.retentionDays = retentionDays
      self.fileManager = fileManager
    }

    /// Backs up a store file for the given profile if today's backup doesn't exist.
    func backupStore(at storeURL: URL, profileId: UUID) throws {
      guard !hasBackupForToday(profileId: profileId) else {
        logger.debug("Backup already exists for today, skipping \(profileId)")
        return
      }

      let profileDir = backupDirectory.appending(path: profileId.uuidString)
      try fileManager.createDirectory(at: profileDir, withIntermediateDirectories: true)

      let today = Self.dateFormatter.string(from: Date())
      let backupURL = profileDir.appending(path: "\(today).store")

      // Use a temporary coordinator to safely copy the store
      let coordinator = NSPersistentStoreCoordinator(
        managedObjectModel: NSManagedObjectModel()
      )
      try coordinator.replacePersistentStore(
        at: backupURL,
        withPersistentStoreFrom: storeURL,
        type: .sqlite
      )

      logger.info("Backed up profile \(profileId) to \(backupURL.lastPathComponent)")
    }

    /// Returns true if a backup already exists for today.
    func hasBackupForToday(profileId: UUID) -> Bool {
      let profileDir = backupDirectory.appending(path: profileId.uuidString)
      let today = Self.dateFormatter.string(from: Date())
      let backupURL = profileDir.appending(path: "\(today).store")
      return fileManager.fileExists(atPath: backupURL.path())
    }

    /// Deletes backups older than the retention period.
    func pruneBackups(profileId: UUID) {
      let profileDir = backupDirectory.appending(path: profileId.uuidString)
      guard let files = try? fileManager.contentsOfDirectory(atPath: profileDir.path()) else {
        return
      }

      let storeFiles = files.filter { $0.hasSuffix(".store") }.sorted().reversed()
      // Keep the most recent `retentionDays` files
      let toDelete = Array(storeFiles.dropFirst(retentionDays))
      for filename in toDelete {
        let fileURL = profileDir.appending(path: filename)
        try? fileManager.removeItem(at: fileURL)
        logger.debug("Pruned old backup: \(filename)")
      }
    }

    /// Runs the backup cycle for all iCloud profiles.
    func performDailyBackup(profiles: [Profile], containerManager: ProfileContainerManager) {
      let cloudProfiles = profiles.filter { $0.backendType == .cloudKit }
      for profile in cloudProfiles {
        do {
          let container = try containerManager.container(for: profile.id)
          guard let storeURL = container.configurations.first?.url else {
            logger.warning("No store URL for profile \(profile.id)")
            continue
          }
          try backupStore(at: storeURL, profileId: profile.id)
          pruneBackups(profileId: profile.id)
        } catch {
          logger.error("Backup failed for profile \(profile.id): \(error.localizedDescription)")
        }
      }
    }
  }
#endif
```

- [ ] **Step 4: Run tests**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 5: Wire up in MoolahApp**

In `App/MoolahApp.swift`, add the backup manager and daily timer inside the `#if os(macOS)` block.

Add a property to `MoolahApp`:

```swift
#if os(macOS)
  private let backupManager: StoreBackupManager
#endif
```

In `init()`, after the `containerManager` and `profileStore` are set up, inside `#if os(macOS)`:

```swift
#if os(macOS)
  backupManager = StoreBackupManager()
  _sessionManager = State(initialValue: SessionManager(containerManager: containerManager))
#endif
```

Add a `.task` modifier to the macOS `WindowGroup` body to trigger backup on launch and schedule a daily timer:

```swift
.task {
  backupManager.performDailyBackup(
    profiles: profileStore.profiles,
    containerManager: containerManager
  )
  // Schedule daily repeat
  Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { _ in
    Task { @MainActor in
      backupManager.performDailyBackup(
        profiles: profileStore.profiles,
        containerManager: containerManager
      )
    }
  }
}
```

- [ ] **Step 6: Run tests**

Run: `just test`
Expected: All tests pass. Build succeeds on both macOS and iOS targets.

- [ ] **Step 7: Commit**

```bash
git add Shared/StoreBackupManager.swift \
  MoolahTests/Backup/StoreBackupManagerTests.swift \
  App/MoolahApp.swift
git commit -m "feat: add automatic daily store backup on macOS with 7-day retention"
```

---

### Task 5: macOS File Menu Commands for Import/Export

Add Export Profile and Import Profile to the macOS File menu.

**Files:**
- Create: `Features/Export/ExportImportCommands.swift`
- Modify: `App/MoolahApp.swift`

- [ ] **Step 1: Create ExportImportCommands**

Create `Features/Export/ExportImportCommands.swift`:

```swift
#if os(macOS)
  import SwiftUI
  import UniformTypeIdentifiers

  /// macOS File menu commands for exporting and importing profiles.
  struct ExportImportCommands: Commands {
    let profileStore: ProfileStore
    let containerManager: ProfileContainerManager

    @FocusedValue(\.activeProfileSession) private var session

    var body: some Commands {
      CommandGroup(after: .saveItem) {
        Divider()

        Button("Export Profile...") {
          guard let session else { return }
          Task { await exportProfile(session: session) }
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(session == nil)

        Button("Import Profile...") {
          Task { await importProfile() }
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
      }
    }

    @MainActor
    private func exportProfile(session: ProfileSession) async {
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.json]
      panel.nameFieldStringValue = "\(session.profile.label).json"
      panel.canCreateDirectories = true

      guard panel.runModal() == .OK, let url = panel.url else { return }

      let coordinator = MigrationCoordinator()
      do {
        try await coordinator.exportToFile(
          url: url,
          backend: session.backend,
          profile: session.profile
        )
      } catch {
        let alert = NSAlert(error: error)
        alert.runModal()
      }
    }

    @MainActor
    private func importProfile() async {
      let panel = NSOpenPanel()
      panel.allowedContentTypes = [.json]
      panel.allowsMultipleSelection = false
      panel.canChooseDirectories = false

      guard panel.runModal() == .OK, let url = panel.url else { return }

      // Read the file to get profile metadata
      let jsonData: Data
      let exported: ExportedData
      do {
        jsonData = try Data(contentsOf: url)
        exported = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: jsonData)
      } catch {
        let alert = NSAlert(error: error)
        alert.runModal()
        return
      }

      // Create a new iCloud profile
      let newProfile = Profile(
        label: exported.profileLabel,
        backendType: .cloudKit,
        currencyCode: exported.currencyCode,
        financialYearStartMonth: exported.financialYearStartMonth
      )
      profileStore.addProfile(newProfile)

      do {
        let container = try containerManager.container(for: newProfile.id)
        let coordinator = MigrationCoordinator()
        _ = try await coordinator.importFromFile(
          url: url,
          modelContainer: container
        )
        profileStore.setActiveProfile(newProfile.id)
      } catch {
        // Clean up failed import
        profileStore.removeProfile(newProfile.id)
        let alert = NSAlert(error: error)
        alert.runModal()
      }
    }
  }
#endif
```

- [ ] **Step 2: Add FocusedValue for active session**

Check if `FocusedValues` already has an `activeProfileSession` key. If not, add to `Shared/FocusedValues.swift`:

```swift
extension FocusedValues {
  @Entry var activeProfileSession: ProfileSession?
}
```

And ensure the active session is published via `.focusedValue(\.activeProfileSession, session)` in the profile window view. Check `App/ProfileWindowView.swift` to find where other focused values are set and add it there.

- [ ] **Step 3: Register commands in MoolahApp**

In `App/MoolahApp.swift`, add `ExportImportCommands` to the macOS `.commands` block:

```swift
.commands {
  ProfileCommands(profileStore: profileStore, sessionManager: sessionManager)
  ExportImportCommands(profileStore: profileStore, containerManager: containerManager)
  NewTransactionCommands()
  NewEarmarkCommands()
  RefreshCommands()
  ShowHiddenCommands()
}
```

- [ ] **Step 4: Build and verify menu items appear**

Run: `just run-mac`
Expected: File menu shows "Export Profile..." and "Import Profile..." items. Export is disabled when no profile is active. Import is always enabled.

- [ ] **Step 5: Commit**

```bash
git add Features/Export/ExportImportCommands.swift \
  Shared/FocusedValues.swift \
  App/MoolahApp.swift
git commit -m "feat: add Export/Import Profile commands to macOS File menu"
```

---

### Task 6: Import/Export Buttons on Profile List (iOS and macOS)

Add import and export actions to the settings/profile list screen.

**Files:**
- Modify: `Features/Settings/SettingsView.swift`

- [ ] **Step 1: Add import button to iOS profile list**

In `Features/Settings/SettingsView.swift`, find the iOS `iOSLayout` section. Add an import button in the section that already has "Add Profile". Also add an export button per profile:

In the `Section("Profiles")` ForEach, add a swipe action or context menu for export on each profile row. In the section with "Add Profile", add an "Import Profile" button:

```swift
Section {
  Button {
    showAddProfile = true
  } label: {
    Label("Add Profile", systemImage: "plus")
  }

  Button {
    showImportPicker = true
  } label: {
    Label("Import Profile", systemImage: "square.and.arrow.down")
  }
}
```

Add state variables at the top of `SettingsView`:

```swift
@State private var showImportPicker = false
@State private var showExportPicker = false
@State private var exportFileURL: URL?
@State private var profileToExport: Profile?
@State private var importError: String?
@State private var isImporting = false
@State private var isExporting = false
```

- [ ] **Step 2: Add export action per profile on iOS**

In the iOS profile list, add a context menu or button for export on each profile. Use `.fileExporter` and `.fileImporter` SwiftUI modifiers for the file dialogs.

Add a `.fileImporter` modifier to the iOS layout:

```swift
.fileImporter(
  isPresented: $showImportPicker,
  allowedContentTypes: [.json]
) { result in
  Task { await handleImport(result: result) }
}
```

- [ ] **Step 3: Add import/export buttons to macOS profile list**

In the macOS `profileList` section, the bottom bar has `+` and `-` buttons. Add an import button there. Add an export option in the detail pane for each profile type (in `CloudKitProfileDetailView`, `MoolahProfileDetailView`, `CustomServerProfileDetailView`).

Alternatively, since macOS has the File menu commands (Task 5), the profile list only needs an import button for discoverability.

- [ ] **Step 4: Implement import/export handlers**

Add private methods to `SettingsView` for handling import and export. These follow the same pattern as `ExportImportCommands` but use SwiftUI file pickers instead of `NSSavePanel`/`NSOpenPanel`:

```swift
private func handleImport(result: Result<URL, Error>) async {
  guard case .success(let url) = result else { return }
  guard url.startAccessingSecurityScopedResource() else { return }
  defer { url.stopAccessingSecurityScopedResource() }

  isImporting = true
  defer { isImporting = false }

  do {
    let jsonData = try Data(contentsOf: url)
    let exported = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: jsonData)

    let newProfile = Profile(
      label: exported.profileLabel,
      backendType: .cloudKit,
      currencyCode: exported.currencyCode,
      financialYearStartMonth: exported.financialYearStartMonth
    )
    profileStore.addProfile(newProfile)

    guard let containerManager = profileStore.containerManager else { return }
    let container = try containerManager.container(for: newProfile.id)
    let coordinator = MigrationCoordinator()
    _ = try await coordinator.importFromFile(
      url: url,
      modelContainer: container
    )
    profileStore.setActiveProfile(newProfile.id)
  } catch {
    importError = error.localizedDescription
  }
}
```

Note: `profileStore.containerManager` is currently private. You'll need to expose it (or pass `containerManager` through the environment, which is already done on iOS via `.environment(containerManager)`). On iOS, get it from `@Environment(ProfileContainerManager.self)`.

- [ ] **Step 5: Build and test on both platforms**

Run: `just build-mac && just build-ios`
Expected: Both builds succeed. Import button visible on the profile list.

- [ ] **Step 6: Commit**

```bash
git add Features/Settings/SettingsView.swift
git commit -m "feat: add import/export buttons to profile list on iOS and macOS"
```

---

### Task 7: Add MigrationError Cases for Import/Export

Extend `MigrationError` with cases specific to file import/export so error messages are clear.

**Files:**
- Modify: `Backends/CloudKit/Migration/MigrationError.swift`

- [ ] **Step 1: Add new error cases**

In `Backends/CloudKit/Migration/MigrationError.swift`, add:

```swift
case fileReadFailed(URL, underlying: Error)
case unsupportedVersion(Int)
```

- [ ] **Step 2: Add localized descriptions**

In the `errorDescription` computed property, add:

```swift
case .fileReadFailed(let url, let underlying):
  return "Failed to read \(url.lastPathComponent): \(Self.detailedDescription(underlying))"
case .unsupportedVersion(let version):
  return "This file uses format version \(version), which is not supported by this version of Moolah."
```

- [ ] **Step 3: Use the new cases in importFromFile**

Update `MigrationCoordinator.importFromFile` to use `fileReadFailed` when `Data(contentsOf:)` fails, and check the version:

```swift
let jsonData: Data
do {
  jsonData = try Data(contentsOf: url)
} catch {
  throw MigrationError.fileReadFailed(url, underlying: error)
}

let exported: ExportedData
do {
  exported = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: jsonData)
} catch {
  throw MigrationError.importFailed(underlying: error)
}

guard exported.version <= 1 else {
  throw MigrationError.unsupportedVersion(exported.version)
}
```

- [ ] **Step 4: Run tests**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Migration/MigrationError.swift \
  Backends/CloudKit/Migration/MigrationCoordinator.swift
git commit -m "feat: add file-specific error cases for import/export"
```

---

### Task 8: Final Integration Testing

Manually test the full flow end-to-end and verify all automated tests pass.

- [ ] **Step 1: Run full test suite**

Run: `just test`
Expected: All tests pass on both iOS and macOS targets.

- [ ] **Step 2: Check for compiler warnings**

Use `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"` or build and check output. Fix any warnings (unused variables, unused results, etc.).

- [ ] **Step 3: Manual test on macOS**

Run: `just run-mac`

1. Open an iCloud profile with some data
2. File > Export Profile... — save to a location
3. Open the exported JSON file and verify it's readable, contains all data
4. File > Import Profile... — select the file
5. Verify a new profile appears in the list with the imported data
6. Verify automatic backup: check `~/Library/Application Support/Moolah/Backups/` contains a `.store` file for today

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "fix: address issues found during integration testing"
```
