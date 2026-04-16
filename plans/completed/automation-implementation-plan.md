# App Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three automation surfaces (AppleScript, App Intents, URL scheme) built on a shared operations layer, plus an AI skill for driving the app.

**Architecture:** A shared `AutomationService` class wraps existing stores/repositories. Three thin surface layers (AppleScript SDEF + command handlers, App Intents, URL scheme handler) call into it. `ProfileSessionManager` (extracted from `SessionManager`) resolves profile names/IDs to active `ProfileSession` instances.

**Tech Stack:** Swift 6.0, SwiftUI, AppIntents framework, NSAppleScript/SDEF, macOS 26+ / iOS 26+

**Design Spec:** `plans/automation-design.md`

---

## File Map

### New Files

```
Automation/
  AutomationService.swift         — Shared operations layer (@MainActor)
  AutomationError.swift           — Error types for automation operations
  AppleScript/
    Moolah.sdef                   — Scripting dictionary definition
    ScriptingBridge.swift         — NSApplication scripting delegate (macOS only)
    ScriptableProfile.swift       — NSObject wrapper for Profile
    ScriptableAccount.swift       — NSObject wrapper for Account
    ScriptableTransaction.swift   — NSObject wrapper for Transaction
    ScriptableEarmark.swift       — NSObject wrapper for Earmark
    ScriptableCategory.swift      — NSObject wrapper for Category
    Commands/
      CreateAccountCommand.swift
      CreateTransactionCommand.swift
      CreateEarmarkCommand.swift
      CreateCategoryCommand.swift
      DeleteCommand.swift
      PayScheduledCommand.swift
      RefreshCommand.swift
      NavigateCommand.swift
      NetWorthCommand.swift
      AnalysisCommands.swift
  Intents/
    Entities/
      ProfileEntity.swift
      AccountEntity.swift
      EarmarkEntity.swift
      CategoryEntity.swift
    GetNetWorthIntent.swift
    GetAccountBalanceIntent.swift
    ListAccountsIntent.swift
    CreateTransactionIntent.swift
    GetRecentTransactionsIntent.swift
    CreateEarmarkIntent.swift
    GetEarmarkBalanceIntent.swift
    AddInvestmentValueIntent.swift
    GetExpenseBreakdownIntent.swift
    GetMonthlySummaryIntent.swift
    OpenAccountIntent.swift
    RefreshDataIntent.swift
    MoolahShortcuts.swift
  URLScheme/
    URLSchemeHandler.swift

MoolahTests/
  Automation/
    AutomationServiceTests.swift
    URLSchemeHandlerTests.swift

.claude/skills/automate-app/
  SKILL.md
```

### Modified Files

```
App/MoolahApp.swift              — Add scripting support, onOpenURL handler, inject AutomationService
App/SessionManager.swift         — Add profile lookup by name, expose sessions for automation
App/ContentView.swift            — Accept navigation binding from URL scheme
App/Info.plist                   — Add NSAppleScriptEnabled key
project.yml                     — Add Automation/ to source paths, add AppIntents capability
```

---

## Task 1: AutomationError Type

**Files:**
- Create: `Automation/AutomationError.swift`
- Test: `MoolahTests/Automation/AutomationServiceTests.swift` (create file, first test)

- [ ] **Step 1: Create the error enum**

```swift
// Automation/AutomationError.swift
import Foundation

enum AutomationError: LocalizedError, Sendable {
  case profileNotFound(String)
  case profileNotOpen(String)
  case accountNotFound(String)
  case transactionNotFound(String)
  case earmarkNotFound(String)
  case categoryNotFound(String)
  case invalidParameter(String)
  case operationFailed(String)

  var errorDescription: String? {
    switch self {
    case .profileNotFound(let name): "Profile not found: \(name)"
    case .profileNotOpen(let name): "Profile not open: \(name)"
    case .accountNotFound(let name): "Account not found: \(name)"
    case .transactionNotFound(let id): "Transaction not found: \(id)"
    case .earmarkNotFound(let name): "Earmark not found: \(name)"
    case .categoryNotFound(let name): "Category not found: \(name)"
    case .invalidParameter(let detail): "Invalid parameter: \(detail)"
    case .operationFailed(let detail): "Operation failed: \(detail)"
    }
  }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-output.txt`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Automation/AutomationError.swift
git commit -m "feat(automation): add AutomationError type"
```

---

## Task 2: Extend SessionManager for Automation

**Files:**
- Modify: `App/SessionManager.swift`
- Test: `MoolahTests/Automation/AutomationServiceTests.swift`

The automation layer needs to resolve profiles by name (for AppleScript/URL scheme) and list all open sessions. Add these capabilities to the existing `SessionManager`.

- [ ] **Step 1: Write failing tests for profile resolution**

```swift
// MoolahTests/Automation/AutomationServiceTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("SessionManager Automation Extensions")
@MainActor
struct SessionManagerAutomationTests {
  private func makeProfile(label: String, id: UUID = UUID()) -> Profile {
    Profile(
      id: id,
      label: label,
      backendType: .cloudKit,
      serverURL: nil,
      cachedUserName: nil,
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date()
    )
  }

  @Test func findSessionByProfileName() throws {
    let manager = SessionManager(
      containerManager: try ProfileContainerManager(isTest: true))
    let profile = makeProfile(label: "Personal")
    _ = manager.session(for: profile)

    let found = manager.session(named: "Personal")
    #expect(found != nil)
    #expect(found?.profile.id == profile.id)
  }

  @Test func findSessionByProfileNameCaseInsensitive() throws {
    let manager = SessionManager(
      containerManager: try ProfileContainerManager(isTest: true))
    let profile = makeProfile(label: "Personal")
    _ = manager.session(for: profile)

    let found = manager.session(named: "personal")
    #expect(found != nil)
    #expect(found?.profile.id == profile.id)
  }

  @Test func findSessionByProfileNameReturnsNilWhenNotFound() throws {
    let manager = SessionManager(
      containerManager: try ProfileContainerManager(isTest: true))

    let found = manager.session(named: "Nonexistent")
    #expect(found == nil)
  }

  @Test func findSessionByUUID() throws {
    let id = UUID()
    let manager = SessionManager(
      containerManager: try ProfileContainerManager(isTest: true))
    let profile = makeProfile(label: "Personal", id: id)
    _ = manager.session(for: profile)

    let found = manager.session(forID: id)
    #expect(found != nil)
    #expect(found?.profile.label == "Personal")
  }

  @Test func openProfilesReturnsAllSessions() throws {
    let manager = SessionManager(
      containerManager: try ProfileContainerManager(isTest: true))
    let p1 = makeProfile(label: "Personal")
    let p2 = makeProfile(label: "Business")
    _ = manager.session(for: p1)
    _ = manager.session(for: p2)

    let profiles = manager.openProfiles
    #expect(profiles.count == 2)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt`
Expected: Compilation errors — `session(named:)`, `session(forID:)`, `openProfiles` don't exist yet.

- [ ] **Step 3: Add automation methods to SessionManager**

Add to `App/SessionManager.swift`:

```swift
  /// Find an open session by profile name (case-insensitive).
  func session(named name: String) -> ProfileSession? {
    let lowered = name.lowercased()
    return sessions.values.first { $0.profile.label.lowercased() == lowered }
  }

  /// Find an open session by profile UUID.
  func session(forID id: UUID) -> ProfileSession? {
    sessions[id]
  }

  /// All currently open profile sessions.
  var openProfiles: [ProfileSession] {
    Array(sessions.values)
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt`
Expected: All SessionManagerAutomationTests pass.

- [ ] **Step 5: Commit**

```bash
git add App/SessionManager.swift MoolahTests/Automation/AutomationServiceTests.swift
git commit -m "feat(automation): add profile lookup by name/ID to SessionManager"
```

---

## Task 3: AutomationService — Profile Operations

**Files:**
- Create: `Automation/AutomationService.swift`
- Modify: `MoolahTests/Automation/AutomationServiceTests.swift`

- [ ] **Step 1: Write failing tests for profile operations**

Add to `MoolahTests/Automation/AutomationServiceTests.swift`:

```swift
@Suite("AutomationService Profile Operations")
@MainActor
struct AutomationServiceProfileTests {
  private func makeProfile(label: String, id: UUID = UUID()) -> Profile {
    Profile(
      id: id,
      label: label,
      backendType: .cloudKit,
      serverURL: nil,
      cachedUserName: nil,
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date()
    )
  }

  @Test func resolveSessionByName() throws {
    let manager = SessionManager(
      containerManager: try ProfileContainerManager(isTest: true))
    let profile = makeProfile(label: "Personal")
    _ = manager.session(for: profile)

    let service = AutomationService(sessionManager: manager)
    let session = try service.resolveSession(for: "Personal")
    #expect(session.profile.id == profile.id)
  }

  @Test func resolveSessionByUUID() throws {
    let id = UUID()
    let manager = SessionManager(
      containerManager: try ProfileContainerManager(isTest: true))
    let profile = makeProfile(label: "Personal", id: id)
    _ = manager.session(for: profile)

    let service = AutomationService(sessionManager: manager)
    let session = try service.resolveSession(for: id.uuidString)
    #expect(session.profile.id == id)
  }

  @Test func resolveSessionThrowsWhenNotFound() throws {
    let manager = SessionManager(
      containerManager: try ProfileContainerManager(isTest: true))

    let service = AutomationService(sessionManager: manager)
    #expect(throws: AutomationError.self) {
      try service.resolveSession(for: "Nonexistent")
    }
  }

  @Test func listOpenProfiles() throws {
    let manager = SessionManager(
      containerManager: try ProfileContainerManager(isTest: true))
    let p1 = makeProfile(label: "Personal")
    let p2 = makeProfile(label: "Business")
    _ = manager.session(for: p1)
    _ = manager.session(for: p2)

    let service = AutomationService(sessionManager: manager)
    let profiles = service.listOpenProfiles()
    #expect(profiles.count == 2)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt`
Expected: Compilation errors — `AutomationService` doesn't exist.

- [ ] **Step 3: Create AutomationService with profile operations**

```swift
// Automation/AutomationService.swift
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.moolah.app", category: "AutomationService")

/// Shared operations layer for all automation surfaces (AppleScript, App Intents, URL scheme).
/// Each method maps to a user-visible automation action. All three surfaces are thin wrappers
/// around this single class.
@MainActor
final class AutomationService {
  let sessionManager: SessionManager

  init(sessionManager: SessionManager) {
    self.sessionManager = sessionManager
  }

  // MARK: - Profile Resolution

  /// Resolve a profile identifier (name or UUID string) to an open ProfileSession.
  /// Tries name match first (case-insensitive), then UUID match.
  func resolveSession(for identifier: String) throws -> ProfileSession {
    // Try name match first
    if let session = sessionManager.session(named: identifier) {
      return session
    }
    // Try UUID match
    if let uuid = UUID(uuidString: identifier),
      let session = sessionManager.session(forID: uuid)
    {
      return session
    }
    throw AutomationError.profileNotFound(identifier)
  }

  /// List all currently open profiles.
  func listOpenProfiles() -> [Profile] {
    sessionManager.openProfiles.map(\.profile)
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt`
Expected: All AutomationServiceProfileTests pass.

- [ ] **Step 5: Commit**

```bash
git add Automation/AutomationService.swift MoolahTests/Automation/AutomationServiceTests.swift
git commit -m "feat(automation): add AutomationService with profile resolution"
```

---

## Task 4: AutomationService — Account Operations

**Files:**
- Modify: `Automation/AutomationService.swift`
- Modify: `MoolahTests/Automation/AutomationServiceTests.swift`

- [ ] **Step 1: Write failing tests for account operations**

Add to `MoolahTests/Automation/AutomationServiceTests.swift`:

```swift
@Suite("AutomationService Account Operations")
@MainActor
struct AutomationServiceAccountTests {
  /// Helper: creates a SessionManager with one open CloudKit profile and seeded data.
  /// Returns (AutomationService, ModelContainer) for seeding additional data.
  private func makeService(
    profileLabel: String = "Test"
  ) throws -> (AutomationService, ProfileSession) {
    let manager = SessionManager(
      containerManager: try ProfileContainerManager(isTest: true))
    let profile = Profile(
      id: UUID(),
      label: profileLabel,
      backendType: .cloudKit,
      serverURL: nil,
      cachedUserName: nil,
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date()
    )
    let session = manager.session(for: profile)
    let service = AutomationService(sessionManager: manager)
    return (service, session)
  }

  @Test func listAccountsFromStore() async throws {
    let (service, session) = try makeService()
    // Load accounts into the store (store starts empty)
    await session.accountStore.load()
    let accounts = try service.listAccounts(profileIdentifier: "Test")
    #expect(accounts.isEmpty) // No seeded data
  }

  @Test func getNetWorth() async throws {
    let (service, session) = try makeService()
    await session.accountStore.load()
    let netWorth = try service.getNetWorth(profileIdentifier: "Test")
    #expect(netWorth.isZero)
  }

  @Test func resolveAccountByName() async throws {
    let (service, session) = try makeService()
    let account = Account(
      id: UUID(), name: "Savings", type: .bank,
      balance: .zero(instrument: .defaultTestInstrument),
      investmentValue: nil, positions: [],
      usesPositionTracking: false, position: 0, isHidden: false
    )
    _ = try await session.backend.accounts.create(account)
    await session.accountStore.load()

    let resolved = try service.resolveAccount(
      named: "Savings", profileIdentifier: "Test")
    #expect(resolved.name == "Savings")
  }

  @Test func resolveAccountByNameThrowsWhenNotFound() async throws {
    let (service, session) = try makeService()
    await session.accountStore.load()

    #expect(throws: AutomationError.self) {
      try service.resolveAccount(named: "Nonexistent", profileIdentifier: "Test")
    }
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt`
Expected: Compilation errors — account methods don't exist on AutomationService.

- [ ] **Step 3: Add account operations to AutomationService**

Add to `Automation/AutomationService.swift`:

```swift
  // MARK: - Account Operations

  /// List all accounts for a profile.
  func listAccounts(profileIdentifier: String) throws -> [Account] {
    let session = try resolveSession(for: profileIdentifier)
    return Array(session.accountStore.accounts)
  }

  /// Resolve an account by name (case-insensitive) within a profile.
  func resolveAccount(named name: String, profileIdentifier: String) throws -> Account {
    let session = try resolveSession(for: profileIdentifier)
    let lowered = name.lowercased()
    guard let account = session.accountStore.accounts.first(where: {
      $0.name.lowercased() == lowered
    }) else {
      throw AutomationError.accountNotFound(name)
    }
    return account
  }

  /// Resolve an account by UUID within a profile.
  func resolveAccount(id: UUID, profileIdentifier: String) throws -> Account {
    let session = try resolveSession(for: profileIdentifier)
    guard let account = session.accountStore.accounts.by(id: id) else {
      throw AutomationError.accountNotFound(id.uuidString)
    }
    return account
  }

  /// Get the net worth for a profile.
  func getNetWorth(profileIdentifier: String) throws -> InstrumentAmount {
    let session = try resolveSession(for: profileIdentifier)
    return session.accountStore.netWorth
  }

  /// Create a new account in a profile.
  func createAccount(
    profileIdentifier: String,
    name: String,
    type: AccountType,
    isHidden: Bool = false
  ) async throws -> Account {
    let session = try resolveSession(for: profileIdentifier)
    let account = Account(
      id: UUID(),
      name: name,
      type: type,
      balance: .zero(instrument: session.profile.instrument),
      investmentValue: nil,
      positions: [],
      usesPositionTracking: false,
      position: session.accountStore.accounts.count,
      isHidden: isHidden
    )
    guard let created = await session.accountStore.create(account) else {
      throw AutomationError.operationFailed("Failed to create account '\(name)'")
    }
    return created
  }

  /// Update an existing account in a profile.
  func updateAccount(
    profileIdentifier: String,
    accountId: UUID,
    name: String? = nil,
    isHidden: Bool? = nil
  ) async throws -> Account {
    let session = try resolveSession(for: profileIdentifier)
    guard var account = session.accountStore.accounts.by(id: accountId) else {
      throw AutomationError.accountNotFound(accountId.uuidString)
    }
    if let name { account.name = name }
    if let isHidden { account.isHidden = isHidden }
    await session.accountStore.update(account)
    return account
  }

  /// Delete an account from a profile.
  func deleteAccount(profileIdentifier: String, accountId: UUID) async throws {
    let session = try resolveSession(for: profileIdentifier)
    guard session.accountStore.accounts.by(id: accountId) != nil else {
      throw AutomationError.accountNotFound(accountId.uuidString)
    }
    await session.accountStore.delete(id: accountId)
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt`
Expected: All AutomationServiceAccountTests pass.

- [ ] **Step 5: Commit**

```bash
git add Automation/AutomationService.swift MoolahTests/Automation/AutomationServiceTests.swift
git commit -m "feat(automation): add account operations to AutomationService"
```

---

## Task 5: AutomationService — Transaction Operations

**Files:**
- Modify: `Automation/AutomationService.swift`
- Modify: `MoolahTests/Automation/AutomationServiceTests.swift`

- [ ] **Step 1: Write failing tests for transaction operations**

Add to `MoolahTests/Automation/AutomationServiceTests.swift`:

```swift
@Suite("AutomationService Transaction Operations")
@MainActor
struct AutomationServiceTransactionTests {
  private func makeService() throws -> (AutomationService, ProfileSession) {
    let manager = SessionManager(
      containerManager: try ProfileContainerManager(isTest: true))
    let profile = Profile(
      id: UUID(), label: "Test", backendType: .cloudKit,
      serverURL: nil, cachedUserName: nil, currencyCode: "AUD",
      financialYearStartMonth: 7, createdAt: Date()
    )
    let session = manager.session(for: profile)
    return (AutomationService(sessionManager: manager), session)
  }

  @Test func createSimpleExpense() async throws {
    let (service, session) = try makeService()
    await session.accountStore.load()
    await session.categoryStore.load()

    // Create an account first
    let account = try await service.createAccount(
      profileIdentifier: "Test", name: "Everyday", type: .bank)

    let transaction = try await service.createTransaction(
      profileIdentifier: "Test",
      payee: "Woolworths",
      date: Date(),
      legs: [AutomationService.LegSpec(
        accountName: "Everyday", amount: -42.50, categoryName: nil, earmarkName: nil
      )]
    )
    #expect(transaction.payee == "Woolworths")
    #expect(transaction.legs.count == 1)
    #expect(transaction.legs[0].accountId == account.id)
  }

  @Test func listTransactions() async throws {
    let (service, session) = try makeService()
    await session.accountStore.load()
    await session.categoryStore.load()

    _ = try await service.createAccount(
      profileIdentifier: "Test", name: "Everyday", type: .bank)
    _ = try await service.createTransaction(
      profileIdentifier: "Test", payee: "Test Tx", date: Date(),
      legs: [AutomationService.LegSpec(
        accountName: "Everyday", amount: -10.00, categoryName: nil, earmarkName: nil
      )]
    )

    let transactions = try await service.listTransactions(
      profileIdentifier: "Test", accountName: "Everyday")
    #expect(transactions.count == 1)
    #expect(transactions[0].payee == "Test Tx")
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt`
Expected: Compilation errors — transaction methods and `LegSpec` don't exist.

- [ ] **Step 3: Add transaction operations to AutomationService**

Add to `Automation/AutomationService.swift`:

```swift
  // MARK: - Transaction Operations

  /// Specification for a transaction leg, using names instead of IDs.
  struct LegSpec: Sendable {
    let accountName: String
    let amount: Decimal
    let categoryName: String?
    let earmarkName: String?
  }

  /// Create a transaction with legs specified by account/category/earmark names.
  func createTransaction(
    profileIdentifier: String,
    payee: String,
    date: Date,
    legs: [LegSpec],
    notes: String? = nil
  ) async throws -> Transaction {
    let session = try resolveSession(for: profileIdentifier)
    let resolvedLegs = try legs.map { spec -> TransactionLeg in
      let account = try resolveAccount(named: spec.accountName, profileIdentifier: profileIdentifier)
      let categoryId: UUID? = if let categoryName = spec.categoryName {
        try resolveCategory(named: categoryName, profileIdentifier: profileIdentifier).id
      } else {
        nil
      }
      let earmarkId: UUID? = if let earmarkName = spec.earmarkName {
        try resolveEarmark(named: earmarkName, profileIdentifier: profileIdentifier).id
      } else {
        nil
      }
      let quantity = spec.amount
      let type: TransactionType = quantity >= 0 ? .income : .expense
      return TransactionLeg(
        accountId: account.id,
        instrument: session.profile.instrument,
        quantity: quantity,
        type: type,
        categoryId: categoryId,
        earmarkId: earmarkId
      )
    }

    // Determine overall transaction type from legs
    let transactionType: TransactionType
    if resolvedLegs.count >= 2 {
      let accountIds = Set(resolvedLegs.compactMap(\.accountId))
      transactionType = accountIds.count > 1 ? .transfer : resolvedLegs[0].type
    } else {
      transactionType = resolvedLegs.first?.type ?? .expense
    }

    // For transfers, all legs use the .expense sign convention
    let finalLegs: [TransactionLeg]
    if transactionType == .transfer {
      finalLegs = resolvedLegs.map { leg in
        var updated = leg
        updated.type = .expense
        return updated
      }
    } else {
      finalLegs = resolvedLegs
    }

    let transaction = Transaction(
      id: UUID(),
      date: date,
      payee: payee,
      notes: notes,
      recurPeriod: nil,
      recurEvery: nil,
      legs: finalLegs
    )

    guard let created = await session.transactionStore.create(transaction) else {
      throw AutomationError.operationFailed("Failed to create transaction")
    }
    return created
  }

  /// List transactions for a profile, optionally filtered to an account.
  func listTransactions(
    profileIdentifier: String,
    accountName: String? = nil,
    scheduled: Bool? = nil
  ) async throws -> [Transaction] {
    let session = try resolveSession(for: profileIdentifier)
    var filter = TransactionFilter()
    if let accountName {
      let account = try resolveAccount(named: accountName, profileIdentifier: profileIdentifier)
      filter.accountId = account.id
    }
    filter.scheduled = scheduled
    await session.transactionStore.load(filter: filter)
    return session.transactionStore.transactions.map(\.transaction)
  }

  /// Delete a transaction by ID.
  func deleteTransaction(profileIdentifier: String, transactionId: UUID) async throws {
    let session = try resolveSession(for: profileIdentifier)
    await session.transactionStore.delete(id: transactionId)
  }

  /// Update a transaction (payee, date, notes).
  func updateTransaction(
    profileIdentifier: String,
    transactionId: UUID,
    payee: String? = nil,
    date: Date? = nil,
    notes: String? = nil
  ) async throws -> Transaction {
    let session = try resolveSession(for: profileIdentifier)
    guard let entry = session.transactionStore.transactions.first(where: {
      $0.transaction.id == transactionId
    }) else {
      throw AutomationError.transactionNotFound(transactionId.uuidString)
    }
    var updated = entry.transaction
    if let payee { updated.payee = payee }
    if let date { updated.date = date }
    if let notes { updated.notes = notes }
    await session.transactionStore.update(updated)
    return updated
  }

  /// Pay a scheduled transaction.
  func payScheduledTransaction(
    profileIdentifier: String,
    transactionId: UUID
  ) async throws -> TransactionStore.PayResult {
    let session = try resolveSession(for: profileIdentifier)
    // Find the transaction in the current loaded set
    guard let entry = session.transactionStore.transactions.first(where: {
      $0.transaction.id == transactionId
    }) else {
      throw AutomationError.transactionNotFound(transactionId.uuidString)
    }
    return await session.transactionStore.payScheduledTransaction(entry.transaction)
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt`
Expected: All AutomationServiceTransactionTests pass.

- [ ] **Step 5: Commit**

```bash
git add Automation/AutomationService.swift MoolahTests/Automation/AutomationServiceTests.swift
git commit -m "feat(automation): add transaction operations to AutomationService"
```

---

## Task 6: AutomationService — Earmark, Category, Investment, Analysis Operations

**Files:**
- Modify: `Automation/AutomationService.swift`
- Modify: `MoolahTests/Automation/AutomationServiceTests.swift`

- [ ] **Step 1: Write failing tests for remaining operations**

Add to `MoolahTests/Automation/AutomationServiceTests.swift`:

```swift
@Suite("AutomationService Earmark Operations")
@MainActor
struct AutomationServiceEarmarkTests {
  private func makeService() throws -> (AutomationService, ProfileSession) {
    let manager = SessionManager(
      containerManager: try ProfileContainerManager(isTest: true))
    let profile = Profile(
      id: UUID(), label: "Test", backendType: .cloudKit,
      serverURL: nil, cachedUserName: nil, currencyCode: "AUD",
      financialYearStartMonth: 7, createdAt: Date()
    )
    let session = manager.session(for: profile)
    return (AutomationService(sessionManager: manager), session)
  }

  @Test func createAndListEarmarks() async throws {
    let (service, session) = try makeService()
    await session.earmarkStore.load()

    let earmark = try await service.createEarmark(
      profileIdentifier: "Test", name: "Holiday Fund",
      targetAmount: 5000.00, savingsEndDate: nil
    )
    #expect(earmark.name == "Holiday Fund")

    let earmarks = try service.listEarmarks(profileIdentifier: "Test")
    #expect(earmarks.count == 1)
  }

  @Test func resolveEarmarkByName() async throws {
    let (service, session) = try makeService()
    await session.earmarkStore.load()
    _ = try await service.createEarmark(
      profileIdentifier: "Test", name: "Emergency", targetAmount: nil, savingsEndDate: nil)

    let resolved = try service.resolveEarmark(named: "Emergency", profileIdentifier: "Test")
    #expect(resolved.name == "Emergency")
  }
}

@Suite("AutomationService Category Operations")
@MainActor
struct AutomationServiceCategoryTests {
  private func makeService() throws -> (AutomationService, ProfileSession) {
    let manager = SessionManager(
      containerManager: try ProfileContainerManager(isTest: true))
    let profile = Profile(
      id: UUID(), label: "Test", backendType: .cloudKit,
      serverURL: nil, cachedUserName: nil, currencyCode: "AUD",
      financialYearStartMonth: 7, createdAt: Date()
    )
    let session = manager.session(for: profile)
    return (AutomationService(sessionManager: manager), session)
  }

  @Test func createAndListCategories() async throws {
    let (service, session) = try makeService()
    await session.categoryStore.load()

    let category = try await service.createCategory(
      profileIdentifier: "Test", name: "Groceries", parentName: nil)
    #expect(category.name == "Groceries")

    let categories = try service.listCategories(profileIdentifier: "Test")
    #expect(categories.count == 1)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt`
Expected: Compilation errors — earmark/category/investment/analysis methods don't exist.

- [ ] **Step 3: Add earmark operations**

Add to `Automation/AutomationService.swift`:

```swift
  // MARK: - Earmark Operations

  /// List all earmarks for a profile.
  func listEarmarks(profileIdentifier: String) throws -> [Earmark] {
    let session = try resolveSession(for: profileIdentifier)
    return Array(session.earmarkStore.earmarks)
  }

  /// Resolve an earmark by name (case-insensitive) within a profile.
  func resolveEarmark(named name: String, profileIdentifier: String) throws -> Earmark {
    let session = try resolveSession(for: profileIdentifier)
    let lowered = name.lowercased()
    guard let earmark = session.earmarkStore.earmarks.first(where: {
      $0.name.lowercased() == lowered
    }) else {
      throw AutomationError.earmarkNotFound(name)
    }
    return earmark
  }

  /// Create a new earmark in a profile.
  func createEarmark(
    profileIdentifier: String,
    name: String,
    targetAmount: Decimal?,
    savingsEndDate: Date?
  ) async throws -> Earmark {
    let session = try resolveSession(for: profileIdentifier)
    let instrument = session.profile.instrument
    let earmark = Earmark(
      id: UUID(),
      name: name,
      balance: .zero(instrument: instrument),
      saved: .zero(instrument: instrument),
      spent: .zero(instrument: instrument),
      isHidden: false,
      position: session.earmarkStore.earmarks.count,
      savingsGoal: targetAmount.map { InstrumentAmount(quantity: $0, instrument: instrument) },
      savingsStartDate: savingsEndDate != nil ? Date() : nil,
      savingsEndDate: savingsEndDate
    )
    guard let created = await session.earmarkStore.create(earmark) else {
      throw AutomationError.operationFailed("Failed to create earmark '\(name)'")
    }
    return created
  }

  /// Update an earmark in a profile.
  func updateEarmark(
    profileIdentifier: String,
    earmarkId: UUID,
    name: String? = nil,
    targetAmount: Decimal? = nil,
    savingsEndDate: Date? = nil
  ) async throws -> Earmark {
    let session = try resolveSession(for: profileIdentifier)
    guard var earmark = session.earmarkStore.earmarks.by(id: earmarkId) else {
      throw AutomationError.earmarkNotFound(earmarkId.uuidString)
    }
    if let name { earmark.name = name }
    if let targetAmount {
      earmark.savingsGoal = InstrumentAmount(
        quantity: targetAmount, instrument: session.profile.instrument)
    }
    if let savingsEndDate { earmark.savingsEndDate = savingsEndDate }
    await session.earmarkStore.update(earmark)
    return earmark
  }

  /// Delete an earmark from a profile.
  func deleteEarmark(profileIdentifier: String, earmarkId: UUID) async throws {
    let session = try resolveSession(for: profileIdentifier)
    await session.earmarkStore.delete(id: earmarkId)
  }
```

- [ ] **Step 4: Add category operations**

Add to `Automation/AutomationService.swift`:

```swift
  // MARK: - Category Operations

  /// List all categories for a profile.
  func listCategories(profileIdentifier: String) throws -> [Category] {
    let session = try resolveSession(for: profileIdentifier)
    return session.categoryStore.categories.flattenedByPath().map(\.category)
  }

  /// Resolve a category by name (case-insensitive) within a profile.
  func resolveCategory(named name: String, profileIdentifier: String) throws -> Category {
    let session = try resolveSession(for: profileIdentifier)
    let lowered = name.lowercased()
    // Search flattened list for exact match or path match (e.g., "Food > Groceries")
    let entries = session.categoryStore.categories.flattenedByPath()
    if let entry = entries.first(where: { $0.category.name.lowercased() == lowered }) {
      return entry.category
    }
    if let entry = entries.first(where: {
      session.categoryStore.categories.path(for: $0.category).lowercased() == lowered
    }) {
      return entry.category
    }
    throw AutomationError.categoryNotFound(name)
  }

  /// Create a new category in a profile.
  func createCategory(
    profileIdentifier: String,
    name: String,
    parentName: String?
  ) async throws -> Category {
    let session = try resolveSession(for: profileIdentifier)
    let parentId: UUID? = if let parentName {
      try resolveCategory(named: parentName, profileIdentifier: profileIdentifier).id
    } else {
      nil
    }
    let category = Category(id: UUID(), name: name, parentId: parentId)
    guard let created = await session.categoryStore.create(category) else {
      throw AutomationError.operationFailed("Failed to create category '\(name)'")
    }
    return created
  }

  /// Delete a category from a profile, optionally replacing references with another category.
  func deleteCategory(
    profileIdentifier: String,
    categoryId: UUID,
    replacementName: String? = nil
  ) async throws {
    let session = try resolveSession(for: profileIdentifier)
    let replacementId: UUID? = if let replacementName {
      try resolveCategory(named: replacementName, profileIdentifier: profileIdentifier).id
    } else {
      nil
    }
    await session.categoryStore.delete(id: categoryId, replacementId: replacementId)
  }
```

- [ ] **Step 5: Add investment and analysis operations**

Add to `Automation/AutomationService.swift`:

```swift
  // MARK: - Investment Operations

  /// Set the investment value for an account on a date.
  func setInvestmentValue(
    profileIdentifier: String,
    accountName: String,
    date: Date,
    value: Decimal
  ) async throws {
    let session = try resolveSession(for: profileIdentifier)
    let account = try resolveAccount(named: accountName, profileIdentifier: profileIdentifier)
    guard account.type == .investment else {
      throw AutomationError.invalidParameter("Account '\(accountName)' is not an investment account")
    }
    let amount = InstrumentAmount(quantity: value, instrument: session.profile.instrument)
    await session.investmentStore.setValue(accountId: account.id, date: date, value: amount)
  }

  /// Get positions for an investment account.
  func getPositions(
    profileIdentifier: String,
    accountName: String
  ) async throws -> [Position] {
    let session = try resolveSession(for: profileIdentifier)
    let account = try resolveAccount(named: accountName, profileIdentifier: profileIdentifier)
    return session.accountStore.positions(for: account.id)
  }

  // MARK: - Analysis Operations

  /// Load analysis data for a profile.
  func loadAnalysis(
    profileIdentifier: String,
    historyMonths: Int? = nil,
    forecastMonths: Int? = nil
  ) async throws -> AnalysisData {
    let session = try resolveSession(for: profileIdentifier)
    if let historyMonths { session.analysisStore.historyMonths = historyMonths }
    if let forecastMonths { session.analysisStore.forecastMonths = forecastMonths }
    await session.analysisStore.loadAll()
    return AnalysisData(
      dailyBalances: session.analysisStore.dailyBalances,
      expenseBreakdown: session.analysisStore.expenseBreakdown,
      incomeAndExpense: session.analysisStore.incomeAndExpense
    )
  }

  // MARK: - Refresh

  /// Reload all data for a profile from the backend.
  func refresh(profileIdentifier: String) async throws {
    let session = try resolveSession(for: profileIdentifier)
    async let accounts: () = session.accountStore.load()
    async let categories: () = session.categoryStore.load()
    async let earmarks: () = session.earmarkStore.load()
    _ = await (accounts, categories, earmarks)
  }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt`
Expected: All new tests pass.

- [ ] **Step 7: Check for warnings**

Run: `mcp__xcode__XcodeListNavigatorIssues` with severity "warning". Fix any warnings in automation code.

- [ ] **Step 8: Commit**

```bash
git add Automation/AutomationService.swift MoolahTests/Automation/AutomationServiceTests.swift
git commit -m "feat(automation): add earmark, category, investment, analysis operations"
```

---

## Task 7: URL Scheme Handler

**Files:**
- Create: `Automation/URLScheme/URLSchemeHandler.swift`
- Modify: `App/MoolahApp.swift`
- Modify: `App/ContentView.swift`
- Test: `MoolahTests/Automation/URLSchemeHandlerTests.swift`

- [ ] **Step 1: Write tests for URL parsing**

```swift
// MoolahTests/Automation/URLSchemeHandlerTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("URLSchemeHandler")
struct URLSchemeHandlerTests {
  @Test func parsesProfileOnly() throws {
    let url = URL(string: "moolah://Personal")!
    let route = try URLSchemeHandler.parse(url)
    #expect(route.profileIdentifier == "Personal")
    #expect(route.destination == nil)
  }

  @Test func parsesAccountRoute() throws {
    let url = URL(string: "moolah://Personal/account/550e8400-e29b-41d4-a716-446655440000")!
    let route = try URLSchemeHandler.parse(url)
    #expect(route.profileIdentifier == "Personal")
    if case .account(let id) = route.destination {
      #expect(id == UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
    } else {
      Issue.record("Expected .account destination")
    }
  }

  @Test func parsesTransactionRoute() throws {
    let url = URL(string: "moolah://Personal/transaction/550e8400-e29b-41d4-a716-446655440000")!
    let route = try URLSchemeHandler.parse(url)
    if case .transaction(let id) = route.destination {
      #expect(id == UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
    } else {
      Issue.record("Expected .transaction destination")
    }
  }

  @Test func parsesAnalysisWithQueryParams() throws {
    let url = URL(string: "moolah://Personal/analysis?history=12&forecast=3")!
    let route = try URLSchemeHandler.parse(url)
    if case .analysis(let history, let forecast) = route.destination {
      #expect(history == 12)
      #expect(forecast == 3)
    } else {
      Issue.record("Expected .analysis destination")
    }
  }

  @Test func parsesReportsWithDateRange() throws {
    let url = URL(string: "moolah://Personal/reports?from=2026-01-01&to=2026-03-31")!
    let route = try URLSchemeHandler.parse(url)
    if case .reports(let from, let to) = route.destination {
      #expect(from != nil)
      #expect(to != nil)
    } else {
      Issue.record("Expected .reports destination")
    }
  }

  @Test func parsesEncodedProfileName() throws {
    let url = URL(string: "moolah://My%20Finances/analysis")!
    let route = try URLSchemeHandler.parse(url)
    #expect(route.profileIdentifier == "My Finances")
  }

  @Test func parsesSimpleDestinations() throws {
    for (path, expected) in [
      ("categories", URLSchemeHandler.Destination.categories),
      ("earmarks", .earmarks),
      ("upcoming", .upcoming),
      ("accounts", .accounts),
    ] {
      let url = URL(string: "moolah://Test/\(path)")!
      let route = try URLSchemeHandler.parse(url)
      #expect(route.destination == expected)
    }
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt`
Expected: Compilation errors — `URLSchemeHandler` doesn't exist.

- [ ] **Step 3: Implement URLSchemeHandler**

```swift
// Automation/URLScheme/URLSchemeHandler.swift
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.moolah.app", category: "URLScheme")

/// Parses `moolah://` URLs into structured routes and applies them to app navigation.
enum URLSchemeHandler {
  /// A parsed URL route.
  struct Route: Sendable {
    let profileIdentifier: String
    let destination: Destination?
  }

  /// Navigation destinations that can be expressed as URLs.
  enum Destination: Sendable, Equatable {
    case accounts
    case account(UUID)
    case transaction(UUID)
    case earmarks
    case earmark(UUID)
    case analysis(history: Int?, forecast: Int?)
    case reports(from: Date?, to: Date?)
    case categories
    case upcoming
  }

  /// Parse a `moolah://` URL into a Route.
  static func parse(_ url: URL) throws -> Route {
    guard url.scheme == "moolah" else {
      throw AutomationError.invalidParameter("URL scheme must be 'moolah'")
    }

    // Host is the profile identifier (URL-decoded)
    guard let profileIdentifier = url.host(percentEncoded: false), !profileIdentifier.isEmpty else {
      throw AutomationError.invalidParameter("URL must include a profile name: moolah://ProfileName/...")
    }

    let pathComponents = url.pathComponents.filter { $0 != "/" }

    guard !pathComponents.isEmpty else {
      return Route(profileIdentifier: profileIdentifier, destination: nil)
    }

    let destination: Destination
    let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

    switch pathComponents[0].lowercased() {
    case "accounts":
      destination = .accounts

    case "account":
      guard pathComponents.count >= 2, let id = UUID(uuidString: pathComponents[1]) else {
        throw AutomationError.invalidParameter("account requires a valid UUID")
      }
      destination = .account(id)

    case "transaction":
      guard pathComponents.count >= 2, let id = UUID(uuidString: pathComponents[1]) else {
        throw AutomationError.invalidParameter("transaction requires a valid UUID")
      }
      destination = .transaction(id)

    case "earmarks":
      destination = .earmarks

    case "earmark":
      guard pathComponents.count >= 2, let id = UUID(uuidString: pathComponents[1]) else {
        throw AutomationError.invalidParameter("earmark requires a valid UUID")
      }
      destination = .earmark(id)

    case "analysis":
      let history = queryItems.first(where: { $0.name == "history" })
        .flatMap { $0.value.flatMap(Int.init) }
      let forecast = queryItems.first(where: { $0.name == "forecast" })
        .flatMap { $0.value.flatMap(Int.init) }
      destination = .analysis(history: history, forecast: forecast)

    case "reports":
      let dateFormatter = ISO8601DateFormatter()
      dateFormatter.formatOptions = [.withFullDate]
      let from = queryItems.first(where: { $0.name == "from" })
        .flatMap { $0.value.flatMap { dateFormatter.date(from: $0) } }
      let to = queryItems.first(where: { $0.name == "to" })
        .flatMap { $0.value.flatMap { dateFormatter.date(from: $0) } }
      destination = .reports(from: from, to: to)

    case "categories":
      destination = .categories

    case "upcoming":
      destination = .upcoming

    default:
      throw AutomationError.invalidParameter("Unknown destination: \(pathComponents[0])")
    }

    return Route(profileIdentifier: profileIdentifier, destination: destination)
  }

  /// Convert a Destination to a SidebarSelection for navigation.
  static func toSidebarSelection(_ destination: Destination) -> SidebarSelection? {
    switch destination {
    case .accounts: nil // No single sidebar selection for account list
    case .account(let id): .account(id)
    case .transaction: nil // Transaction detail handled separately
    case .earmarks: nil // No single sidebar selection for earmark list
    case .earmark(let id): .earmark(id)
    case .analysis: .analysis
    case .reports: .reports
    case .categories: .categories
    case .upcoming: .upcomingTransactions
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt`
Expected: All URLSchemeHandlerTests pass.

- [ ] **Step 5: Wire URL handler into MoolahApp**

Add `onOpenURL` to the scene in `App/MoolahApp.swift`. On macOS, inside the `WindowGroup(for: Profile.ID.self)` block, add after the `.commands` block:

```swift
// In the macOS WindowGroup, add after .commands { ... }
.handlesExternalEvents(matching: ["moolah"])
```

And add a method to `MoolahApp`:

```swift
  // MARK: - URL Scheme Handling

  private func handleURL(_ url: URL) {
    logger.info("Handling URL: \(url.absoluteString, privacy: .public)")
    do {
      let route = try URLSchemeHandler.parse(url)
      // Find or open the profile
      if let profile = profileStore.profiles.first(where: {
        $0.label.lowercased() == route.profileIdentifier.lowercased()
      }) ?? profileStore.profiles.first(where: {
        $0.id.uuidString.lowercased() == route.profileIdentifier.lowercased()
      }) {
        #if os(macOS)
          // Open the profile window (brings to front if already open)
          openWindow(value: profile.id)
        #else
          profileStore.setActiveProfile(profile.id)
        #endif

        // Store the pending navigation for the window to pick up
        if let destination = route.destination {
          pendingNavigation = PendingNavigation(
            profileId: profile.id, destination: destination)
        }
      } else {
        logger.warning("Profile not found for URL: \(route.profileIdentifier, privacy: .public)")
      }
    } catch {
      logger.error("Failed to parse URL: \(error.localizedDescription, privacy: .public)")
    }
  }
```

Add to MoolahApp properties:

```swift
  @State private var pendingNavigation: PendingNavigation?

  struct PendingNavigation {
    let profileId: UUID
    let destination: URLSchemeHandler.Destination
  }
```

Add `.onOpenURL(perform: handleURL)` to both macOS and iOS scene bodies, and `@Environment(\.openWindow) private var openWindow` on macOS.

- [ ] **Step 6: Wire ContentView to accept navigation from URL scheme**

Modify `App/ContentView.swift` to accept an optional `Binding<URLSchemeHandler.Destination?>` or use an environment value to receive pending navigation. The simplest approach: add an `onAppear`/`onChange` that reads pending navigation from the `AutomationService` or an environment object and translates it to `SidebarSelection`.

This step requires careful integration with the existing navigation model. The key change is:

```swift
// In ContentView, add a method to handle URL navigation
func applyNavigation(_ destination: URLSchemeHandler.Destination) {
  if let sidebarSelection = URLSchemeHandler.toSidebarSelection(destination) {
    selection = sidebarSelection
  }
  // Handle analysis/reports query params
  if case .analysis(let history, let forecast) = destination {
    if let history { analysisStore.historyMonths = history }
    if let forecast { analysisStore.forecastMonths = forecast }
  }
}
```

- [ ] **Step 7: Run full test suite**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt`
Expected: All tests pass.

- [ ] **Step 8: Check for warnings**

Run: `mcp__xcode__XcodeListNavigatorIssues` with severity "warning". Fix any warnings.

- [ ] **Step 9: Commit**

```bash
git add Automation/URLScheme/URLSchemeHandler.swift MoolahTests/Automation/URLSchemeHandlerTests.swift App/MoolahApp.swift App/ContentView.swift
git commit -m "feat(automation): add moolah:// URL scheme handler with deep linking"
```

---

## Task 8: Update project.yml

**Files:**
- Modify: `project.yml`

The `Automation/` directory needs to be added to both iOS and macOS target sources.

- [ ] **Step 1: Add Automation/ to source paths**

In `project.yml`, add `- path: Automation` to the sources list for both `Moolah_iOS` and `Moolah_macOS` targets, alongside the existing entries for `App`, `Domain`, `Backends`, `Features`, `Shared`.

- [ ] **Step 2: Add AppIntents capability**

If the project.yml has a capabilities or entitlements section, ensure AppIntents framework is linked. Add `AppIntents` to the frameworks list for both targets.

- [ ] **Step 3: Regenerate Xcode project**

Run: `just generate`

- [ ] **Step 4: Build to verify**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-output.txt`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add project.yml
git commit -m "build: add Automation/ sources and AppIntents framework to project"
```

---

## Task 9: AppleScript SDEF — Scripting Dictionary

**Files:**
- Create: `Automation/AppleScript/Moolah.sdef`
- Modify: `App/Info.plist`

This is macOS-only. The SDEF defines the Apple Event object model for the app.

- [ ] **Step 1: Create the SDEF file**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE dictionary SYSTEM "file://localhost/System/Library/DTDs/sdef.dtd">
<dictionary title="Moolah Terminology">

  <!-- Standard Suite (inherited commands) -->
  <suite name="Standard Suite" code="????" description="Common classes and commands for all applications.">
    <command name="open" code="aevtodoc" description="Open a profile.">
      <direct-parameter description="The profile to open." type="text"/>
    </command>

    <command name="close" code="coreclos" description="Close a window.">
      <direct-parameter description="The window to close." type="specifier"/>
    </command>

    <command name="quit" code="aevtquit" description="Quit the application."/>

    <command name="count" code="corecnte" description="Return the number of elements of a particular type in an object.">
      <direct-parameter description="The objects to be counted." type="specifier"/>
      <parameter name="each" code="kocl" description="The type of object to count." type="type" optional="yes"/>
      <result description="The count." type="integer"/>
    </command>
  </suite>

  <!-- Moolah Suite -->
  <suite name="Moolah Suite" code="Mool" description="Moolah-specific classes and commands.">

    <!-- Application element -->
    <class name="application" code="capp" description="The Moolah application.">
      <cocoa class="NSApplication"/>
      <element type="profile" access="r">
        <cocoa key="scriptableProfiles"/>
      </element>
    </class>

    <!-- Profile -->
    <class name="profile" code="Prof" description="A financial profile." plural="profiles">
      <cocoa class="ScriptableProfile"/>
      <property name="id" code="ID  " description="The unique identifier." type="text" access="r">
        <cocoa key="uniqueID"/>
      </property>
      <property name="name" code="pnam" description="The profile name." type="text" access="r">
        <cocoa key="name"/>
      </property>
      <property name="currency" code="Pcur" description="The profile currency code." type="text" access="r">
        <cocoa key="currencyCode"/>
      </property>
      <element type="account" access="r">
        <cocoa key="scriptableAccounts"/>
      </element>
      <element type="transaction" access="r">
        <cocoa key="scriptableTransactions"/>
      </element>
      <element type="earmark" access="r">
        <cocoa key="scriptableEarmarks"/>
      </element>
      <element type="category" access="r">
        <cocoa key="scriptableCategories"/>
      </element>
    </class>

    <!-- Account -->
    <class name="account" code="Acct" description="A financial account." plural="accounts">
      <cocoa class="ScriptableAccount"/>
      <property name="id" code="ID  " description="The unique identifier." type="text" access="r">
        <cocoa key="uniqueID"/>
      </property>
      <property name="name" code="pnam" description="The account name." type="text" access="r">
        <cocoa key="name"/>
      </property>
      <property name="account type" code="Atyp" description="The account type (bank, cc, asset, investment)." type="text" access="r">
        <cocoa key="accountType"/>
      </property>
      <property name="balance" code="Abal" description="The current balance." type="real" access="r">
        <cocoa key="balance"/>
      </property>
      <property name="investment value" code="Aivl" description="The current investment value." type="real" access="r">
        <cocoa key="investmentValue"/>
      </property>
      <property name="hidden" code="Ahid" description="Whether the account is hidden." type="boolean" access="r">
        <cocoa key="isHidden"/>
      </property>
    </class>

    <!-- Transaction -->
    <class name="transaction" code="Txn " description="A financial transaction." plural="transactions">
      <cocoa class="ScriptableTransaction"/>
      <property name="id" code="ID  " description="The unique identifier." type="text" access="r">
        <cocoa key="uniqueID"/>
      </property>
      <property name="date" code="Tdat" description="The transaction date." type="date" access="r">
        <cocoa key="date"/>
      </property>
      <property name="payee" code="Tpay" description="The payee." type="text" access="r">
        <cocoa key="payee"/>
      </property>
      <property name="notes" code="Tnot" description="Notes." type="text" access="r">
        <cocoa key="notes"/>
      </property>
      <property name="transaction type" code="Ttyp" description="The type (income, expense, transfer, openingBalance)." type="text" access="r">
        <cocoa key="transactionType"/>
      </property>
      <property name="amount" code="Tamt" description="The total amount (sum of legs)." type="real" access="r">
        <cocoa key="amount"/>
      </property>
      <property name="scheduled" code="Tsch" description="Whether this is a scheduled transaction." type="boolean" access="r">
        <cocoa key="isScheduled"/>
      </property>
      <element type="leg" access="r">
        <cocoa key="scriptableLegs"/>
      </element>
    </class>

    <!-- Transaction Leg -->
    <class name="leg" code="TLeg" description="A transaction leg." plural="legs">
      <cocoa class="ScriptableLeg"/>
      <property name="account name" code="Lacn" description="The account name." type="text" access="r">
        <cocoa key="accountName"/>
      </property>
      <property name="amount" code="Lamt" description="The leg amount." type="real" access="r">
        <cocoa key="amount"/>
      </property>
      <property name="category name" code="Lcat" description="The category name." type="text" access="r">
        <cocoa key="categoryName"/>
      </property>
      <property name="type" code="Ltyp" description="The leg type." type="text" access="r">
        <cocoa key="legType"/>
      </property>
    </class>

    <!-- Earmark -->
    <class name="earmark" code="Emrk" description="A budget earmark." plural="earmarks">
      <cocoa class="ScriptableEarmark"/>
      <property name="id" code="ID  " description="The unique identifier." type="text" access="r">
        <cocoa key="uniqueID"/>
      </property>
      <property name="name" code="pnam" description="The earmark name." type="text" access="r">
        <cocoa key="name"/>
      </property>
      <property name="balance" code="Ebal" description="The current balance." type="real" access="r">
        <cocoa key="balance"/>
      </property>
      <property name="target amount" code="Etar" description="The savings target amount." type="real" access="r">
        <cocoa key="targetAmount"/>
      </property>
    </class>

    <!-- Category -->
    <class name="category" code="Catg" description="A transaction category." plural="categories">
      <cocoa class="ScriptableCategory"/>
      <property name="id" code="ID  " description="The unique identifier." type="text" access="r">
        <cocoa key="uniqueID"/>
      </property>
      <property name="name" code="pnam" description="The category name." type="text" access="r">
        <cocoa key="name"/>
      </property>
      <property name="parent name" code="Cpnm" description="The parent category name." type="text" access="r">
        <cocoa key="parentName"/>
      </property>
    </class>

    <!-- Commands -->

    <command name="create account" code="Moolcrac" description="Create a new account.">
      <direct-parameter description="The profile to create the account in." type="specifier"/>
      <parameter name="name" code="Cnam" description="The account name." type="text">
        <cocoa key="name"/>
      </parameter>
      <parameter name="type" code="Ctyp" description="The account type (bank, cc, asset, investment)." type="text">
        <cocoa key="accountType"/>
      </parameter>
      <result description="The created account." type="account"/>
    </command>

    <command name="create transaction" code="Moolcrtx" description="Create a new transaction.">
      <direct-parameter description="The profile to create the transaction in." type="specifier"/>
      <parameter name="with payee" code="Cpay" description="The payee name." type="text">
        <cocoa key="payee"/>
      </parameter>
      <parameter name="amount" code="Camt" description="The amount (for single-leg transactions)." type="real">
        <cocoa key="amount"/>
      </parameter>
      <parameter name="account" code="Cacc" description="The account name (for single-leg transactions)." type="text">
        <cocoa key="accountName"/>
      </parameter>
      <parameter name="category" code="Ccat" description="The category name (optional)." type="text" optional="yes">
        <cocoa key="categoryName"/>
      </parameter>
      <parameter name="date" code="Cdat" description="The transaction date." type="date" optional="yes">
        <cocoa key="date"/>
      </parameter>
      <parameter name="notes" code="Cnot" description="Notes (optional)." type="text" optional="yes">
        <cocoa key="notes"/>
      </parameter>
      <result description="The created transaction." type="transaction"/>
    </command>

    <command name="create earmark" code="Moolcrem" description="Create a new earmark.">
      <direct-parameter description="The profile to create the earmark in." type="specifier"/>
      <parameter name="name" code="Cnam" description="The earmark name." type="text">
        <cocoa key="name"/>
      </parameter>
      <parameter name="target" code="Ctar" description="The target amount (optional)." type="real" optional="yes">
        <cocoa key="targetAmount"/>
      </parameter>
      <result description="The created earmark." type="earmark"/>
    </command>

    <command name="create category" code="Moolcrca" description="Create a new category.">
      <direct-parameter description="The profile to create the category in." type="specifier"/>
      <parameter name="name" code="Cnam" description="The category name." type="text">
        <cocoa key="name"/>
      </parameter>
      <parameter name="parent" code="Cpar" description="The parent category name (optional)." type="text" optional="yes">
        <cocoa key="parentCategory"/>
      </parameter>
      <result description="The created category." type="category"/>
    </command>

    <command name="delete" code="Mooldelt" description="Delete an object.">
      <direct-parameter description="The object to delete." type="specifier"/>
    </command>

    <command name="pay" code="Moolpays" description="Pay a scheduled transaction.">
      <direct-parameter description="The scheduled transaction to pay." type="specifier"/>
    </command>

    <command name="refresh" code="Moolrefr" description="Refresh data from the server.">
      <direct-parameter description="The profile to refresh (optional)." type="specifier" optional="yes"/>
    </command>

    <command name="navigate to" code="Moolnavt" description="Navigate to a view.">
      <direct-parameter description="The object to navigate to (account, earmark, etc.)." type="specifier"/>
    </command>

    <command name="net worth" code="Moolnetw" description="Get the net worth of a profile.">
      <direct-parameter description="The profile." type="specifier"/>
      <result description="The net worth as a decimal." type="real"/>
    </command>

  </suite>
</dictionary>
```

- [ ] **Step 2: Add NSAppleScriptEnabled to Info.plist**

Add to `App/Info.plist` inside the top-level `<dict>`:

```xml
<key>NSAppleScriptEnabled</key>
<true/>
<key>OSAScriptingDefinition</key>
<string>Moolah.sdef</string>
```

- [ ] **Step 3: Add SDEF to project.yml resources**

Ensure the SDEF file is included as a resource in the macOS target. Add to the macOS target's resources or settings in `project.yml`.

- [ ] **Step 4: Build to verify SDEF is valid**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-output.txt`
Expected: BUILD SUCCEEDED (the build validates the SDEF format).

- [ ] **Step 5: Commit**

```bash
git add Automation/AppleScript/Moolah.sdef App/Info.plist project.yml
git commit -m "feat(automation): add AppleScript scripting dictionary (SDEF)"
```

---

## Task 10: AppleScript Scriptable Object Wrappers

**Files:**
- Create: `Automation/AppleScript/ScriptableProfile.swift`
- Create: `Automation/AppleScript/ScriptableAccount.swift`
- Create: `Automation/AppleScript/ScriptableTransaction.swift`
- Create: `Automation/AppleScript/ScriptableEarmark.swift`
- Create: `Automation/AppleScript/ScriptableCategory.swift`

These `NSObject` subclasses wrap domain models for the AppleScript object model. They must be macOS-only (`#if os(macOS)`).

- [ ] **Step 1: Create ScriptableProfile**

```swift
// Automation/AppleScript/ScriptableProfile.swift
#if os(macOS)
  import Cocoa
  import Foundation

  /// NSObject wrapper for Profile, exposed to AppleScript as the "profile" class.
  class ScriptableProfile: NSObject {
    let session: ProfileSession
    let automationService: AutomationService

    init(session: ProfileSession, automationService: AutomationService) {
      self.session = session
      self.automationService = automationService
      super.init()
    }

    @objc var uniqueID: String { session.profile.id.uuidString }
    @objc var name: String { session.profile.label }
    @objc var currencyCode: String { session.profile.currencyCode }

    @objc var scriptableAccounts: [ScriptableAccount] {
      session.accountStore.accounts.map {
        ScriptableAccount(account: $0, session: session)
      }
    }

    @objc var scriptableEarmarks: [ScriptableEarmark] {
      session.earmarkStore.earmarks.map {
        ScriptableEarmark(earmark: $0)
      }
    }

    @objc var scriptableCategories: [ScriptableCategory] {
      session.categoryStore.categories.flattenedByPath().map {
        ScriptableCategory(
          category: $0.category,
          categories: session.categoryStore.categories
        )
      }
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
      guard let appDescription = NSApp.classDescription as? NSScriptClassDescription else {
        return nil
      }
      return NSNameSpecifier(
        containerClassDescription: appDescription,
        containerSpecifier: nil,
        key: "scriptableProfiles",
        name: name
      )
    }
  }
#endif
```

- [ ] **Step 2: Create ScriptableAccount**

```swift
// Automation/AppleScript/ScriptableAccount.swift
#if os(macOS)
  import Cocoa
  import Foundation

  class ScriptableAccount: NSObject {
    let account: Account
    let session: ProfileSession

    init(account: Account, session: ProfileSession) {
      self.account = account
      self.session = session
      super.init()
    }

    @objc var uniqueID: String { account.id.uuidString }
    @objc var name: String { account.name }
    @objc var accountType: String { account.type.rawValue }
    @objc var balance: Double { account.balance.doubleValue }
    @objc var investmentValue: Double { account.investmentValue?.doubleValue ?? 0 }
    @objc var isHidden: Bool { account.isHidden }

    override var objectSpecifier: NSScriptObjectSpecifier? {
      let profileSpecifier = ScriptableProfile(
        session: session,
        automationService: AutomationService(sessionManager: SessionManager(containerManager: session.containerManager))
      ).objectSpecifier
      guard let profileSpecifier,
        let profileDescription = profileSpecifier.keyClassDescription
      else { return nil }
      return NSNameSpecifier(
        containerClassDescription: profileDescription as! NSScriptClassDescription,
        containerSpecifier: profileSpecifier,
        key: "scriptableAccounts",
        name: name
      )
    }
  }
#endif
```

Note: The `objectSpecifier` implementation above is a starting point. During implementation, the actual wiring will depend on how the scripting bridge resolves object hierarchies. The implementer should verify this works with `osascript` and adjust the specifier chain as needed.

- [ ] **Step 3: Create ScriptableTransaction**

```swift
// Automation/AppleScript/ScriptableTransaction.swift
#if os(macOS)
  import Cocoa
  import Foundation

  class ScriptableTransaction: NSObject {
    let transaction: Transaction
    let session: ProfileSession

    init(transaction: Transaction, session: ProfileSession) {
      self.transaction = transaction
      self.session = session
      super.init()
    }

    @objc var uniqueID: String { transaction.id.uuidString }
    @objc var date: Date { transaction.date }
    @objc var payee: String { transaction.payee ?? "" }
    @objc var notes: String { transaction.notes ?? "" }
    @objc var transactionType: String {
      transaction.legs.first?.type.rawValue ?? "expense"
    }
    @objc var amount: Double {
      transaction.legs.reduce(0.0) { sum, leg in
        sum + leg.amount.doubleValue
      }
    }
    @objc var isScheduled: Bool { transaction.isScheduled }

    @objc var scriptableLegs: [ScriptableLeg] {
      transaction.legs.map { ScriptableLeg(leg: $0, session: session) }
    }
  }

  class ScriptableLeg: NSObject {
    let leg: TransactionLeg
    let session: ProfileSession

    init(leg: TransactionLeg, session: ProfileSession) {
      self.leg = leg
      self.session = session
      super.init()
    }

    @objc var accountName: String {
      guard let accountId = leg.accountId else { return "" }
      return session.accountStore.accounts.by(id: accountId)?.name ?? ""
    }
    @objc var amount: Double { leg.amount.doubleValue }
    @objc var categoryName: String {
      guard let categoryId = leg.categoryId else { return "" }
      return session.categoryStore.categories.by(id: categoryId)?.name ?? ""
    }
    @objc var legType: String { leg.type.rawValue }
  }
#endif
```

- [ ] **Step 4: Create ScriptableEarmark and ScriptableCategory**

```swift
// Automation/AppleScript/ScriptableEarmark.swift
#if os(macOS)
  import Cocoa
  import Foundation

  class ScriptableEarmark: NSObject {
    let earmark: Earmark

    init(earmark: Earmark) {
      self.earmark = earmark
      super.init()
    }

    @objc var uniqueID: String { earmark.id.uuidString }
    @objc var name: String { earmark.name }
    @objc var balance: Double { earmark.balance.doubleValue }
    @objc var targetAmount: Double { earmark.savingsGoal?.doubleValue ?? 0 }
  }
#endif
```

```swift
// Automation/AppleScript/ScriptableCategory.swift
#if os(macOS)
  import Cocoa
  import Foundation

  class ScriptableCategory: NSObject {
    let category: Category
    let categories: Categories

    init(category: Category, categories: Categories) {
      self.category = category
      self.categories = categories
      super.init()
    }

    @objc var uniqueID: String { category.id.uuidString }
    @objc var name: String { category.name }
    @objc var parentName: String {
      guard let parentId = category.parentId else { return "" }
      return categories.by(id: parentId)?.name ?? ""
    }
  }
#endif
```

- [ ] **Step 5: Build to verify**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-output.txt`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Automation/AppleScript/ScriptableProfile.swift Automation/AppleScript/ScriptableAccount.swift Automation/AppleScript/ScriptableTransaction.swift Automation/AppleScript/ScriptableEarmark.swift Automation/AppleScript/ScriptableCategory.swift
git commit -m "feat(automation): add scriptable NSObject wrappers for AppleScript"
```

---

## Task 11: AppleScript Scripting Bridge

**Files:**
- Create: `Automation/AppleScript/ScriptingBridge.swift`
- Create: `Automation/AppleScript/Commands/CreateAccountCommand.swift`
- Create: `Automation/AppleScript/Commands/CreateTransactionCommand.swift`
- Create: `Automation/AppleScript/Commands/CreateEarmarkCommand.swift`
- Create: `Automation/AppleScript/Commands/CreateCategoryCommand.swift`
- Create: `Automation/AppleScript/Commands/DeleteCommand.swift`
- Create: `Automation/AppleScript/Commands/RefreshCommand.swift`
- Create: `Automation/AppleScript/Commands/NavigateCommand.swift`
- Create: `Automation/AppleScript/Commands/NetWorthCommand.swift`
- Modify: `App/MoolahApp.swift`

- [ ] **Step 1: Create ScriptingBridge (application delegate for scripting)**

```swift
// Automation/AppleScript/ScriptingBridge.swift
#if os(macOS)
  import Cocoa
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "ScriptingBridge")

  /// Bridges the NSApplication scripting model to AutomationService.
  /// Registered as the application's scripting delegate.
  @MainActor
  final class ScriptingBridge: NSObject {
    let automationService: AutomationService

    init(automationService: AutomationService) {
      self.automationService = automationService
      super.init()
    }

    /// The `profiles` element of the `application` in the SDEF.
    @objc var scriptableProfiles: [ScriptableProfile] {
      automationService.sessionManager.openProfiles.map {
        ScriptableProfile(session: $0, automationService: automationService)
      }
    }
  }
#endif
```

- [ ] **Step 2: Create command handlers**

Each command subclass inherits from `NSScriptCommand` and overrides `performDefaultImplementation()`. Example for `CreateTransactionCommand`:

```swift
// Automation/AppleScript/Commands/CreateTransactionCommand.swift
#if os(macOS)
  import Cocoa
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "CreateTransactionCommand")

  final class CreateTransactionCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let bridge = NSApp.delegate as? ScriptingBridge ?? findScriptingBridge() else {
        scriptErrorNumber = -1
        scriptErrorString = "Scripting bridge not available"
        return nil
      }

      let payee = evaluatedArguments?["payee"] as? String ?? ""
      let amount = evaluatedArguments?["amount"] as? Double ?? 0
      let accountName = evaluatedArguments?["accountName"] as? String ?? ""
      let categoryName = evaluatedArguments?["categoryName"] as? String
      let date = evaluatedArguments?["date"] as? Date ?? Date()
      let notes = evaluatedArguments?["notes"] as? String

      // Resolve the profile from the direct parameter (object specifier)
      guard let profileName = resolveProfileName() else {
        scriptErrorNumber = -1
        scriptErrorString = "Could not resolve profile"
        return nil
      }

      var result: ScriptableTransaction?
      let semaphore = DispatchSemaphore(value: 0)

      Task { @MainActor in
        do {
          let service = bridge.automationService
          let transaction = try await service.createTransaction(
            profileIdentifier: profileName,
            payee: payee,
            date: date,
            legs: [AutomationService.LegSpec(
              accountName: accountName,
              amount: Decimal(amount),
              categoryName: categoryName,
              earmarkName: nil
            )],
            notes: notes
          )
          let session = try service.resolveSession(for: profileName)
          result = ScriptableTransaction(transaction: transaction, session: session)
        } catch {
          logger.error("CreateTransaction failed: \(error.localizedDescription, privacy: .public)")
        }
        semaphore.signal()
      }
      semaphore.wait()
      return result
    }

    private func resolveProfileName() -> String? {
      // Extract profile name from the direct parameter object specifier
      guard let specifier = directParameter as? NSScriptObjectSpecifier else {
        return directParameter as? String
      }
      if let nameSpecifier = specifier as? NSNameSpecifier {
        return nameSpecifier.name
      }
      return nil
    }

    private func findScriptingBridge() -> ScriptingBridge? {
      // Access the scripting bridge from the app's stored reference
      nil // Will be wired up during integration
    }
  }
#endif
```

Create similar command classes for `CreateAccountCommand`, `CreateEarmarkCommand`, `CreateCategoryCommand`, `DeleteCommand`, `RefreshCommand`, `NavigateCommand`, and `NetWorthCommand`. Each follows the same pattern:
1. Extract arguments from `evaluatedArguments`
2. Resolve the profile from the direct parameter
3. Call the appropriate `AutomationService` method in a `Task`
4. Return the result as a scriptable object

- [ ] **Step 3: Register the scripting bridge in MoolahApp**

In `App/MoolahApp.swift`, create and store the `ScriptingBridge` and register it. On macOS, add the scripting bridge as a property and wire it up during initialization.

The exact mechanism depends on whether the app uses `NSApplicationDelegate` or pure SwiftUI lifecycle. Since this is a SwiftUI app, the scripting bridge needs to be registered via `NSApplication.shared`. The implementer should verify the correct integration point — this may require adding a custom `NSApplicationDelegate` adapter or using `NSApplication.shared.scriptingProperties`.

- [ ] **Step 4: Build and test with osascript**

Run: `just build-mac`
Then test: `osascript -e 'tell application "Moolah" to get name of every profile'`

- [ ] **Step 5: Check for warnings**

Run: `mcp__xcode__XcodeListNavigatorIssues` with severity "warning". Fix any warnings.

- [ ] **Step 6: Commit**

```bash
git add Automation/AppleScript/
git commit -m "feat(automation): add AppleScript scripting bridge and command handlers"
```

---

## Task 12: App Intents — Entity Definitions

**Files:**
- Create: `Automation/Intents/Entities/ProfileEntity.swift`
- Create: `Automation/Intents/Entities/AccountEntity.swift`
- Create: `Automation/Intents/Entities/EarmarkEntity.swift`
- Create: `Automation/Intents/Entities/CategoryEntity.swift`

- [ ] **Step 1: Create ProfileEntity**

```swift
// Automation/Intents/Entities/ProfileEntity.swift
import AppIntents
import Foundation

struct ProfileEntity: AppEntity {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Profile")
  static var defaultQuery = ProfileQuery()

  var id: UUID
  var name: String
  var currency: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)", subtitle: "\(currency)")
  }

  init(from profile: Profile) {
    self.id = profile.id
    self.name = profile.label
    self.currency = profile.currencyCode
  }
}

struct ProfileQuery: EntityQuery {
  @MainActor
  func entities(for identifiers: [UUID]) async throws -> [ProfileEntity] {
    guard let service = AutomationServiceLocator.shared.service else { return [] }
    return service.listOpenProfiles()
      .filter { identifiers.contains($0.id) }
      .map { ProfileEntity(from: $0) }
  }

  @MainActor
  func suggestedEntities() async throws -> [ProfileEntity] {
    guard let service = AutomationServiceLocator.shared.service else { return [] }
    return service.listOpenProfiles().map { ProfileEntity(from: $0) }
  }
}

/// Service locator for App Intents to access AutomationService.
/// App Intents are instantiated by the system and cannot use dependency injection.
@MainActor
final class AutomationServiceLocator {
  static let shared = AutomationServiceLocator()
  var service: AutomationService?
  private init() {}
}
```

- [ ] **Step 2: Create AccountEntity**

```swift
// Automation/Intents/Entities/AccountEntity.swift
import AppIntents
import Foundation

struct AccountEntity: AppEntity {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Account")
  static var defaultQuery = AccountQuery()

  var id: UUID
  var name: String
  var accountType: String
  var balance: Double

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)", subtitle: "\(accountType)")
  }

  init(from account: Account) {
    self.id = account.id
    self.name = account.name
    self.accountType = account.type.rawValue
    self.balance = account.balance.doubleValue
  }
}

struct AccountQuery: EntityQuery {
  @IntentParameter(title: "Profile")
  var profile: ProfileEntity?

  @MainActor
  func entities(for identifiers: [UUID]) async throws -> [AccountEntity] {
    guard let service = AutomationServiceLocator.shared.service,
      let profileName = profile?.name
    else { return [] }
    return try service.listAccounts(profileIdentifier: profileName)
      .filter { identifiers.contains($0.id) }
      .map { AccountEntity(from: $0) }
  }

  @MainActor
  func suggestedEntities() async throws -> [AccountEntity] {
    guard let service = AutomationServiceLocator.shared.service,
      let profileName = profile?.name
    else { return [] }
    return try service.listAccounts(profileIdentifier: profileName)
      .map { AccountEntity(from: $0) }
  }
}
```

- [ ] **Step 3: Create EarmarkEntity and CategoryEntity**

Follow the same pattern as AccountEntity, using `EarmarkQuery` and `CategoryQuery` with a `profile` parameter.

```swift
// Automation/Intents/Entities/EarmarkEntity.swift
import AppIntents
import Foundation

struct EarmarkEntity: AppEntity {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Earmark")
  static var defaultQuery = EarmarkQuery()

  var id: UUID
  var name: String
  var balance: Double

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)")
  }

  init(from earmark: Earmark) {
    self.id = earmark.id
    self.name = earmark.name
    self.balance = earmark.balance.doubleValue
  }
}

struct EarmarkQuery: EntityQuery {
  @IntentParameter(title: "Profile")
  var profile: ProfileEntity?

  @MainActor
  func entities(for identifiers: [UUID]) async throws -> [EarmarkEntity] {
    guard let service = AutomationServiceLocator.shared.service,
      let profileName = profile?.name
    else { return [] }
    return try service.listEarmarks(profileIdentifier: profileName)
      .filter { identifiers.contains($0.id) }
      .map { EarmarkEntity(from: $0) }
  }

  @MainActor
  func suggestedEntities() async throws -> [EarmarkEntity] {
    guard let service = AutomationServiceLocator.shared.service,
      let profileName = profile?.name
    else { return [] }
    return try service.listEarmarks(profileIdentifier: profileName)
      .map { EarmarkEntity(from: $0) }
  }
}
```

```swift
// Automation/Intents/Entities/CategoryEntity.swift
import AppIntents
import Foundation

struct CategoryEntity: AppEntity {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Category")
  static var defaultQuery = CategoryQuery()

  var id: UUID
  var name: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)")
  }

  init(from category: Category) {
    self.id = category.id
    self.name = category.name
  }
}

struct CategoryQuery: EntityQuery {
  @IntentParameter(title: "Profile")
  var profile: ProfileEntity?

  @MainActor
  func entities(for identifiers: [UUID]) async throws -> [CategoryEntity] {
    guard let service = AutomationServiceLocator.shared.service,
      let profileName = profile?.name
    else { return [] }
    return try service.listCategories(profileIdentifier: profileName)
      .filter { identifiers.contains($0.id) }
      .map { CategoryEntity(from: $0) }
  }

  @MainActor
  func suggestedEntities() async throws -> [CategoryEntity] {
    guard let service = AutomationServiceLocator.shared.service,
      let profileName = profile?.name
    else { return [] }
    return try service.listCategories(profileIdentifier: profileName)
      .map { CategoryEntity(from: $0) }
  }
}
```

- [ ] **Step 4: Build to verify**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-output.txt`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Automation/Intents/Entities/
git commit -m "feat(automation): add App Intents entity definitions and queries"
```

---

## Task 13: App Intents — Intent Implementations

**Files:**
- Create: All intent files in `Automation/Intents/`
- Create: `Automation/Intents/MoolahShortcuts.swift`

- [ ] **Step 1: Create GetNetWorthIntent**

```swift
// Automation/Intents/GetNetWorthIntent.swift
import AppIntents
import Foundation

struct GetNetWorthIntent: AppIntent {
  static var title: LocalizedStringResource = "Get Net Worth"
  static var description = IntentDescription("Get the total net worth for a profile.")

  @Parameter(title: "Profile")
  var profile: ProfileEntity

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard let service = AutomationServiceLocator.shared.service else {
      throw AutomationError.operationFailed("App not ready")
    }
    let netWorth = try service.getNetWorth(profileIdentifier: profile.name)
    return .result(value: netWorth.formatted)
  }
}
```

- [ ] **Step 2: Create remaining intents**

Create each intent following the same pattern. Each takes a `ProfileEntity` parameter and calls the corresponding `AutomationService` method:

- `GetAccountBalanceIntent` — takes profile + account, returns formatted balance
- `ListAccountsIntent` — takes profile, returns formatted list of account names and balances
- `CreateTransactionIntent` — takes profile + payee + amount + account + optional category + optional date
- `GetRecentTransactionsIntent` — takes profile + optional account + count
- `CreateEarmarkIntent` — takes profile + name + optional target amount
- `GetEarmarkBalanceIntent` — takes profile + earmark, returns formatted balance
- `AddInvestmentValueIntent` — takes profile + account + value
- `GetExpenseBreakdownIntent` — takes profile + period (this month / last month / custom)
- `GetMonthlySummaryIntent` — takes profile + month/year
- `OpenAccountIntent` — takes profile + account, opens URL scheme
- `RefreshDataIntent` — takes optional profile, refreshes all stores

Each follows the exact same structure as `GetNetWorthIntent` above — resolve service from `AutomationServiceLocator`, call the service method, format and return the result.

- [ ] **Step 3: Create MoolahShortcuts**

```swift
// Automation/Intents/MoolahShortcuts.swift
import AppIntents

struct MoolahShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: GetNetWorthIntent(),
      phrases: [
        "What's my net worth in \(.applicationName)?",
      ],
      shortTitle: "Net Worth",
      systemImageName: "chart.line.uptrend.xyaxis"
    )

    AppShortcut(
      intent: ListAccountsIntent(),
      phrases: [
        "Show my balances in \(.applicationName)?",
      ],
      shortTitle: "Account Balances",
      systemImageName: "list.bullet"
    )

    AppShortcut(
      intent: CreateTransactionIntent(),
      phrases: [
        "Add a transaction in \(.applicationName)",
      ],
      shortTitle: "Add Transaction",
      systemImageName: "plus.circle"
    )

    AppShortcut(
      intent: GetAccountBalanceIntent(),
      phrases: [
        "What's my \(\.$account) balance in \(.applicationName)?",
      ],
      shortTitle: "Account Balance",
      systemImageName: "dollarsign.circle"
    )

    AppShortcut(
      intent: GetEarmarkBalanceIntent(),
      phrases: [
        "How much is in \(\.$earmark) in \(.applicationName)?",
      ],
      shortTitle: "Earmark Balance",
      systemImageName: "bookmark"
    )

    AppShortcut(
      intent: GetExpenseBreakdownIntent(),
      phrases: [
        "What did I spend this month in \(.applicationName)?",
      ],
      shortTitle: "Monthly Spending",
      systemImageName: "chart.pie"
    )

    AppShortcut(
      intent: GetRecentTransactionsIntent(),
      phrases: [
        "Show my recent transactions in \(.applicationName)",
      ],
      shortTitle: "Recent Transactions",
      systemImageName: "clock"
    )
  }
}
```

- [ ] **Step 4: Wire AutomationServiceLocator in MoolahApp**

In `App/MoolahApp.swift` init, after creating the `SessionManager`, add:

```swift
let automationService = AutomationService(sessionManager: sessionManager)
AutomationServiceLocator.shared.service = automationService
```

- [ ] **Step 5: Build to verify**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-output.txt`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Check for warnings**

Run: `mcp__xcode__XcodeListNavigatorIssues` with severity "warning". Fix any warnings.

- [ ] **Step 7: Commit**

```bash
git add Automation/Intents/ App/MoolahApp.swift
git commit -m "feat(automation): add App Intents with Siri phrases and Shortcuts provider"
```

---

## Task 14: AI Automation Skill

**Files:**
- Create: `.claude/skills/automate-app/SKILL.md`

- [ ] **Step 1: Write the skill**

```markdown
---
name: automate-app
description: Use when you need to interact with the running Moolah app — testing UI changes, verifying data, creating test fixtures, or navigating to specific views via AppleScript or URL scheme
---

# Automating the Moolah App

Drive the running Moolah macOS app via AppleScript (`osascript`) for data operations and `moolah://` URLs for navigation.

## CRITICAL: Profile Safety

**Before taking ANY automation action, you MUST confirm with the user which profile to use.** Never assume a profile. Never default to the first profile. Ask explicitly, every time, even if there's only one profile open. This is real financial data — testing operations must not be performed on important profiles.

**Recommended first step for testing:** Suggest creating a dedicated test profile:

```bash
osascript -e 'tell application "Moolah" to create profile name "AI Test" currency "AUD"'
```

## AppleScript Reference

All commands use `osascript -e '...'` from the terminal.

### Profile Operations

```bash
# List all open profiles
osascript -e 'tell application "Moolah" to get name of every profile'

# Get profile currency
osascript -e 'tell application "Moolah" to get currency of profile "Test"'
```

### Account Operations

```bash
# List accounts
osascript -e 'tell application "Moolah" to get name of every account of profile "Test"'

# Get account balance
osascript -e 'tell application "Moolah" to get balance of account "Savings" of profile "Test"'

# Get all balances
osascript -e 'tell application "Moolah" to get {name, balance} of every account of profile "Test"'

# Get net worth
osascript -e 'tell application "Moolah" to net worth of profile "Test"'

# Create account
osascript -e 'tell application "Moolah" to tell profile "Test" to create account name "New Account" type "bank"'

# Delete account (use the account specifier)
osascript -e 'tell application "Moolah" to delete account "New Account" of profile "Test"'
```

### Transaction Operations

```bash
# Create a simple expense
osascript -e 'tell application "Moolah" to tell profile "Test" to create transaction with payee "Woolworths" amount -42.50 account "Everyday" category "Groceries"'

# Create with date and notes
osascript -e 'tell application "Moolah" to tell profile "Test" to create transaction with payee "Rent" amount -2000.00 account "Everyday" date (date "2026-04-01") notes "April rent"'

# List recent transactions (loads first page)
osascript -e 'tell application "Moolah" to get {payee, amount, date} of every transaction of profile "Test"'

# Delete a transaction by ID
osascript -e 'tell application "Moolah" to delete transaction id "uuid-here" of profile "Test"'
```

### Earmark Operations

```bash
# List earmarks
osascript -e 'tell application "Moolah" to get {name, balance} of every earmark of profile "Test"'

# Create earmark
osascript -e 'tell application "Moolah" to tell profile "Test" to create earmark name "Holiday" target 5000.00'

# Get earmark balance
osascript -e 'tell application "Moolah" to get balance of earmark "Holiday" of profile "Test"'
```

### Category Operations

```bash
# List categories
osascript -e 'tell application "Moolah" to get name of every category of profile "Test"'

# Create category
osascript -e 'tell application "Moolah" to tell profile "Test" to create category name "Groceries"'

# Create subcategory
osascript -e 'tell application "Moolah" to tell profile "Test" to create category name "Fruit" parent "Groceries"'
```

### Other Commands

```bash
# Refresh data from backend
osascript -e 'tell application "Moolah" to refresh profile "Test"'

# Navigate to a view
osascript -e 'tell application "Moolah" to navigate to account "Savings" of profile "Test"'
```

## URL Scheme Reference

Use `open` command to trigger URL navigation:

```bash
# Open a profile window
open "moolah://Test"

# Navigate to a specific account
open "moolah://Test/account/ACCOUNT-UUID-HERE"

# Navigate to analysis with custom periods
open "moolah://Test/analysis?history=12&forecast=3"

# Navigate to reports with date range
open "moolah://Test/reports?from=2026-01-01&to=2026-03-31"

# Navigate to categories
open "moolah://Test/categories"

# Navigate to upcoming transactions
open "moolah://Test/upcoming"

# Navigate to earmarks
open "moolah://Test/earmarks"

# URL-encode profile names with spaces
open "moolah://My%20Finances/analysis"
```

**Profile resolution:** The URL first tries matching by profile name (case-insensitive), then by UUID. If the profile isn't open, a new window opens for it.

**Transaction detail:** Opening a transaction navigates to it within the first leg's account context.

## Common Test Workflows

### Verify account balance updates after transaction

```bash
# 1. Check initial balance
osascript -e 'tell application "Moolah" to get balance of account "Everyday" of profile "Test"'

# 2. Create a transaction
osascript -e 'tell application "Moolah" to tell profile "Test" to create transaction with payee "Test Purchase" amount -25.00 account "Everyday"'

# 3. Check balance changed
osascript -e 'tell application "Moolah" to get balance of account "Everyday" of profile "Test"'
```

### Verify UI navigation

```bash
# Navigate to analysis view
open "moolah://Test/analysis?history=6&forecast=3"
# Wait for navigation, then visually verify or check logs

# Navigate to specific account
open "moolah://Test/account/ACCOUNT-UUID"
```

### Create test fixtures

```bash
# Create a full test environment
osascript -e '
tell application "Moolah"
  tell profile "AI Test"
    create account name "Checking" type "bank"
    create account name "Savings" type "bank"
    create account name "Credit Card" type "cc"
    create category name "Food"
    create category name "Transport"
    create earmark name "Emergency Fund" target 10000.00
    create transaction with payee "Salary" amount 5000.00 account "Checking" category "Income" date (current date)
    create transaction with payee "Groceries" amount -150.00 account "Checking" category "Food"
    create transaction with payee "Gas" amount -60.00 account "Credit Card" category "Transport"
  end tell
end tell
'
```

## Error Handling

AppleScript errors appear as exceptions. Capture them with:

```bash
osascript -e '
try
  tell application "Moolah" to get balance of account "Nonexistent" of profile "Test"
on error errMsg
  return "ERROR: " & errMsg
end try
'
```

Common errors:
- "Profile not found" — profile isn't open or name is misspelled
- "Account not found" — account name doesn't match (check case)
- "Operation failed" — backend error (check app logs)

## Tips

- **Use AppleScript for data operations** (CRUD, balance checks, analysis data)
- **Use URL scheme for navigation** (opening views, navigating to specific entities)
- **Always verify state after mutations** — read back the value you just changed
- **Check the running app** — automation requires the app to be running. Use `just run-mac` to launch it first.
- **Use `run-mac-app-with-logs` skill** to capture app logs while running automation for debugging
```

- [ ] **Step 2: Verify skill appears in skill list**

The skill should appear when listing available skills. Verify the file is properly structured with the YAML frontmatter.

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/automate-app/SKILL.md
git commit -m "feat(automation): add AI automation skill for driving the app"
```

---

## Task 15: Integration Testing & Verification

**Files:** None new — this is a verification task.

- [ ] **Step 1: Run full test suite**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt`
Expected: All tests pass.

- [ ] **Step 2: Build for both platforms**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-mac.txt`
Run: `just build-ios 2>&1 | tee .agent-tmp/build-ios.txt`
Expected: Both BUILD SUCCEEDED.

- [ ] **Step 3: Check for all warnings**

Run: `mcp__xcode__XcodeListNavigatorIssues` with severity "warning". Fix all warnings in user code.

- [ ] **Step 4: Manual AppleScript verification (macOS)**

Launch the app with `just run-mac`, then test:

```bash
osascript -e 'tell application "Moolah" to get name of every profile'
```

Verify it returns the list of open profiles.

- [ ] **Step 5: Manual URL scheme verification**

```bash
open "moolah://ProfileName/analysis"
```

Verify the app navigates to the analysis view.

- [ ] **Step 6: Clean up temp files**

```bash
rm -f .agent-tmp/test-output.txt .agent-tmp/build-mac.txt .agent-tmp/build-ios.txt .agent-tmp/build-output.txt
```

- [ ] **Step 7: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "fix(automation): address integration test findings"
```
