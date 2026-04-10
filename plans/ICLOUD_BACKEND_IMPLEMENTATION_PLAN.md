# iCloud Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a CloudKit-backed backend as an additional profile option alongside the existing remote backend, with full feature parity.

**Architecture:** New `CloudKitBackend` implements `BackendProvider` using SwiftData `@Model` records scoped by `profileId`. `ProfileStore` becomes hybrid (UserDefaults for remote, SwiftData for iCloud). `ProfileSession` branches on `BackendType` to create the appropriate backend.

**Tech Stack:** SwiftData, CloudKit, Swift Testing, SwiftUI

---

## File Structure

### New Files

```
Backends/CloudKit/
├── CloudKitBackend.swift                    # BackendProvider impl (modelContext + profileId + currency)
├── CloudKitAuthProvider.swift               # Implicit iCloud auth
├── Models/
│   ├── ProfileRecord.swift                  # @Model — profile metadata synced via CloudKit
│   ├── AccountRecord.swift                  # @Model — includes profileId, currencyCode
│   ├── TransactionRecord.swift              # @Model — includes profileId, currencyCode
│   ├── CategoryRecord.swift                 # @Model — includes profileId
│   ├── EarmarkRecord.swift                  # @Model — includes profileId, currencyCode
│   ├── EarmarkBudgetItemRecord.swift        # @Model — includes profileId, currencyCode
│   └── InvestmentValueRecord.swift          # @Model — includes profileId, currencyCode
├── Repositories/
│   ├── CloudKitCategoryRepository.swift     # All queries scoped by profileId
│   ├── CloudKitAccountRepository.swift      # Balance computed from transactions
│   ├── CloudKitTransactionRepository.swift  # Filtering, pagination, priorBalance
│   ├── CloudKitEarmarkRepository.swift      # Balance/saved/spent computed from transactions
│   ├── CloudKitAnalysisRepository.swift     # Daily balances, breakdowns, forecasting
│   └── CloudKitInvestmentRepository.swift   # Investment values per account
└── ProfileDataDeleter.swift                 # Batch-deletes all records for a profileId
```

### Modified Files

| File | Change |
|------|--------|
| `Domain/Models/Currency.swift` | Replace hardcoded constants with system-derived `from(code:)` |
| `Domain/Models/Profile.swift` | Add `BackendType.cloudKit`; use `Currency.from(code:)` in `currency` property |
| `App/MoolahApp.swift` | Create `ModelContainer` at launch; pass to `ProfileStore` and sessions |
| `App/ProfileSession.swift` | Accept `ModelContainer`; branch on `backendType` |
| `App/SessionManager.swift` | Hold `ModelContainer`; pass to `ProfileSession` |
| `Features/Profiles/ProfileStore.swift` | Hybrid UserDefaults + SwiftData; observe remote changes |
| `Features/Profiles/Views/ProfileFormView.swift` | Add "iCloud" option to type picker |
| `project.yml` | Add CloudKit entitlement configuration |
| `MoolahTests/Support/TestCurrency.swift` | Update to use `Currency.from(code:)` |

### Test Files

```
MoolahTests/
├── Domain/
│   ├── CategoryRepositoryContractTests.swift     # Add CloudKit repository to arguments
│   ├── AccountRepositoryContractTests.swift      # Add CloudKit repository to arguments
│   ├── TransactionRepositoryContractTests.swift  # Add CloudKit repository to arguments
│   ├── EarmarkRepositoryContractTests.swift      # Add CloudKit repository to arguments
│   ├── AnalysisRepositoryContractTests.swift     # Add CloudKit repository to arguments
│   ├── InvestmentRepositoryContractTests.swift   # Add CloudKit repository to arguments
│   └── AuthContractTests.swift                   # Add CloudKit auth to arguments
├── CloudKit/
│   ├── ProfileRecordTests.swift                  # ProfileRecord CRUD and mapping
│   ├── MultiProfileIsolationTests.swift          # Two backends share container, data isolated
│   └── ProfileDataDeleterTests.swift             # Batch delete by profileId
└── Profiles/
    └── ProfileStoreTests.swift                   # Hybrid store with iCloud profiles (may exist already)
```

---

### Task 1: System-Derived Currency

**Files:**
- Modify: `Domain/Models/Currency.swift`
- Modify: `Domain/Models/Profile.swift:47-53`
- Modify: `MoolahTests/Support/TestCurrency.swift`

- [ ] **Step 1: Update Currency to derive from system**

Replace the full content of `Domain/Models/Currency.swift`:

```swift
import Foundation

struct Currency: Codable, Sendable, Hashable {
  let code: String
  let symbol: String
  let decimals: Int

  /// Construct Currency from an ISO currency code.
  /// Symbol and decimal places are derived from the system locale database.
  static func from(code: String) -> Currency {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = code
    return Currency(
      code: code,
      symbol: formatter.currencySymbol ?? code,
      decimals: formatter.maximumFractionDigits
    )
  }

  // Convenience constants — delegate to from(code:) so values are locale-sensitive
  static let AUD = Currency.from(code: "AUD")
  static let USD = Currency.from(code: "USD")
}
```

- [ ] **Step 2: Update Profile.currency to use Currency.from(code:)**

In `Domain/Models/Profile.swift`, replace the `currency` computed property (lines 47-53):

```swift
  var currency: Currency {
    Currency.from(code: currencyCode)
  }
```

- [ ] **Step 3: Build and run tests**

Run: `just test`
Expected: All existing tests pass. Currency values now use system-derived symbols.

- [ ] **Step 4: Commit**

```bash
git add Domain/Models/Currency.swift Domain/Models/Profile.swift
git commit -m "Derive currency symbol and decimals from system locale

Replace hardcoded Currency constants with system-derived values via
NumberFormatter. Symbols and decimal places are now locale-sensitive
and correct for all ISO currency codes."
```

---

### Task 2: Add BackendType.cloudKit

**Files:**
- Modify: `Domain/Models/Profile.swift:3-7`

- [ ] **Step 1: Add cloudKit case to BackendType**

In `Domain/Models/Profile.swift`, replace the `BackendType` enum (lines 3-7):

```swift
enum BackendType: String, Codable, Sendable {
  case remote
  case moolah
  case cloudKit
}
```

- [ ] **Step 2: Build to verify no exhaustive switch issues**

Run: `just build-mac`
Expected: Build succeeds. If any `switch` statements on `BackendType` are non-exhaustive, fix them by adding `case .cloudKit:` handling. Key places to check:
- `ProfileFormView.swift` — the `canAdd` computed property and `save()` method
- Any other views that switch on `backendType`

The `ProfileFormView` switches will need a `.cloudKit` case in `canAdd` and `save()`. For now, add minimal stubs that will be replaced in Task 18:

In `ProfileFormView.swift`, add to the `canAdd` switch:
```swift
    case .cloudKit:
      return true
```

In `ProfileFormView.swift`, add to the `save()` switch:
```swift
    case .cloudKit:
      profile = Profile(label: "iCloud", backendType: .cloudKit)
```

- [ ] **Step 3: Commit**

```bash
git add Domain/Models/Profile.swift Features/Profiles/Views/ProfileFormView.swift
git commit -m "Add BackendType.cloudKit case"
```

---

### Task 3: SwiftData Models — ProfileRecord

**Files:**
- Create: `Backends/CloudKit/Models/ProfileRecord.swift`

- [ ] **Step 1: Create the ProfileRecord model**

```swift
import Foundation
import SwiftData

@Model
final class ProfileRecord {
  #Unique<ProfileRecord>([\.id])

  @Attribute(.preserveValueOnDeletion)
  var id: UUID

  var label: String
  var currencyCode: String
  var financialYearStartMonth: Int
  var createdAt: Date

  init(
    id: UUID = UUID(),
    label: String,
    currencyCode: String,
    financialYearStartMonth: Int = 7,
    createdAt: Date = .now
  ) {
    self.id = id
    self.label = label
    self.currencyCode = currencyCode
    self.financialYearStartMonth = financialYearStartMonth
    self.createdAt = createdAt
  }

  /// Convert to domain Profile model.
  func toProfile() -> Profile {
    Profile(
      id: id,
      label: label,
      backendType: .cloudKit,
      currencyCode: currencyCode,
      financialYearStartMonth: financialYearStartMonth,
      createdAt: createdAt
    )
  }

  /// Create from domain Profile model.
  static func from(profile: Profile) -> ProfileRecord {
    ProfileRecord(
      id: profile.id,
      label: profile.label,
      currencyCode: profile.currencyCode,
      financialYearStartMonth: profile.financialYearStartMonth,
      createdAt: profile.createdAt
    )
  }
}
```

- [ ] **Step 2: Build**

Run: `just build-mac`
Expected: Compiles with no errors.

- [ ] **Step 3: Commit**

```bash
git add Backends/CloudKit/Models/ProfileRecord.swift
git commit -m "Add ProfileRecord SwiftData model"
```

---

### Task 4: SwiftData Models — CategoryRecord

**Files:**
- Create: `Backends/CloudKit/Models/CategoryRecord.swift`

- [ ] **Step 1: Create the CategoryRecord model**

```swift
import Foundation
import SwiftData

@Model
final class CategoryRecord {
  #Unique<CategoryRecord>([\.id])

  var id: UUID
  var profileId: UUID
  var name: String
  var parentId: UUID?

  init(id: UUID = UUID(), profileId: UUID, name: String, parentId: UUID? = nil) {
    self.id = id
    self.profileId = profileId
    self.name = name
    self.parentId = parentId
  }

  func toDomain() -> Category {
    Category(id: id, name: name, parentId: parentId)
  }

  static func from(_ category: Category, profileId: UUID) -> CategoryRecord {
    CategoryRecord(
      id: category.id,
      profileId: profileId,
      name: category.name,
      parentId: category.parentId
    )
  }
}
```

- [ ] **Step 2: Build**

Run: `just build-mac`

- [ ] **Step 3: Commit**

```bash
git add Backends/CloudKit/Models/CategoryRecord.swift
git commit -m "Add CategoryRecord SwiftData model"
```

---

### Task 5: SwiftData Models — AccountRecord

**Files:**
- Create: `Backends/CloudKit/Models/AccountRecord.swift`

- [ ] **Step 1: Create the AccountRecord model**

```swift
import Foundation
import SwiftData

@Model
final class AccountRecord {
  #Unique<AccountRecord>([\.id])

  var id: UUID
  var profileId: UUID
  var name: String
  var type: String  // Raw value of AccountType
  var position: Int
  var isHidden: Bool
  var currencyCode: String

  init(
    id: UUID = UUID(),
    profileId: UUID,
    name: String,
    type: String,
    position: Int = 0,
    isHidden: Bool = false,
    currencyCode: String
  ) {
    self.id = id
    self.profileId = profileId
    self.name = name
    self.type = type
    self.position = position
    self.isHidden = isHidden
    self.currencyCode = currencyCode
  }

  func toDomain(balance: MonetaryAmount, investmentValue: MonetaryAmount?) -> Account {
    Account(
      id: id,
      name: name,
      type: AccountType(rawValue: type) ?? .bank,
      balance: balance,
      investmentValue: investmentValue,
      position: position,
      isHidden: isHidden
    )
  }

  static func from(_ account: Account, profileId: UUID, currencyCode: String) -> AccountRecord {
    AccountRecord(
      id: account.id,
      profileId: profileId,
      name: account.name,
      type: account.type.rawValue,
      position: account.position,
      isHidden: account.isHidden,
      currencyCode: currencyCode
    )
  }
}
```

- [ ] **Step 2: Build**

Run: `just build-mac`

- [ ] **Step 3: Commit**

```bash
git add Backends/CloudKit/Models/AccountRecord.swift
git commit -m "Add AccountRecord SwiftData model"
```

---

### Task 6: SwiftData Models — TransactionRecord

**Files:**
- Create: `Backends/CloudKit/Models/TransactionRecord.swift`

- [ ] **Step 1: Create the TransactionRecord model**

```swift
import Foundation
import SwiftData

@Model
final class TransactionRecord {
  #Unique<TransactionRecord>([\.id])

  var id: UUID
  var profileId: UUID
  var type: String  // Raw value of TransactionType
  var date: Date
  var accountId: UUID?
  var toAccountId: UUID?
  var amount: Int  // cents
  var currencyCode: String
  var payee: String?
  var notes: String?
  var categoryId: UUID?
  var earmarkId: UUID?
  var recurPeriod: String?  // Raw value of RecurPeriod
  var recurEvery: Int?

  init(
    id: UUID = UUID(),
    profileId: UUID,
    type: String,
    date: Date,
    accountId: UUID? = nil,
    toAccountId: UUID? = nil,
    amount: Int,
    currencyCode: String,
    payee: String? = nil,
    notes: String? = nil,
    categoryId: UUID? = nil,
    earmarkId: UUID? = nil,
    recurPeriod: String? = nil,
    recurEvery: Int? = nil
  ) {
    self.id = id
    self.profileId = profileId
    self.type = type
    self.date = date
    self.accountId = accountId
    self.toAccountId = toAccountId
    self.amount = amount
    self.currencyCode = currencyCode
    self.payee = payee
    self.notes = notes
    self.categoryId = categoryId
    self.earmarkId = earmarkId
    self.recurPeriod = recurPeriod
    self.recurEvery = recurEvery
  }

  func toDomain() -> Transaction {
    let currency = Currency.from(code: currencyCode)
    return Transaction(
      id: id,
      type: TransactionType(rawValue: type) ?? .expense,
      date: date,
      accountId: accountId,
      toAccountId: toAccountId,
      amount: MonetaryAmount(cents: amount, currency: currency),
      payee: payee,
      notes: notes,
      categoryId: categoryId,
      earmarkId: earmarkId,
      recurPeriod: recurPeriod.flatMap { RecurPeriod(rawValue: $0) },
      recurEvery: recurEvery
    )
  }

  static func from(_ transaction: Transaction, profileId: UUID) -> TransactionRecord {
    TransactionRecord(
      id: transaction.id,
      profileId: profileId,
      type: transaction.type.rawValue,
      date: transaction.date,
      accountId: transaction.accountId,
      toAccountId: transaction.toAccountId,
      amount: transaction.amount.cents,
      currencyCode: transaction.amount.currency.code,
      payee: transaction.payee,
      notes: transaction.notes,
      categoryId: transaction.categoryId,
      earmarkId: transaction.earmarkId,
      recurPeriod: transaction.recurPeriod?.rawValue,
      recurEvery: transaction.recurEvery
    )
  }
}
```

- [ ] **Step 2: Build**

Run: `just build-mac`

- [ ] **Step 3: Commit**

```bash
git add Backends/CloudKit/Models/TransactionRecord.swift
git commit -m "Add TransactionRecord SwiftData model"
```

---

### Task 7: SwiftData Models — EarmarkRecord and EarmarkBudgetItemRecord

**Files:**
- Create: `Backends/CloudKit/Models/EarmarkRecord.swift`
- Create: `Backends/CloudKit/Models/EarmarkBudgetItemRecord.swift`

- [ ] **Step 1: Create the EarmarkRecord model**

```swift
import Foundation
import SwiftData

@Model
final class EarmarkRecord {
  #Unique<EarmarkRecord>([\.id])

  var id: UUID
  var profileId: UUID
  var name: String
  var position: Int
  var isHidden: Bool
  var savingsTarget: Int?  // cents
  var currencyCode: String
  var savingsStartDate: Date?
  var savingsEndDate: Date?

  init(
    id: UUID = UUID(),
    profileId: UUID,
    name: String,
    position: Int = 0,
    isHidden: Bool = false,
    savingsTarget: Int? = nil,
    currencyCode: String,
    savingsStartDate: Date? = nil,
    savingsEndDate: Date? = nil
  ) {
    self.id = id
    self.profileId = profileId
    self.name = name
    self.position = position
    self.isHidden = isHidden
    self.savingsTarget = savingsTarget
    self.currencyCode = currencyCode
    self.savingsStartDate = savingsStartDate
    self.savingsEndDate = savingsEndDate
  }

  func toDomain(balance: MonetaryAmount, saved: MonetaryAmount, spent: MonetaryAmount) -> Earmark {
    let currency = Currency.from(code: currencyCode)
    return Earmark(
      id: id,
      name: name,
      balance: balance,
      saved: saved,
      spent: spent,
      isHidden: isHidden,
      position: position,
      savingsGoal: savingsTarget.map { MonetaryAmount(cents: $0, currency: currency) },
      savingsStartDate: savingsStartDate,
      savingsEndDate: savingsEndDate
    )
  }

  static func from(_ earmark: Earmark, profileId: UUID, currencyCode: String) -> EarmarkRecord {
    EarmarkRecord(
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
  }
}
```

- [ ] **Step 2: Create the EarmarkBudgetItemRecord model**

```swift
import Foundation
import SwiftData

@Model
final class EarmarkBudgetItemRecord {
  #Unique<EarmarkBudgetItemRecord>([\.id])

  var id: UUID
  var profileId: UUID
  var earmarkId: UUID
  var categoryId: UUID
  var amount: Int  // cents
  var currencyCode: String

  init(
    id: UUID = UUID(),
    profileId: UUID,
    earmarkId: UUID,
    categoryId: UUID,
    amount: Int,
    currencyCode: String
  ) {
    self.id = id
    self.profileId = profileId
    self.earmarkId = earmarkId
    self.categoryId = categoryId
    self.amount = amount
    self.currencyCode = currencyCode
  }

  func toDomain() -> EarmarkBudgetItem {
    let currency = Currency.from(code: currencyCode)
    return EarmarkBudgetItem(
      id: id,
      categoryId: categoryId,
      amount: MonetaryAmount(cents: amount, currency: currency)
    )
  }
}
```

- [ ] **Step 3: Build**

Run: `just build-mac`

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/Models/EarmarkRecord.swift Backends/CloudKit/Models/EarmarkBudgetItemRecord.swift
git commit -m "Add EarmarkRecord and EarmarkBudgetItemRecord SwiftData models"
```

---

### Task 8: SwiftData Models — InvestmentValueRecord

**Files:**
- Create: `Backends/CloudKit/Models/InvestmentValueRecord.swift`

- [ ] **Step 1: Create the InvestmentValueRecord model**

```swift
import Foundation
import SwiftData

@Model
final class InvestmentValueRecord {
  #Unique<InvestmentValueRecord>([\.id])

  var id: UUID
  var profileId: UUID
  var accountId: UUID
  var date: Date
  var value: Int  // cents
  var currencyCode: String

  init(
    id: UUID = UUID(),
    profileId: UUID,
    accountId: UUID,
    date: Date,
    value: Int,
    currencyCode: String
  ) {
    self.id = id
    self.profileId = profileId
    self.accountId = accountId
    self.date = date
    self.value = value
    self.currencyCode = currencyCode
  }

  func toDomain() -> InvestmentValue {
    let currency = Currency.from(code: currencyCode)
    return InvestmentValue(date: date, value: MonetaryAmount(cents: value, currency: currency))
  }
}
```

- [ ] **Step 2: Build**

Run: `just build-mac`

- [ ] **Step 3: Commit**

```bash
git add Backends/CloudKit/Models/InvestmentValueRecord.swift
git commit -m "Add InvestmentValueRecord SwiftData model"
```

---

### Task 9: ModelContainer Helper for Tests

Before writing repositories, we need a test helper that creates in-memory SwiftData containers.

**Files:**
- Create: `MoolahTests/Support/TestModelContainer.swift`

- [ ] **Step 1: Create test helper**

```swift
import Foundation
import SwiftData

@testable import Moolah

/// Creates an in-memory ModelContainer with all CloudKit model types.
/// No CloudKit sync — pure local SwiftData for fast testing.
enum TestModelContainer {
  static func create() throws -> ModelContainer {
    let schema = Schema([
      ProfileRecord.self,
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

- [ ] **Step 2: Build**

Run: `just build-mac`

- [ ] **Step 3: Commit**

```bash
git add MoolahTests/Support/TestModelContainer.swift
git commit -m "Add TestModelContainer helper for in-memory SwiftData tests"
```

---

### Task 10: CloudKitCategoryRepository + Contract Tests

**Files:**
- Create: `Backends/CloudKit/Repositories/CloudKitCategoryRepository.swift`
- Modify: `MoolahTests/Domain/CategoryRepositoryContractTests.swift`

- [ ] **Step 1: Write the CloudKitCategoryRepository**

```swift
import Foundation
import SwiftData

final class CloudKitCategoryRepository: CategoryRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let profileId: UUID

  init(modelContainer: ModelContainer, profileId: UUID) {
    self.modelContainer = modelContainer
    self.profileId = profileId
  }

  @MainActor
  private var context: ModelContext {
    modelContainer.mainContext
  }

  func fetchAll() async throws -> [Category] {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<CategoryRecord>(
      predicate: #Predicate { $0.profileId == profileId },
      sortBy: [SortDescriptor(\.name)]
    )
    let records = try await MainActor.run { try context.fetch(descriptor) }
    return records.map { $0.toDomain() }
  }

  func create(_ category: Category) async throws -> Category {
    let record = CategoryRecord.from(category, profileId: profileId)
    try await MainActor.run {
      context.insert(record)
      try context.save()
    }
    return category
  }

  func update(_ category: Category) async throws -> Category {
    let categoryId = category.id
    let profileId = self.profileId
    let descriptor = FetchDescriptor<CategoryRecord>(
      predicate: #Predicate { $0.id == categoryId && $0.profileId == profileId }
    )
    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }
      record.name = category.name
      record.parentId = category.parentId
      try context.save()
    }
    return category
  }

  func delete(id: UUID, withReplacement replacementId: UUID?) async throws {
    let profileId = self.profileId
    let targetId = id

    // Fetch the category to delete
    let descriptor = FetchDescriptor<CategoryRecord>(
      predicate: #Predicate { $0.id == targetId && $0.profileId == profileId }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }

      // Update children to point to replacement (or nil)
      let childDescriptor = FetchDescriptor<CategoryRecord>(
        predicate: #Predicate { $0.parentId == targetId && $0.profileId == profileId }
      )
      let children = try context.fetch(childDescriptor)
      for child in children {
        child.parentId = replacementId
      }

      context.delete(record)
      try context.save()
    }
  }
}
```

- [ ] **Step 2: Add CloudKit repository to contract tests**

In `MoolahTests/Domain/CategoryRepositoryContractTests.swift`, update each test's `arguments` array to include a CloudKit instance. The challenge is that `CloudKitCategoryRepository` is not an actor like `InMemoryCategoryRepository`, so we need a helper to create one with a test container.

Add a helper at the bottom of the file:

```swift
private func makeCloudKitCategoryRepository(
  initialCategories: [Category] = []
) -> CloudKitCategoryRepository {
  let container = try! TestModelContainer.create()
  let profileId = UUID()
  let repo = CloudKitCategoryRepository(modelContainer: container, profileId: profileId)

  // Seed initial data
  if !initialCategories.isEmpty {
    let context = container.mainContext
    for category in initialCategories {
      context.insert(CategoryRecord.from(category, profileId: profileId))
    }
    try! context.save()
  }

  return repo
}
```

The contract tests currently take `InMemoryCategoryRepository` as the argument type. Since both types conform to `CategoryRepository`, change the parameter type to `any CategoryRepository` and add both implementations to each test's arguments. For example, the first test becomes:

```swift
  @Test(
    "creates category",
    arguments: [
      InMemoryCategoryRepository() as any CategoryRepository,
      makeCloudKitCategoryRepository() as any CategoryRepository,
    ])
  func testCreatesCategory(repository: any CategoryRepository) async throws {
```

Apply this pattern to all tests in the file. For tests that need initial data, add a second argument using `makeCloudKitCategoryRepository(initialCategories:)`.

For the hierarchy tests, add:
```swift
private func makeCloudKitRepositoryWithHierarchy() -> CloudKitCategoryRepository {
  let groceriesId = UUID()
  return makeCloudKitCategoryRepository(initialCategories: [
    Category(id: groceriesId, name: "Groceries"),
    Category(name: "Fruit", parentId: groceriesId),
    Category(name: "Transport"),
  ])
}
```

- [ ] **Step 3: Run contract tests**

Run: `just test`
Expected: All category contract tests pass for both InMemory and CloudKit backends.

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitCategoryRepository.swift MoolahTests/Domain/CategoryRepositoryContractTests.swift
git commit -m "Add CloudKitCategoryRepository with contract tests"
```

---

### Task 11: CloudKitAccountRepository + Contract Tests

**Files:**
- Create: `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift`
- Modify: `MoolahTests/Domain/AccountRepositoryContractTests.swift`

- [ ] **Step 1: Write the CloudKitAccountRepository**

```swift
import Foundation
import SwiftData

final class CloudKitAccountRepository: AccountRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let profileId: UUID
  private let currency: Currency

  init(modelContainer: ModelContainer, profileId: UUID, currency: Currency) {
    self.modelContainer = modelContainer
    self.profileId = profileId
    self.currency = currency
  }

  @MainActor
  private var context: ModelContext {
    modelContainer.mainContext
  }

  func fetchAll() async throws -> [Account] {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.profileId == profileId },
      sortBy: [SortDescriptor(\.position)]
    )
    let records = try await MainActor.run { try context.fetch(descriptor) }

    return try await records.map { record in
      let balance = try await computeBalance(for: record.id)
      let investmentValue = record.type == AccountType.investment.rawValue
        ? try await computeInvestmentValue(for: record.id)
        : nil
      return record.toDomain(balance: balance, investmentValue: investmentValue)
    }
  }

  func create(_ account: Account) async throws -> Account {
    guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw BackendError.validationFailed("Account name cannot be empty")
    }

    let record = AccountRecord.from(account, profileId: profileId, currencyCode: currency.code)
    try await MainActor.run {
      context.insert(record)
      try context.save()
    }

    // If account has an opening balance, create an opening balance transaction
    if account.balance.cents != 0 {
      let txn = TransactionRecord(
        profileId: profileId,
        type: TransactionType.openingBalance.rawValue,
        date: Date(),
        accountId: account.id,
        amount: account.balance.cents,
        currencyCode: currency.code
      )
      try await MainActor.run {
        context.insert(txn)
        try context.save()
      }
    }

    return account
  }

  func update(_ account: Account) async throws -> Account {
    let accountId = account.id
    let profileId = self.profileId
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == accountId && $0.profileId == profileId }
    )

    guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw BackendError.validationFailed("Account name cannot be empty")
    }

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.notFound("Account not found")
      }
      record.name = account.name
      record.type = account.type.rawValue
      record.position = account.position
      record.isHidden = account.isHidden
      // Balance is NOT updated — it's computed from transactions
      try context.save()
    }

    // Return with computed balance
    let balance = try await computeBalance(for: account.id)
    let investmentValue = account.type == .investment
      ? try await computeInvestmentValue(for: account.id)
      : nil
    return account.toDomain(balance: balance, investmentValue: investmentValue) // Use record's toDomain via re-fetch
  }

  func delete(id: UUID) async throws {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == id && $0.profileId == profileId }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.notFound("Account not found")
      }

      // Validate balance is zero
      let balance = try computeBalanceSync(for: id)
      guard balance.cents == 0 else {
        throw BackendError.validationFailed("Cannot delete account with non-zero balance")
      }

      // Soft delete
      record.isHidden = true
      try context.save()
    }
  }

  // MARK: - Balance Computation

  private func computeBalance(for accountId: UUID) async throws -> MonetaryAmount {
    try await MainActor.run { try computeBalanceSync(for: accountId) }
  }

  @MainActor
  private func computeBalanceSync(for accountId: UUID) throws -> MonetaryAmount {
    let profileId = self.profileId
    // Sum transactions where accountId matches (as source)
    let sourceDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate {
        $0.profileId == profileId && $0.accountId == accountId && $0.recurPeriod == nil
      }
    )
    let sourceRecords = try context.fetch(sourceDescriptor)
    let sourceSum = sourceRecords.reduce(0) { $0 + $1.amount }

    // Subtract transfers where toAccountId matches (money coming in is negative for source)
    let destDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate {
        $0.profileId == profileId && $0.toAccountId == accountId && $0.recurPeriod == nil
      }
    )
    let destRecords = try context.fetch(destDescriptor)
    let destSum = destRecords.reduce(0) { $0 + $1.amount }

    // For transfers: source gets -amount, dest gets +amount
    // The amount field stores the value from the source's perspective
    return MonetaryAmount(cents: sourceSum - destSum, currency: currency)
  }

  private func computeInvestmentValue(for accountId: UUID) async throws -> MonetaryAmount? {
    let profileId = self.profileId
    // Get the latest investment value record
    var descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate { $0.profileId == profileId && $0.accountId == accountId },
      sortBy: [SortDescriptor(\.date, order: .reverse)]
    )
    descriptor.fetchLimit = 1
    let records = try await MainActor.run { try context.fetch(descriptor) }
    return records.first?.toDomain().value
  }
}

private extension Account {
  func toDomain(balance: MonetaryAmount, investmentValue: MonetaryAmount?) -> Account {
    Account(
      id: id,
      name: name,
      type: type,
      balance: balance,
      investmentValue: investmentValue,
      position: position,
      isHidden: isHidden
    )
  }
}
```

**Note:** The balance computation for the CloudKit account repository differs from InMemory because InMemory stores the balance directly on the Account. In CloudKit, the balance is always computed from transactions. The contract tests may need adjustment if they test balance values that aren't set via transactions. Review the account contract tests carefully — if they set `balance` on the Account directly at creation, the CloudKit backend will instead create an opening balance transaction. The returned balance should match.

- [ ] **Step 2: Add CloudKit repository to contract tests**

Follow the same pattern as Task 10: change the parameter type to `any AccountRepository` and add CloudKit instances to the `arguments` arrays. Create a helper:

```swift
private func makeCloudKitAccountRepository(
  initialAccounts: [Account] = []
) -> CloudKitAccountRepository {
  let container = try! TestModelContainer.create()
  let profileId = UUID()
  let currency = Currency.defaultTestCurrency
  let repo = CloudKitAccountRepository(
    modelContainer: container, profileId: profileId, currency: currency)

  if !initialAccounts.isEmpty {
    let context = container.mainContext
    for account in initialAccounts {
      let record = AccountRecord.from(account, profileId: profileId, currencyCode: currency.code)
      context.insert(record)
      // If account has a non-zero balance, create an opening balance transaction
      if account.balance.cents != 0 {
        let txn = TransactionRecord(
          profileId: profileId,
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
  }

  return repo
}
```

- [ ] **Step 3: Run contract tests**

Run: `just test`
Expected: All account contract tests pass for both backends.

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitAccountRepository.swift MoolahTests/Domain/AccountRepositoryContractTests.swift
git commit -m "Add CloudKitAccountRepository with contract tests"
```

---

### Task 12: CloudKitTransactionRepository + Contract Tests

**Files:**
- Create: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift`
- Modify: `MoolahTests/Domain/TransactionRepositoryContractTests.swift`

- [ ] **Step 1: Write the CloudKitTransactionRepository**

This is the most complex repository. It must implement filtering, pagination, priorBalance, and payee suggestions.

```swift
import Foundation
import SwiftData

final class CloudKitTransactionRepository: TransactionRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let profileId: UUID
  private let currency: Currency

  init(modelContainer: ModelContainer, profileId: UUID, currency: Currency) {
    self.modelContainer = modelContainer
    self.profileId = profileId
    self.currency = currency
  }

  @MainActor
  private var context: ModelContext {
    modelContainer.mainContext
  }

  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    let profileId = self.profileId

    // Fetch all matching transactions for this profile, then apply filters in memory.
    // SwiftData #Predicate has limitations with optional comparisons, so we fetch by profileId
    // and filter the rest in memory (same pattern as InMemoryTransactionRepository).
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )

    let allRecords = try await MainActor.run { try context.fetch(descriptor) }
    var result = allRecords.map { $0.toDomain() }

    // Apply filters (matches InMemoryTransactionRepository exactly)
    if let accountId = filter.accountId {
      result = result.filter { $0.accountId == accountId || $0.toAccountId == accountId }
    }
    if let earmarkId = filter.earmarkId {
      result = result.filter { $0.earmarkId == earmarkId }
    }
    if let scheduled = filter.scheduled {
      result = result.filter { $0.isScheduled == scheduled }
    }
    if let dateRange = filter.dateRange {
      result = result.filter { dateRange.contains($0.date) }
    }
    if let categoryIds = filter.categoryIds, !categoryIds.isEmpty {
      result = result.filter { transaction in
        guard let categoryId = transaction.categoryId else { return false }
        return categoryIds.contains(categoryId)
      }
    }
    if let payee = filter.payee, !payee.isEmpty {
      let lowered = payee.lowercased()
      result = result.filter { transaction in
        guard let transactionPayee = transaction.payee else { return false }
        return transactionPayee.lowercased().contains(lowered)
      }
    }

    // Sort by date DESC, then id for stable ordering (matches server)
    result.sort { a, b in
      if a.date != b.date { return a.date > b.date }
      return a.id.uuidString < b.id.uuidString
    }

    // Paginate
    let offset = page * pageSize
    guard offset < result.count else {
      return TransactionPage(
        transactions: [], priorBalance: MonetaryAmount(cents: 0, currency: currency))
    }
    let end = min(offset + pageSize, result.count)
    let pageTransactions = Array(result[offset..<end])

    // priorBalance = sum of all transactions older than this page
    let priorBalance = result[end...].reduce(MonetaryAmount(cents: 0, currency: currency)) {
      $0 + $1.amount
    }

    return TransactionPage(transactions: pageTransactions, priorBalance: priorBalance)
  }

  func create(_ transaction: Transaction) async throws -> Transaction {
    let record = TransactionRecord.from(transaction, profileId: profileId)
    try await MainActor.run {
      context.insert(record)
      try context.save()
    }
    return transaction
  }

  func update(_ transaction: Transaction) async throws -> Transaction {
    let txnId = transaction.id
    let profileId = self.profileId
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.id == txnId && $0.profileId == profileId }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }
      record.type = transaction.type.rawValue
      record.date = transaction.date
      record.accountId = transaction.accountId
      record.toAccountId = transaction.toAccountId
      record.amount = transaction.amount.cents
      record.currencyCode = transaction.amount.currency.code
      record.payee = transaction.payee
      record.notes = transaction.notes
      record.categoryId = transaction.categoryId
      record.earmarkId = transaction.earmarkId
      record.recurPeriod = transaction.recurPeriod?.rawValue
      record.recurEvery = transaction.recurEvery
      try context.save()
    }
    return transaction
  }

  func delete(id: UUID) async throws {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.id == id && $0.profileId == profileId }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }
      context.delete(record)
      try context.save()
    }
  }

  func fetchPayeeSuggestions(prefix: String) async throws -> [String] {
    guard !prefix.isEmpty else { return [] }
    let profileId = self.profileId
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.profileId == profileId && $0.payee != nil }
    )

    let records = try await MainActor.run { try context.fetch(descriptor) }
    let lowered = prefix.lowercased()
    let matching = records.compactMap(\.payee)
      .filter { !$0.isEmpty && $0.lowercased().hasPrefix(lowered) }

    var counts: [String: Int] = [:]
    for payee in matching {
      counts[payee, default: 0] += 1
    }
    return counts.sorted { $0.value > $1.value }.map(\.key)
  }
}
```

- [ ] **Step 2: Add CloudKit repository to contract tests**

Same pattern as before. Create a helper:

```swift
private func makeCloudKitTransactionRepository(
  initialTransactions: [Transaction] = [],
  currency: Currency = .defaultTestCurrency
) -> CloudKitTransactionRepository {
  let container = try! TestModelContainer.create()
  let profileId = UUID()
  let repo = CloudKitTransactionRepository(
    modelContainer: container, profileId: profileId, currency: currency)

  if !initialTransactions.isEmpty {
    let context = container.mainContext
    for txn in initialTransactions {
      context.insert(TransactionRecord.from(txn, profileId: profileId))
    }
    try! context.save()
  }

  return repo
}
```

Update each test to use `any TransactionRepository` parameter and add CloudKit instances.

- [ ] **Step 3: Run contract tests**

Run: `just test`
Expected: All transaction contract tests pass for both backends.

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift MoolahTests/Domain/TransactionRepositoryContractTests.swift
git commit -m "Add CloudKitTransactionRepository with contract tests"
```

---

### Task 13: CloudKitEarmarkRepository + Contract Tests

**Files:**
- Create: `Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift`
- Modify: `MoolahTests/Domain/EarmarkRepositoryContractTests.swift`

- [ ] **Step 1: Write the CloudKitEarmarkRepository**

```swift
import Foundation
import SwiftData

final class CloudKitEarmarkRepository: EarmarkRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let profileId: UUID
  private let currency: Currency

  init(modelContainer: ModelContainer, profileId: UUID, currency: Currency) {
    self.modelContainer = modelContainer
    self.profileId = profileId
    self.currency = currency
  }

  @MainActor
  private var context: ModelContext {
    modelContainer.mainContext
  }

  func fetchAll() async throws -> [Earmark] {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<EarmarkRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    let records = try await MainActor.run { try context.fetch(descriptor) }

    return try await records.map { record in
      let (balance, saved, spent) = try await computeEarmarkTotals(for: record.id)
      return record.toDomain(balance: balance, saved: saved, spent: spent)
    }.sorted()
  }

  func create(_ earmark: Earmark) async throws -> Earmark {
    let record = EarmarkRecord.from(earmark, profileId: profileId, currencyCode: currency.code)
    try await MainActor.run {
      context.insert(record)
      try context.save()
    }
    return earmark
  }

  func update(_ earmark: Earmark) async throws -> Earmark {
    let earmarkId = earmark.id
    let profileId = self.profileId
    let descriptor = FetchDescriptor<EarmarkRecord>(
      predicate: #Predicate { $0.id == earmarkId && $0.profileId == profileId }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }
      record.name = earmark.name
      record.position = earmark.position
      record.isHidden = earmark.isHidden
      record.savingsTarget = earmark.savingsGoal?.cents
      record.savingsStartDate = earmark.savingsStartDate
      record.savingsEndDate = earmark.savingsEndDate
      try context.save()
    }
    return earmark
  }

  func fetchBudget(earmarkId: UUID) async throws -> [EarmarkBudgetItem] {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
      predicate: #Predicate { $0.earmarkId == earmarkId && $0.profileId == profileId }
    )
    let records = try await MainActor.run { try context.fetch(descriptor) }
    return records.map { $0.toDomain() }
  }

  func setBudget(earmarkId: UUID, categoryId: UUID, amount: Int) async throws {
    let profileId = self.profileId

    // Verify earmark exists
    let earmarkDescriptor = FetchDescriptor<EarmarkRecord>(
      predicate: #Predicate { $0.id == earmarkId && $0.profileId == profileId }
    )

    try await MainActor.run {
      guard try context.fetch(earmarkDescriptor).first != nil else {
        throw BackendError.serverError(404)
      }

      // Find existing budget item for this earmark+category
      let budgetDescriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
        predicate: #Predicate {
          $0.earmarkId == earmarkId && $0.categoryId == categoryId && $0.profileId == profileId
        }
      )
      let existing = try context.fetch(budgetDescriptor).first

      if amount == 0 {
        // Remove budget item
        if let existing {
          context.delete(existing)
        }
      } else if let existing {
        // Update existing
        existing.amount = amount
        existing.currencyCode = currency.code
      } else {
        // Create new
        let record = EarmarkBudgetItemRecord(
          profileId: profileId,
          earmarkId: earmarkId,
          categoryId: categoryId,
          amount: amount,
          currencyCode: currency.code
        )
        context.insert(record)
      }
      try context.save()
    }
  }

  // MARK: - Computed Values

  private func computeEarmarkTotals(for earmarkId: UUID) async throws -> (
    balance: MonetaryAmount, saved: MonetaryAmount, spent: MonetaryAmount
  ) {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate {
        $0.profileId == profileId && $0.earmarkId == earmarkId && $0.recurPeriod == nil
      }
    )
    let records = try await MainActor.run { try context.fetch(descriptor) }

    let zero = MonetaryAmount(cents: 0, currency: currency)
    var balance = zero
    var saved = zero
    var spent = zero

    for record in records {
      let amount = MonetaryAmount(cents: record.amount, currency: currency)
      balance += amount
      if record.amount > 0 {
        saved += amount
      } else if record.amount < 0 {
        spent += MonetaryAmount(cents: abs(record.amount), currency: currency)
      }
    }

    return (balance, saved, spent)
  }
}
```

- [ ] **Step 2: Add CloudKit repository to contract tests**

Same pattern. Create helper and add to arguments.

- [ ] **Step 3: Run contract tests**

Run: `just test`

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift MoolahTests/Domain/EarmarkRepositoryContractTests.swift
git commit -m "Add CloudKitEarmarkRepository with contract tests"
```

---

### Task 14: CloudKitAnalysisRepository + Contract Tests

**Files:**
- Create: `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift`
- Modify: `MoolahTests/Domain/AnalysisRepositoryContractTests.swift`

- [ ] **Step 1: Write the CloudKitAnalysisRepository**

This repository replicates the `InMemoryAnalysisRepository` logic but reads from SwiftData instead of in-memory stores. The computation logic is identical — it fetches all transactions and computes in memory.

Since the computation logic is identical to `InMemoryAnalysisRepository`, extract the shared computation into the `CloudKitAnalysisRepository` that reads from SwiftData:

```swift
import Foundation
import SwiftData

final class CloudKitAnalysisRepository: AnalysisRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let profileId: UUID
  private let currency: Currency

  init(modelContainer: ModelContainer, profileId: UUID, currency: Currency) {
    self.modelContainer = modelContainer
    self.profileId = profileId
    self.currency = currency
  }

  @MainActor
  private var context: ModelContext {
    modelContainer.mainContext
  }

  // MARK: - Data Fetching Helpers

  private func fetchTransactions(scheduled: Bool? = nil) async throws -> [Transaction] {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    let records = try await MainActor.run { try context.fetch(descriptor) }
    var transactions = records.map { $0.toDomain() }

    if let scheduled {
      transactions = transactions.filter { $0.isScheduled == scheduled }
    }

    return transactions
  }

  private func fetchAccounts() async throws -> [Account] {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    let records = try await MainActor.run { try context.fetch(descriptor) }
    // Accounts without balance — we only need type info for analysis
    return records.map {
      Account(
        id: $0.id,
        name: $0.name,
        type: AccountType(rawValue: $0.type) ?? .bank,
        position: $0.position,
        isHidden: $0.isHidden
      )
    }
  }

  // MARK: - Daily Balances

  func fetchDailyBalances(after: Date?, forecastUntil: Date?) async throws -> [DailyBalance] {
    let allTransactions = try await fetchTransactions(scheduled: false)
    let transactions = allTransactions.filter { txn in
      guard let after else { return true }
      return txn.date >= after
    }

    let accounts = try await fetchAccounts()
    let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))

    var dailyBalances: [Date: DailyBalance] = [:]
    var currentBalance: MonetaryAmount = .zero(currency: currency)
    var currentInvestments: MonetaryAmount = .zero(currency: currency)
    var currentEarmarks: MonetaryAmount = .zero(currency: currency)

    if let after {
      let priorTransactions = allTransactions.filter { $0.date < after }
      for txn in priorTransactions.sorted(by: { $0.date < $1.date }) {
        Self.applyTransaction(
          txn, to: &currentBalance, investments: &currentInvestments,
          earmarks: &currentEarmarks, investmentAccountIds: investmentAccountIds)
      }
    }

    for txn in transactions.sorted(by: { $0.date < $1.date }) {
      Self.applyTransaction(
        txn, to: &currentBalance, investments: &currentInvestments,
        earmarks: &currentEarmarks, investmentAccountIds: investmentAccountIds)

      let dayKey = Calendar.current.startOfDay(for: txn.date)
      dailyBalances[dayKey] = DailyBalance(
        date: dayKey, balance: currentBalance, earmarked: currentEarmarks,
        availableFunds: currentBalance - currentEarmarks,
        investments: currentInvestments, investmentValue: nil,
        netWorth: currentBalance + currentInvestments, bestFit: nil, isForecast: false)
    }

    var scheduledBalances: [DailyBalance] = []
    if let forecastUntil {
      let lastDate = transactions.last?.date ?? Date()
      let scheduledTxns = try await fetchTransactions(scheduled: true)
      scheduledBalances = Self.generateForecast(
        scheduledTransactions: scheduledTxns, startDate: lastDate, endDate: forecastUntil,
        startingBalance: currentBalance, startingEarmarks: currentEarmarks,
        startingInvestments: currentInvestments, investmentAccountIds: investmentAccountIds,
        currency: currency)
    }

    let actualBalances = dailyBalances.values.sorted { $0.date < $1.date }
    return actualBalances + scheduledBalances
  }

  // MARK: - Expense Breakdown

  func fetchExpenseBreakdown(monthEnd: Int, after: Date?) async throws -> [ExpenseBreakdown] {
    var transactions = try await fetchTransactions(scheduled: false)
    transactions = transactions.filter { $0.type == .expense }

    if let after {
      transactions = transactions.filter { $0.date >= after }
    }

    var breakdown: [String: [UUID?: MonetaryAmount]] = [:]
    for txn in transactions where txn.amount.cents < 0 {
      let month = Self.financialMonth(for: txn.date, monthEnd: monthEnd)
      let categoryId = txn.categoryId
      if breakdown[month] == nil { breakdown[month] = [:] }
      let current = breakdown[month]![categoryId] ?? .zero(currency: currency)
      breakdown[month]![categoryId] = current + MonetaryAmount(
        cents: abs(txn.amount.cents), currency: txn.amount.currency)
    }

    var results: [ExpenseBreakdown] = []
    for (month, categories) in breakdown {
      for (categoryId, total) in categories {
        results.append(ExpenseBreakdown(categoryId: categoryId, month: month, totalExpenses: total))
      }
    }
    return results.sorted { $0.month > $1.month }
  }

  // MARK: - Income and Expense

  func fetchIncomeAndExpense(monthEnd: Int, after: Date?) async throws -> [MonthlyIncomeExpense] {
    var transactions = try await fetchTransactions(scheduled: false)
    if let after {
      transactions = transactions.filter { $0.date >= after }
    }

    let accounts = try await fetchAccounts()
    let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))

    var monthlyData: [String: MonthData] = [:]
    for txn in transactions {
      guard txn.accountId != nil else { continue }
      let month = Self.financialMonth(for: txn.date, monthEnd: monthEnd)

      if monthlyData[month] == nil {
        monthlyData[month] = MonthData(start: txn.date, end: txn.date, currency: currency)
      }
      if txn.date < monthlyData[month]!.start { monthlyData[month]!.start = txn.date }
      if txn.date > monthlyData[month]!.end { monthlyData[month]!.end = txn.date }

      let isEarmarked = txn.earmarkId != nil
      let isFromInvestment = txn.accountId.map { investmentAccountIds.contains($0) } ?? false
      let isToInvestment = txn.toAccountId.map { investmentAccountIds.contains($0) } ?? false

      switch txn.type {
      case .income, .openingBalance:
        if isEarmarked { monthlyData[month]!.earmarkedIncome += txn.amount }
        else { monthlyData[month]!.income += txn.amount }
      case .expense:
        let absAmount = MonetaryAmount(cents: abs(txn.amount.cents), currency: txn.amount.currency)
        if isEarmarked { monthlyData[month]!.earmarkedExpense += absAmount }
        else { monthlyData[month]!.expense += absAmount }
      case .transfer:
        if isFromInvestment && !isToInvestment {
          monthlyData[month]!.earmarkedExpense += MonetaryAmount(
            cents: abs(txn.amount.cents), currency: txn.amount.currency)
        } else if !isFromInvestment && isToInvestment {
          monthlyData[month]!.earmarkedIncome += MonetaryAmount(
            cents: abs(txn.amount.cents), currency: txn.amount.currency)
        }
      }
    }

    return monthlyData.map { month, data in
      MonthlyIncomeExpense(
        month: month, start: data.start, end: data.end,
        income: data.income, expense: data.expense, profit: data.income - data.expense,
        earmarkedIncome: data.earmarkedIncome, earmarkedExpense: data.earmarkedExpense,
        earmarkedProfit: data.earmarkedIncome - data.earmarkedExpense)
    }.sorted { $0.month > $1.month }
  }

  // MARK: - Category Balances

  func fetchCategoryBalances(
    dateRange: ClosedRange<Date>, transactionType: TransactionType,
    filters: TransactionFilter?
  ) async throws -> [UUID: MonetaryAmount] {
    let allTransactions = try await fetchTransactions()

    let filtered = allTransactions.filter { tx in
      guard dateRange.contains(tx.date) else { return false }
      guard tx.type == transactionType else { return false }
      guard tx.categoryId != nil else { return false }
      guard tx.recurPeriod == nil else { return false }

      if let accountId = filters?.accountId, tx.accountId != accountId { return false }
      if let earmarkId = filters?.earmarkId, tx.earmarkId != earmarkId { return false }
      if let categoryIds = filters?.categoryIds, !categoryIds.contains(tx.categoryId!) {
        return false
      }
      if let payee = filters?.payee, tx.payee != payee { return false }
      return true
    }

    var balances: [UUID: MonetaryAmount] = [:]
    for transaction in filtered {
      let categoryId = transaction.categoryId!
      balances[categoryId, default: .zero(currency: transaction.amount.currency)] +=
        transaction.amount
    }
    return balances
  }

  // MARK: - Static Helpers (shared computation logic)

  static func applyTransaction(
    _ txn: Transaction, to balance: inout MonetaryAmount,
    investments: inout MonetaryAmount, earmarks: inout MonetaryAmount,
    investmentAccountIds: Set<UUID>
  ) {
    let isFromInvestment = txn.accountId.map { investmentAccountIds.contains($0) } ?? false
    let isToInvestment = txn.toAccountId.map { investmentAccountIds.contains($0) } ?? false

    switch txn.type {
    case .income, .expense, .openingBalance:
      if txn.accountId != nil { balance += txn.amount }
      if txn.earmarkId != nil { earmarks += txn.amount }
    case .transfer:
      if isFromInvestment && !isToInvestment {
        balance += txn.amount; investments -= txn.amount
      } else if !isFromInvestment && isToInvestment {
        balance -= txn.amount; investments += txn.amount
      }
    }
  }

  static func generateForecast(
    scheduledTransactions: [Transaction], startDate: Date, endDate: Date,
    startingBalance: MonetaryAmount, startingEarmarks: MonetaryAmount,
    startingInvestments: MonetaryAmount, investmentAccountIds: Set<UUID>,
    currency: Currency
  ) -> [DailyBalance] {
    var instances: [Transaction] = []
    for scheduled in scheduledTransactions {
      instances.append(contentsOf: extrapolateScheduledTransaction(scheduled, until: endDate))
    }
    instances.sort { $0.date < $1.date }

    var balance = startingBalance
    var earmarks = startingEarmarks
    var investments = startingInvestments
    var forecastBalances: [Date: DailyBalance] = [:]

    for instance in instances {
      applyTransaction(
        instance, to: &balance, investments: &investments,
        earmarks: &earmarks, investmentAccountIds: investmentAccountIds)
      let dayKey = Calendar.current.startOfDay(for: instance.date)
      forecastBalances[dayKey] = DailyBalance(
        date: dayKey, balance: balance, earmarked: earmarks,
        availableFunds: balance - earmarks, investments: investments,
        investmentValue: nil, netWorth: balance + investments, bestFit: nil, isForecast: true)
    }
    return forecastBalances.values.sorted { $0.date < $1.date }
  }

  static func extrapolateScheduledTransaction(
    _ scheduled: Transaction, until endDate: Date
  ) -> [Transaction] {
    guard let period = scheduled.recurPeriod, period != .once else {
      return scheduled.date <= endDate ? [scheduled] : []
    }
    let every = scheduled.recurEvery ?? 1
    var instances: [Transaction] = []
    var currentDate = scheduled.date
    while currentDate <= endDate {
      var instance = scheduled
      instance.date = currentDate
      instance.recurPeriod = nil
      instance.recurEvery = nil
      instances.append(instance)
      guard let nextDate = nextDueDate(from: currentDate, period: period, every: every) else {
        break
      }
      currentDate = nextDate
    }
    return instances
  }

  static func nextDueDate(from date: Date, period: RecurPeriod, every: Int) -> Date? {
    let calendar = Calendar.current
    var components = DateComponents()
    switch period {
    case .day: components.day = every
    case .week: components.weekOfYear = every
    case .month: components.month = every
    case .year: components.year = every
    case .once: return nil
    }
    return calendar.date(byAdding: components, to: date)
  }

  static func financialMonth(for date: Date, monthEnd: Int) -> String {
    let calendar = Calendar.current
    let dayOfMonth = calendar.component(.day, from: date)
    let adjustedDate =
      dayOfMonth > monthEnd
      ? calendar.date(byAdding: .month, value: 1, to: date)!
      : date
    let year = calendar.component(.year, from: adjustedDate)
    let month = calendar.component(.month, from: adjustedDate)
    return String(format: "%04d%02d", year, month)
  }
}

private struct MonthData {
  var start: Date
  var end: Date
  let currency: Currency
  var income: MonetaryAmount
  var expense: MonetaryAmount
  var earmarkedIncome: MonetaryAmount
  var earmarkedExpense: MonetaryAmount

  init(start: Date, end: Date, currency: Currency) {
    self.start = start
    self.end = end
    self.currency = currency
    self.income = .zero(currency: currency)
    self.expense = .zero(currency: currency)
    self.earmarkedIncome = .zero(currency: currency)
    self.earmarkedExpense = .zero(currency: currency)
  }
}
```

- [ ] **Step 2: Add CloudKit repository to analysis contract tests**

The analysis contract tests need both transaction and account data pre-seeded. Create a helper that builds a `CloudKitAnalysisRepository` backed by a shared container that also contains the transaction/account data the tests expect. Review the existing test setup carefully — it likely uses `InMemoryBackend` or constructs the `InMemoryAnalysisRepository` with its in-memory dependencies.

- [ ] **Step 3: Run contract tests**

Run: `just test`

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift MoolahTests/Domain/AnalysisRepositoryContractTests.swift
git commit -m "Add CloudKitAnalysisRepository with contract tests"
```

---

### Task 15: CloudKitInvestmentRepository + Contract Tests

**Files:**
- Create: `Backends/CloudKit/Repositories/CloudKitInvestmentRepository.swift`
- Modify: `MoolahTests/Domain/InvestmentRepositoryContractTests.swift`

- [ ] **Step 1: Write the CloudKitInvestmentRepository**

```swift
import Foundation
import SwiftData

final class CloudKitInvestmentRepository: InvestmentRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let profileId: UUID
  private let currency: Currency

  init(modelContainer: ModelContainer, profileId: UUID, currency: Currency) {
    self.modelContainer = modelContainer
    self.profileId = profileId
    self.currency = currency
  }

  @MainActor
  private var context: ModelContext {
    modelContainer.mainContext
  }

  func fetchValues(accountId: UUID, page: Int, pageSize: Int) async throws -> InvestmentValuePage {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate { $0.profileId == profileId && $0.accountId == accountId },
      sortBy: [SortDescriptor(\.date, order: .reverse)]
    )
    let allRecords = try await MainActor.run { try context.fetch(descriptor) }

    let offset = page * pageSize
    guard offset < allRecords.count else {
      return InvestmentValuePage(values: [], hasMore: false)
    }
    let end = min(offset + pageSize, allRecords.count)
    let pageValues = allRecords[offset..<end].map { $0.toDomain() }
    return InvestmentValuePage(values: Array(pageValues), hasMore: end < allRecords.count)
  }

  func setValue(accountId: UUID, date: Date, value: MonetaryAmount) async throws {
    let profileId = self.profileId
    // Check if a value already exists for this account+date (upsert)
    let descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate {
        $0.profileId == profileId && $0.accountId == accountId && $0.date == date
      }
    )

    try await MainActor.run {
      if let existing = try context.fetch(descriptor).first {
        existing.value = value.cents
        existing.currencyCode = value.currency.code
      } else {
        let record = InvestmentValueRecord(
          profileId: profileId, accountId: accountId, date: date,
          value: value.cents, currencyCode: value.currency.code)
        context.insert(record)
      }
      try context.save()
    }
  }

  func removeValue(accountId: UUID, date: Date) async throws {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate {
        $0.profileId == profileId && $0.accountId == accountId && $0.date == date
      }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.notFound("Investment value not found")
      }
      context.delete(record)
      try context.save()
    }
  }

  func fetchDailyBalances(accountId: UUID) async throws -> [AccountDailyBalance] {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate { $0.profileId == profileId && $0.accountId == accountId },
      sortBy: [SortDescriptor(\.date)]
    )
    let records = try await MainActor.run { try context.fetch(descriptor) }
    return records.map {
      AccountDailyBalance(
        date: $0.date,
        balance: MonetaryAmount(cents: $0.value, currency: Currency.from(code: $0.currencyCode))
      )
    }
  }
}
```

- [ ] **Step 2: Add CloudKit repository to contract tests**

- [ ] **Step 3: Run contract tests**

Run: `just test`

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitInvestmentRepository.swift MoolahTests/Domain/InvestmentRepositoryContractTests.swift
git commit -m "Add CloudKitInvestmentRepository with contract tests"
```

---

### Task 16: CloudKitAuthProvider + Contract Tests

**Files:**
- Create: `Backends/CloudKit/CloudKitAuthProvider.swift`
- Modify: `MoolahTests/Domain/AuthContractTests.swift`

- [ ] **Step 1: Write the CloudKitAuthProvider**

```swift
import CloudKit
import Foundation

final class CloudKitAuthProvider: AuthProvider, Sendable {
  private let profileLabel: String

  nonisolated let requiresExplicitSignIn: Bool = false

  init(profileLabel: String) {
    self.profileLabel = profileLabel
  }

  func currentUser() async throws -> UserProfile? {
    let status = try await CKContainer.default().accountStatus()
    guard status == .available else { return nil }
    return UserProfile(
      id: "icloud-user",
      givenName: profileLabel,
      familyName: "",
      pictureURL: nil
    )
  }

  func signIn() async throws -> UserProfile {
    let status = try await CKContainer.default().accountStatus()
    guard status == .available else {
      throw BackendError.unauthenticated
    }
    return UserProfile(
      id: "icloud-user",
      givenName: profileLabel,
      familyName: "",
      pictureURL: nil
    )
  }

  func signOut() async throws {
    // No-op — cannot sign out of iCloud programmatically
  }
}
```

- [ ] **Step 2: Add to auth contract tests**

The existing auth contract tests test sign-in/sign-out state toggling. `CloudKitAuthProvider` doesn't do that (sign-out is a no-op, sign-in depends on real iCloud). Add a separate test for the no-explicit-sign-in behavior:

```swift
@Test("CloudKitAuthProvider does not require explicit sign in")
func testCloudKitNoExplicitSignIn() {
  let auth = CloudKitAuthProvider(profileLabel: "Test")
  #expect(auth.requiresExplicitSignIn == false)
}
```

The full sign-in/sign-out contract tests can't run without real CloudKit, so we skip them for unit tests.

- [ ] **Step 3: Build and run tests**

Run: `just test`

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/CloudKitAuthProvider.swift MoolahTests/Domain/AuthContractTests.swift
git commit -m "Add CloudKitAuthProvider"
```

---

### Task 17: CloudKitBackend Assembly

**Files:**
- Create: `Backends/CloudKit/CloudKitBackend.swift`

- [ ] **Step 1: Write the CloudKitBackend**

```swift
import Foundation
import SwiftData

final class CloudKitBackend: BackendProvider, @unchecked Sendable {
  let auth: any AuthProvider
  let accounts: any AccountRepository
  let transactions: any TransactionRepository
  let categories: any CategoryRepository
  let earmarks: any EarmarkRepository
  let analysis: any AnalysisRepository
  let investments: any InvestmentRepository

  init(modelContainer: ModelContainer, profileId: UUID, currency: Currency, profileLabel: String) {
    self.auth = CloudKitAuthProvider(profileLabel: profileLabel)
    self.accounts = CloudKitAccountRepository(
      modelContainer: modelContainer, profileId: profileId, currency: currency)
    self.transactions = CloudKitTransactionRepository(
      modelContainer: modelContainer, profileId: profileId, currency: currency)
    self.categories = CloudKitCategoryRepository(
      modelContainer: modelContainer, profileId: profileId)
    self.earmarks = CloudKitEarmarkRepository(
      modelContainer: modelContainer, profileId: profileId, currency: currency)
    self.analysis = CloudKitAnalysisRepository(
      modelContainer: modelContainer, profileId: profileId, currency: currency)
    self.investments = CloudKitInvestmentRepository(
      modelContainer: modelContainer, profileId: profileId, currency: currency)
  }
}
```

- [ ] **Step 2: Build**

Run: `just build-mac`

- [ ] **Step 3: Commit**

```bash
git add Backends/CloudKit/CloudKitBackend.swift
git commit -m "Add CloudKitBackend assembly"
```

---

### Task 18: ProfileSession — Branch on BackendType

**Files:**
- Modify: `App/ProfileSession.swift`
- Modify: `App/SessionManager.swift`

- [ ] **Step 1: Update ProfileSession to accept ModelContainer and branch**

Replace the full content of `App/ProfileSession.swift`:

```swift
import Foundation
import SwiftData

/// Holds the backend and all stores for a single profile.
/// Each profile gets its own isolated backend and store instances.
@Observable
@MainActor
final class ProfileSession: Identifiable {
  let profile: Profile
  let backend: BackendProvider
  let authStore: AuthStore
  let accountStore: AccountStore
  let transactionStore: TransactionStore
  let categoryStore: CategoryStore
  let earmarkStore: EarmarkStore
  let analysisStore: AnalysisStore
  let investmentStore: InvestmentStore

  nonisolated var id: UUID { profile.id }

  init(profile: Profile, modelContainer: ModelContainer? = nil) {
    self.profile = profile

    let backend: BackendProvider
    switch profile.backendType {
    case .remote, .moolah:
      // Each profile gets its own cookie storage and URLSession.
      let config = URLSessionConfiguration.ephemeral
      let cookieStorage = config.httpCookieStorage!
      let session = URLSession(configuration: config)
      let cookieKeychain = CookieKeychain(account: profile.id.uuidString)

      backend = RemoteBackend(
        baseURL: profile.resolvedServerURL,
        currency: profile.currency,
        session: session,
        cookieKeychain: cookieKeychain,
        cookieStorage: cookieStorage
      )

    case .cloudKit:
      guard let modelContainer else {
        fatalError("ModelContainer required for CloudKit profiles")
      }
      backend = CloudKitBackend(
        modelContainer: modelContainer,
        profileId: profile.id,
        currency: profile.currency,
        profileLabel: profile.label
      )
    }

    self.backend = backend

    self.authStore = AuthStore(backend: backend)
    self.accountStore = AccountStore(repository: backend.accounts)
    self.transactionStore = TransactionStore(repository: backend.transactions)
    self.categoryStore = CategoryStore(repository: backend.categories)
    self.earmarkStore = EarmarkStore(repository: backend.earmarks)
    self.analysisStore = AnalysisStore(repository: backend.analysis)
    self.investmentStore = InvestmentStore(repository: backend.investments)

    // Wire up cross-store side effects
    let accountStore = self.accountStore
    let earmarkStore = self.earmarkStore
    self.transactionStore.onMutate = { old, new in
      accountStore.applyTransactionDelta(old: old, new: new)
      earmarkStore.applyTransactionDelta(old: old, new: new)
    }
  }
}
```

- [ ] **Step 2: Update SessionManager to hold ModelContainer**

Replace the full content of `App/SessionManager.swift`:

```swift
import Foundation
import SwiftData

/// Owns the mapping from Profile.ID to ProfileSession.
/// Multiple macOS windows share session instances through this manager.
/// Injected via `.environment(sessionManager)` at the app level.
@Observable
@MainActor
final class SessionManager {
  let modelContainer: ModelContainer
  private(set) var sessions: [UUID: ProfileSession] = [:]

  init(modelContainer: ModelContainer) {
    self.modelContainer = modelContainer
  }

  /// Returns the existing session for a profile, or creates one.
  func session(for profile: Profile) -> ProfileSession {
    if let existing = sessions[profile.id] { return existing }
    let session = ProfileSession(profile: profile, modelContainer: modelContainer)
    sessions[profile.id] = session
    return session
  }

  /// Removes the session for a profile (e.g. when profile is deleted).
  func removeSession(for profileID: UUID) {
    sessions.removeValue(forKey: profileID)
  }

  /// Replaces the session for a profile with a fresh instance
  /// (e.g. when the profile's server URL changes).
  func rebuildSession(for profile: Profile) {
    sessions[profile.id] = ProfileSession(profile: profile, modelContainer: modelContainer)
  }
}
```

- [ ] **Step 3: Build**

Run: `just build-mac`
Expected: Build may fail because `MoolahApp` and possibly iOS code creates `SessionManager()` without the new parameter. Fix in the next task.

- [ ] **Step 4: Commit**

```bash
git add App/ProfileSession.swift App/SessionManager.swift
git commit -m "ProfileSession and SessionManager accept ModelContainer for CloudKit"
```

---

### Task 19: MoolahApp — Create ModelContainer and Wire Up

**Files:**
- Modify: `App/MoolahApp.swift`
- Modify: `project.yml`

- [ ] **Step 1: Update project.yml for CloudKit**

Add CloudKit entitlement to both iOS and macOS targets. In `project.yml`, add an `entitlements` section under each app target's settings. Alternatively, create an entitlements file. The exact approach depends on whether xcodegen supports CloudKit entitlements via `project.yml` — check by looking at xcodegen docs. At minimum, add to each target's settings:

```yaml
    settings:
      base:
        # ... existing settings ...
    entitlements:
      path: App/Moolah.entitlements
```

Create `App/Moolah.entitlements`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.icloud-container-identifiers</key>
	<array>
		<string>iCloud.$(CFBundleIdentifier)</string>
	</array>
	<key>com.apple.developer.icloud-services</key>
	<array>
		<string>CloudKit</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 2: Update MoolahApp to create shared ModelContainer**

Replace the full content of `App/MoolahApp.swift`:

```swift
import SwiftData
import SwiftUI

/// Commands for creating new transactions
struct NewTransactionCommands: Commands {
  @FocusedValue(\.newTransactionAction) private var newTransactionAction

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Transaction") {
        newTransactionAction?()
      }
      .keyboardShortcut("n", modifiers: .command)
      .disabled(newTransactionAction == nil)
    }
  }
}

/// Commands for creating new earmarks
struct NewEarmarkCommands: Commands {
  @FocusedValue(\.newEarmarkAction) private var newEarmarkAction

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("New Earmark") {
        newEarmarkAction?()
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])
      .disabled(newEarmarkAction == nil)
    }
  }
}

/// Commands for refreshing data
struct RefreshCommands: Commands {
  @FocusedValue(\.refreshAction) private var refreshAction

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Divider()
      Button("Refresh") {
        refreshAction?()
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(refreshAction == nil)
    }
  }
}

/// View menu toggle for showing hidden accounts and earmarks
struct ShowHiddenCommands: Commands {
  @FocusedValue(\.showHiddenAccounts) private var showHidden

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      if let showHidden {
        Toggle("Show Hidden Accounts", isOn: showHidden)
          .keyboardShortcut("h", modifiers: [.command, .shift])
      }
    }
  }
}

@main
@MainActor
struct MoolahApp: App {
  private let modelContainer: ModelContainer
  @State private var profileStore: ProfileStore

  #if os(macOS)
    @State private var sessionManager: SessionManager
  #else
    @State private var activeSession: ProfileSession?
  #endif

  init() {
    let schema = Schema([
      ProfileRecord.self,
      AccountRecord.self,
      TransactionRecord.self,
      CategoryRecord.self,
      EarmarkRecord.self,
      EarmarkBudgetItemRecord.self,
      InvestmentValueRecord.self,
    ])
    do {
      let container = try ModelContainer(for: schema)
      self.modelContainer = container
      self._profileStore = State(
        initialValue: ProfileStore(
          validator: RemoteServerValidator(), modelContainer: container))
      #if os(macOS)
        self._sessionManager = State(initialValue: SessionManager(modelContainer: container))
      #endif
    } catch {
      fatalError("Failed to initialize ModelContainer: \(error)")
    }
  }

  var body: some Scene {
    #if os(macOS)
      WindowGroup(for: Profile.ID.self) { $profileID in
        ProfileWindowView(profileID: profileID)
          .environment(profileStore)
          .environment(sessionManager)
      }
      .commands {
        ProfileCommands(profileStore: profileStore, sessionManager: sessionManager)
        NewTransactionCommands()
        NewEarmarkCommands()
        RefreshCommands()
        ShowHiddenCommands()
      }

      Settings {
        SettingsView()
          .environment(profileStore)
          .environment(sessionManager)
      }
    #else
      WindowGroup {
        ProfileRootView(activeSession: $activeSession)
          .environment(profileStore)
      }
      .modelContainer(modelContainer)
      .commands {
        NewTransactionCommands()
        NewEarmarkCommands()
        RefreshCommands()
        ShowHiddenCommands()
      }
    #endif
  }
}
```

**Important:** Tasks 19, 20, and 21 are interdependent (`MoolahApp` → `ProfileStore` → `ProfileDataDeleter`). Implement all three together before attempting to build. The code won't compile until all three are in place.

- [ ] **Step 3: Regenerate Xcode project**

Run: `just generate`
Then: `just build-mac`

- [ ] **Step 4: Commit**

```bash
git add App/MoolahApp.swift App/Moolah.entitlements project.yml
git commit -m "Create shared ModelContainer in MoolahApp and configure CloudKit entitlements"
```

---

### Task 20: ProfileStore — Hybrid UserDefaults + SwiftData

**Files:**
- Modify: `Features/Profiles/ProfileStore.swift`

- [ ] **Step 1: Update ProfileStore to be hybrid**

This is a significant change. The ProfileStore needs to:
1. Accept a `ModelContainer` at init
2. Fetch `ProfileRecord`s from SwiftData for iCloud profiles
3. Observe `NSPersistentStoreRemoteChange` for cross-device sync
4. Add/remove iCloud profiles via SwiftData
5. Validate iCloud availability before adding iCloud profiles
6. Handle active profile being deleted on another device

Replace the full content of `Features/Profiles/ProfileStore.swift`:

```swift
import CloudKit
import Foundation
import OSLog
import SwiftData

/// Manages the list of profiles and which one is active.
/// Remote profiles are persisted to UserDefaults; iCloud profiles to SwiftData/CloudKit.
@Observable
@MainActor
final class ProfileStore {
  private static let profilesKey = "com.moolah.profiles"
  private static let activeProfileKey = "com.moolah.activeProfileID"

  private(set) var remoteProfiles: [Profile] = []
  private(set) var cloudProfiles: [Profile] = []
  private(set) var activeProfileID: UUID?
  private(set) var isValidating = false
  private(set) var validationError: String?

  var profiles: [Profile] { cloudProfiles + remoteProfiles }

  private let defaults: UserDefaults
  private let validator: (any ServerValidator)?
  private let modelContainer: ModelContainer?
  private let logger = Logger(subsystem: "com.moolah.app", category: "ProfileStore")

  var activeProfile: Profile? {
    profiles.first { $0.id == activeProfileID }
  }

  var hasProfiles: Bool {
    !profiles.isEmpty
  }

  init(
    defaults: UserDefaults = .standard,
    validator: (any ServerValidator)? = nil,
    modelContainer: ModelContainer? = nil
  ) {
    self.defaults = defaults
    self.validator = validator
    self.modelContainer = modelContainer
    loadFromDefaults()
    loadCloudProfiles()
    observeRemoteChanges()
  }

  // MARK: - Profile Management

  func addProfile(_ profile: Profile) {
    switch profile.backendType {
    case .remote, .moolah:
      remoteProfiles.append(profile)
      saveToDefaults()
    case .cloudKit:
      guard let modelContainer else { return }
      let record = ProfileRecord.from(profile: profile)
      modelContainer.mainContext.insert(record)
      try? modelContainer.mainContext.save()
      loadCloudProfiles()
    }
    if profiles.count == 1 {
      activeProfileID = profile.id
      saveActiveProfile()
    }
    logger.debug("Added profile: \(profile.label) (\(profile.id))")
  }

  func removeProfile(_ id: UUID) {
    if let profile = profiles.first(where: { $0.id == id }) {
      switch profile.backendType {
      case .remote, .moolah:
        remoteProfiles.removeAll { $0.id == id }
        let keychain = CookieKeychain(account: id.uuidString)
        keychain.clear()
        saveToDefaults()
      case .cloudKit:
        deleteCloudProfile(id: id)
      }
    }

    if activeProfileID == id {
      activeProfileID = profiles.first?.id
      saveActiveProfile()
    }
    logger.debug("Removed profile: \(id)")
  }

  func setActiveProfile(_ id: UUID) {
    guard profiles.contains(where: { $0.id == id }) else { return }
    activeProfileID = id
    saveActiveProfile()
    logger.debug("Switched to profile: \(id)")
  }

  func updateProfile(_ profile: Profile) {
    switch profile.backendType {
    case .remote, .moolah:
      guard let index = remoteProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
      remoteProfiles[index] = profile
      saveToDefaults()
    case .cloudKit:
      updateCloudProfile(profile)
    }
    logger.debug("Updated profile: \(profile.label)")
  }

  // MARK: - Validated mutations

  func validateAndAddProfile(_ profile: Profile) async -> Bool {
    switch profile.backendType {
    case .remote, .moolah:
      guard await validateServer(url: profile.resolvedServerURL) else { return false }
    case .cloudKit:
      guard await validateiCloudAvailability() else { return false }
    }
    addProfile(profile)
    return true
  }

  func validateAndUpdateProfile(_ profile: Profile) async -> Bool {
    switch profile.backendType {
    case .remote, .moolah:
      guard await validateServer(url: profile.resolvedServerURL) else { return false }
    case .cloudKit:
      break  // No validation needed for updates
    }
    updateProfile(profile)
    return true
  }

  func clearValidationError() {
    validationError = nil
  }

  // MARK: - iCloud Availability

  private func validateiCloudAvailability() async -> Bool {
    isValidating = true
    validationError = nil
    defer { isValidating = false }

    do {
      let status = try await CKContainer.default().accountStatus()
      guard status == .available else {
        validationError = "iCloud is not available. Please sign in to iCloud in Settings."
        return false
      }
      return true
    } catch {
      validationError = "Could not check iCloud availability"
      return false
    }
  }

  // MARK: - Server Validation

  private func validateServer(url: URL) async -> Bool {
    guard let validator else { return true }
    isValidating = true
    validationError = nil
    defer { isValidating = false }

    do {
      try await validator.validate(url: url)
      return true
    } catch let error as BackendError {
      if case .validationFailed(let message) = error {
        validationError = message
      } else {
        validationError = "Could not connect to server"
      }
      return false
    } catch {
      validationError = "Could not connect to server"
      return false
    }
  }

  // MARK: - SwiftData (iCloud profiles)

  private func loadCloudProfiles() {
    guard let modelContainer else { return }
    do {
      let descriptor = FetchDescriptor<ProfileRecord>(
        sortBy: [SortDescriptor(\.createdAt)]
      )
      let records = try modelContainer.mainContext.fetch(descriptor)
      cloudProfiles = records.map { $0.toProfile() }

      // If active profile was deleted on another device, clear it
      if let activeProfileID, !profiles.contains(where: { $0.id == activeProfileID }) {
        self.activeProfileID = profiles.first?.id
        saveActiveProfile()
      }
    } catch {
      logger.error("Failed to fetch cloud profiles: \(error.localizedDescription)")
    }
  }

  private func deleteCloudProfile(id: UUID) {
    guard let modelContainer else { return }
    let context = modelContainer.mainContext

    // Delete all data for this profile
    let deleter = ProfileDataDeleter(modelContext: context)
    deleter.deleteAllData(for: id)

    // Delete the profile record
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == id }
    )
    if let record = try? context.fetch(descriptor).first {
      context.delete(record)
    }
    try? context.save()
    loadCloudProfiles()
  }

  private func updateCloudProfile(_ profile: Profile) {
    guard let modelContainer else { return }
    let profileId = profile.id
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    )
    guard let record = try? modelContainer.mainContext.fetch(descriptor).first else { return }
    record.label = profile.label
    record.currencyCode = profile.currencyCode
    record.financialYearStartMonth = profile.financialYearStartMonth
    try? modelContainer.mainContext.save()
    loadCloudProfiles()
  }

  private func observeRemoteChanges() {
    guard let modelContainer else { return }
    NotificationCenter.default.addObserver(
      forName: ModelContext.willSave,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.loadCloudProfiles()
      }
    }
    // Also observe remote CloudKit changes
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("NSPersistentStoreRemoteChangeNotification"),
      object: modelContainer.configurations.first,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.loadCloudProfiles()
      }
    }
  }

  // MARK: - UserDefaults Persistence (remote profiles)

  private func loadFromDefaults() {
    if let data = defaults.data(forKey: Self.profilesKey) {
      do {
        remoteProfiles = try JSONDecoder().decode([Profile].self, from: data)
        logger.debug("Loaded \(self.remoteProfiles.count) remote profiles from defaults")
      } catch {
        logger.error("Failed to decode profiles: \(error.localizedDescription)")
        remoteProfiles = []
      }
    }

    let savedIDString = defaults.string(forKey: Self.activeProfileKey)
    if let idString = savedIDString,
      let id = UUID(uuidString: idString)
    {
      activeProfileID = id
      logger.debug("Restored active profile: \(id)")
    } else {
      activeProfileID = nil
      logger.debug("No saved active profile")
    }
  }

  private func saveToDefaults() {
    do {
      let data = try JSONEncoder().encode(remoteProfiles)
      defaults.set(data, forKey: Self.profilesKey)
    } catch {
      logger.error("Failed to encode profiles: \(error.localizedDescription)")
    }
  }

  private func saveActiveProfile() {
    if let activeProfileID {
      defaults.set(activeProfileID.uuidString, forKey: Self.activeProfileKey)
    } else {
      defaults.removeObject(forKey: Self.activeProfileKey)
    }
  }
}
```

- [ ] **Step 2: Build**

Run: `just build-mac`

**Important:** This references `ProfileDataDeleter` which is created in Task 21. Either implement Task 21 first, or implement Tasks 20 and 21 together. If implementing separately, temporarily comment out the `deleteCloudProfile` method body until Task 21 is done.

- [ ] **Step 3: Run tests**

Run: `just test`

- [ ] **Step 4: Commit**

```bash
git add Features/Profiles/ProfileStore.swift
git commit -m "Make ProfileStore hybrid: UserDefaults for remote, SwiftData for iCloud profiles"
```

---

### Task 21: ProfileDataDeleter

**Files:**
- Create: `Backends/CloudKit/ProfileDataDeleter.swift`
- Create: `MoolahTests/CloudKit/ProfileDataDeleterTests.swift`

- [ ] **Step 1: Write the ProfileDataDeleter**

```swift
import Foundation
import SwiftData

/// Batch-deletes all records belonging to a specific profile.
/// Used when an iCloud profile is removed.
struct ProfileDataDeleter {
  let modelContext: ModelContext

  /// Delete all data records for the given profile ID.
  /// Does NOT delete the ProfileRecord itself — caller handles that.
  @MainActor
  func deleteAllData(for profileId: UUID) {
    deleteAll(TransactionRecord.self, profileId: profileId)
    deleteAll(AccountRecord.self, profileId: profileId)
    deleteAll(CategoryRecord.self, profileId: profileId)
    deleteAll(EarmarkRecord.self, profileId: profileId)
    deleteAll(EarmarkBudgetItemRecord.self, profileId: profileId)
    deleteAll(InvestmentValueRecord.self, profileId: profileId)
    try? modelContext.save()
  }

  @MainActor
  private func deleteAll<T: PersistentModel>(_ type: T.Type, profileId: UUID) {
    // SwiftData doesn't support batch delete with predicates on generic types easily,
    // so we fetch and delete individually. For the data volumes in this app, this is fine.
    do {
      try modelContext.delete(model: T.self, where: #Predicate<T> { _ in true })
      // The above deletes ALL records of this type. We need profile-scoped deletion.
      // Unfortunately, #Predicate on generic T doesn't support accessing .profileId.
      // Use type-specific deletions instead.
    } catch {
      // Fallback handled by type-specific methods
    }
  }
}
```

Actually, the generic approach won't work because `#Predicate` can't access `profileId` on a generic `T`. Use explicit type-specific deletions:

```swift
import Foundation
import SwiftData

/// Batch-deletes all records belonging to a specific profile.
/// Used when an iCloud profile is removed.
struct ProfileDataDeleter {
  let modelContext: ModelContext

  /// Delete all data records for the given profile ID.
  /// Does NOT delete the ProfileRecord itself — caller handles that.
  @MainActor
  func deleteAllData(for profileId: UUID) {
    deleteTransactions(profileId: profileId)
    deleteAccounts(profileId: profileId)
    deleteCategories(profileId: profileId)
    deleteEarmarks(profileId: profileId)
    deleteBudgetItems(profileId: profileId)
    deleteInvestmentValues(profileId: profileId)
    try? modelContext.save()
  }

  @MainActor private func deleteTransactions(profileId: UUID) {
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    if let records = try? modelContext.fetch(descriptor) {
      for record in records { modelContext.delete(record) }
    }
  }

  @MainActor private func deleteAccounts(profileId: UUID) {
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    if let records = try? modelContext.fetch(descriptor) {
      for record in records { modelContext.delete(record) }
    }
  }

  @MainActor private func deleteCategories(profileId: UUID) {
    let descriptor = FetchDescriptor<CategoryRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    if let records = try? modelContext.fetch(descriptor) {
      for record in records { modelContext.delete(record) }
    }
  }

  @MainActor private func deleteEarmarks(profileId: UUID) {
    let descriptor = FetchDescriptor<EarmarkRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    if let records = try? modelContext.fetch(descriptor) {
      for record in records { modelContext.delete(record) }
    }
  }

  @MainActor private func deleteBudgetItems(profileId: UUID) {
    let descriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    if let records = try? modelContext.fetch(descriptor) {
      for record in records { modelContext.delete(record) }
    }
  }

  @MainActor private func deleteInvestmentValues(profileId: UUID) {
    let descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    if let records = try? modelContext.fetch(descriptor) {
      for record in records { modelContext.delete(record) }
    }
  }
}
```

- [ ] **Step 2: Write tests**

Create `MoolahTests/CloudKit/ProfileDataDeleterTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ProfileDataDeleter")
struct ProfileDataDeleterTests {
  @Test("deletes all data for a profile without affecting other profiles")
  @MainActor
  func testDeletesOnlyTargetProfile() throws {
    let container = try TestModelContainer.create()
    let context = container.mainContext

    let profileA = UUID()
    let profileB = UUID()

    // Seed data for both profiles
    context.insert(CategoryRecord(profileId: profileA, name: "Cat A"))
    context.insert(CategoryRecord(profileId: profileB, name: "Cat B"))
    context.insert(AccountRecord(
      profileId: profileA, name: "Account A", type: "bank", currencyCode: "AUD"))
    context.insert(AccountRecord(
      profileId: profileB, name: "Account B", type: "bank", currencyCode: "AUD"))
    context.insert(TransactionRecord(
      profileId: profileA, type: "expense", date: Date(), amount: -500, currencyCode: "AUD"))
    context.insert(TransactionRecord(
      profileId: profileB, type: "income", date: Date(), amount: 1000, currencyCode: "AUD"))
    try context.save()

    // Delete profile A's data
    let deleter = ProfileDataDeleter(modelContext: context)
    deleter.deleteAllData(for: profileA)

    // Profile B's data should remain
    let categories = try context.fetch(FetchDescriptor<CategoryRecord>())
    #expect(categories.count == 1)
    #expect(categories[0].name == "Cat B")

    let accounts = try context.fetch(FetchDescriptor<AccountRecord>())
    #expect(accounts.count == 1)
    #expect(accounts[0].name == "Account B")

    let transactions = try context.fetch(FetchDescriptor<TransactionRecord>())
    #expect(transactions.count == 1)
    #expect(transactions[0].amount == 1000)
  }
}
```

- [ ] **Step 3: Run tests**

Run: `just test`

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/ProfileDataDeleter.swift MoolahTests/CloudKit/ProfileDataDeleterTests.swift
git commit -m "Add ProfileDataDeleter with tests"
```

---

### Task 22: Multi-Profile Isolation Tests

**Files:**
- Create: `MoolahTests/CloudKit/MultiProfileIsolationTests.swift`

- [ ] **Step 1: Write isolation tests**

```swift
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("Multi-Profile Isolation")
struct MultiProfileIsolationTests {
  @Test("two CloudKit backends sharing a container see only their own data")
  @MainActor
  func testProfileIsolation() async throws {
    let container = try TestModelContainer.create()
    let currency = Currency.defaultTestCurrency
    let profileA = UUID()
    let profileB = UUID()

    let backendA = CloudKitBackend(
      modelContainer: container, profileId: profileA, currency: currency, profileLabel: "A")
    let backendB = CloudKitBackend(
      modelContainer: container, profileId: profileB, currency: currency, profileLabel: "B")

    // Create data in profile A
    _ = try await backendA.categories.create(Category(name: "Groceries"))
    _ = try await backendA.categories.create(Category(name: "Transport"))

    // Create data in profile B
    _ = try await backendB.categories.create(Category(name: "Entertainment"))

    // Profile A sees only its categories
    let categoriesA = try await backendA.categories.fetchAll()
    #expect(categoriesA.count == 2)

    // Profile B sees only its category
    let categoriesB = try await backendB.categories.fetchAll()
    #expect(categoriesB.count == 1)
    #expect(categoriesB[0].name == "Entertainment")
  }

  @Test("deleting one profile's data doesn't affect another")
  @MainActor
  func testDeleteIsolation() async throws {
    let container = try TestModelContainer.create()
    let currency = Currency.defaultTestCurrency
    let profileA = UUID()
    let profileB = UUID()

    let backendA = CloudKitBackend(
      modelContainer: container, profileId: profileA, currency: currency, profileLabel: "A")
    let backendB = CloudKitBackend(
      modelContainer: container, profileId: profileB, currency: currency, profileLabel: "B")

    _ = try await backendA.categories.create(Category(name: "A-Cat"))
    _ = try await backendB.categories.create(Category(name: "B-Cat"))

    // Delete all of profile A's data
    let deleter = ProfileDataDeleter(modelContext: container.mainContext)
    deleter.deleteAllData(for: profileA)

    // Profile A should see nothing
    let categoriesA = try await backendA.categories.fetchAll()
    #expect(categoriesA.isEmpty)

    // Profile B should be unaffected
    let categoriesB = try await backendB.categories.fetchAll()
    #expect(categoriesB.count == 1)
    #expect(categoriesB[0].name == "B-Cat")
  }
}
```

- [ ] **Step 2: Run tests**

Run: `just test`

- [ ] **Step 3: Commit**

```bash
git add MoolahTests/CloudKit/MultiProfileIsolationTests.swift
git commit -m "Add multi-profile isolation tests"
```

---

### Task 23: Profile Form UI — Add iCloud Option

**Files:**
- Modify: `Features/Profiles/Views/ProfileFormView.swift`

- [ ] **Step 1: Add iCloud option to ProfileFormView**

Update `ProfileFormView.swift` to add iCloud as the first option in the type picker, with a form for name, currency, and financial year start month.

Replace the full content of `Features/Profiles/Views/ProfileFormView.swift`:

```swift
import SwiftUI

/// Sheet for adding a new profile. Presents three choices:
/// - iCloud (local + CloudKit sync)
/// - Moolah (fixed URL)
/// - Custom Server (user enters URL)
struct ProfileFormView: View {
  @Environment(ProfileStore.self) private var profileStore
  @Environment(\.dismiss) private var dismiss

  @State private var selectedType: BackendType?
  @State private var serverURL = ""
  @State private var label = ""
  @State private var currencyCode = Locale.current.currency?.identifier ?? "AUD"
  @State private var financialYearStartMonth = 7

  private static let months: [(Int, String)] = {
    let formatter = DateFormatter()
    return (1...12).map { ($0, formatter.monthSymbols[$0 - 1]) }
  }()

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Button {
            selectedType = .cloudKit
          } label: {
            HStack {
              Label("iCloud", systemImage: "icloud")
              Spacer()
              if selectedType == .cloudKit {
                Image(systemName: "checkmark")
                  .foregroundStyle(.tint)
                  .accessibilityHidden(true)
              }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selectedType == .cloudKit ? .isSelected : [])

          Button {
            selectedType = .moolah
          } label: {
            HStack {
              Label("Moolah", systemImage: "cloud")
              Spacer()
              if selectedType == .moolah {
                Image(systemName: "checkmark")
                  .foregroundStyle(.tint)
                  .accessibilityHidden(true)
              }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selectedType == .moolah ? .isSelected : [])

          Button {
            selectedType = .remote
          } label: {
            HStack {
              Label("Custom Server", systemImage: "server.rack")
              Spacer()
              if selectedType == .remote {
                Image(systemName: "checkmark")
                  .foregroundStyle(.tint)
                  .accessibilityHidden(true)
              }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selectedType == .remote ? .isSelected : [])
        }

        if selectedType == .cloudKit {
          Section("Profile") {
            TextField("Name", text: $label)

            Picker("Currency", selection: $currencyCode) {
              ForEach(Locale.commonISOCurrencyCodes, id: \.self) { code in
                Text("\(code)").tag(code)
              }
            }

            Picker("Financial Year Starts", selection: $financialYearStartMonth) {
              ForEach(Self.months, id: \.0) { month, name in
                Text(name).tag(month)
              }
            }
          }
        }

        if selectedType == .remote {
          Section("Server") {
            TextField("Server URL", text: $serverURL)
              .autocorrectionDisabled()
              #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
              #endif
              .onChange(of: serverURL) {
                profileStore.clearValidationError()
              }

            TextField("Label (optional)", text: $label)
          }
        }

        if let error = profileStore.validationError {
          Section {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
              .accessibilityLabel("Error: \(error)")
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Add Profile")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            profileStore.clearValidationError()
            dismiss()
          }
        }

        ToolbarItem(placement: .confirmationAction) {
          if profileStore.isValidating {
            ProgressView()
              .controlSize(.small)
          } else {
            Button("Add") {
              Task { await save() }
            }
            .disabled(!canAdd)
          }
        }
      }
    }
  }

  private var canAdd: Bool {
    guard let type = selectedType else { return false }
    switch type {
    case .cloudKit:
      return !label.trimmingCharacters(in: .whitespaces).isEmpty
    case .moolah:
      return true
    case .remote:
      guard !serverURL.isEmpty else { return false }
      let urlString = serverURL.hasPrefix("http") ? serverURL : "https://\(serverURL)"
      return URL(string: urlString) != nil
    }
  }

  private func save() async {
    guard let type = selectedType else { return }

    let profile: Profile
    switch type {
    case .cloudKit:
      profile = Profile(
        label: label.trimmingCharacters(in: .whitespaces),
        backendType: .cloudKit,
        currencyCode: currencyCode,
        financialYearStartMonth: financialYearStartMonth
      )
    case .moolah:
      profile = Profile(label: "Moolah", backendType: .moolah)
    case .remote:
      let urlString = serverURL.hasPrefix("http") ? serverURL : "https://\(serverURL)"
      guard let url = URL(string: urlString) else { return }
      let profileLabel = label.isEmpty ? url.host() ?? "Custom Server" : label
      profile = Profile(label: profileLabel, backendType: .remote, serverURL: url)
    }

    if await profileStore.validateAndAddProfile(profile) {
      dismiss()
    }
  }
}
```

- [ ] **Step 2: Build**

Run: `just build-mac`

- [ ] **Step 3: Commit**

```bash
git add Features/Profiles/Views/ProfileFormView.swift
git commit -m "Add iCloud option to profile creation form"
```

---

### Task 24: Profile Deletion Confirmation

**Files:**
- Search for where profile deletion is triggered in the UI and add a confirmation dialog for iCloud profiles.

- [ ] **Step 1: Find the deletion UI**

Search for where `removeProfile` is called in the UI code. Add an alert for iCloud profiles:

```swift
.alert(
  "Delete \"\(profileToDelete?.label ?? "")\"?",
  isPresented: $showDeleteConfirmation
) {
  Button("Cancel", role: .cancel) {}
  Button("Delete", role: .destructive) {
    if let profile = profileToDelete {
      profileStore.removeProfile(profile.id)
    }
  }
} message: {
  Text("This will permanently delete all accounts, transactions, and other data in this profile across all your devices. This cannot be undone.")
}
```

The exact location and state management will depend on which view currently handles deletion. Find it and add the confirmation dialog for `.cloudKit` profiles only (remote profiles can keep their existing deletion behavior since they don't delete server data).

- [ ] **Step 2: Build and test manually**

Run: `just build-mac` then `just run-mac`
Verify: Creating an iCloud profile shows the form. Deleting it shows the confirmation.

- [ ] **Step 3: Commit**

```bash
git add <modified files>
git commit -m "Add deletion confirmation dialog for iCloud profiles"
```

---

### Task 25: Handle Active Profile Deleted on Another Device

**Files:**
- Verify the ProfileStore changes from Task 20 handle this case.

- [ ] **Step 1: Verify the logic**

In `ProfileStore.loadCloudProfiles()`, we already check if the active profile still exists after reloading:

```swift
if let activeProfileID, !profiles.contains(where: { $0.id == activeProfileID }) {
  self.activeProfileID = profiles.first?.id
  saveActiveProfile()
}
```

Verify that the views observing `profileStore.activeProfile` handle `nil` gracefully — they should navigate back to the profile picker. Check:
- `ProfileWindowView` (macOS)
- `ProfileRootView` (iOS)

If they already handle `activeProfile == nil` by showing the profile picker, no code changes needed. If not, add the handling.

- [ ] **Step 2: Build and run**

Run: `just test`

- [ ] **Step 3: Commit if any changes were needed**

---

### Task 26: iOS ProfileSession Wiring

**Files:**
- Check how iOS creates ProfileSession (without SessionManager)

- [ ] **Step 1: Verify iOS path**

On iOS, `ProfileRootView` creates `ProfileSession` directly. Find where this happens and ensure it passes the `modelContainer`. It likely gets the container from the environment (`.modelContainer(container)` in MoolahApp). Update the iOS code path to pass the container when creating ProfileSession:

```swift
// In whatever view creates the ProfileSession on iOS:
let session = ProfileSession(profile: profile, modelContainer: modelContainer)
```

The exact fix depends on how the iOS code gets the container. It may need to be passed via environment or stored as a property.

- [ ] **Step 2: Build for iOS**

Run: `just build-ios`

- [ ] **Step 3: Commit if changes needed**

---

### Task 27: ProfileSetupView — First-Run with iCloud Option

**Files:**
- Modify: `Features/Profiles/Views/ProfileSetupView.swift`

- [ ] **Step 1: Check if ProfileSetupView needs updating**

The first-run setup view (`ProfileSetupView.swift`) may have a different flow from `ProfileFormView`. Check if it needs an iCloud option too. If it currently only offers "Sign in to Moolah" and "Use a custom server", add an iCloud option at the top.

- [ ] **Step 2: Update if needed and build**

Run: `just build-mac`

- [ ] **Step 3: Commit**

```bash
git add Features/Profiles/Views/ProfileSetupView.swift
git commit -m "Add iCloud option to first-run profile setup"
```

---

### Task 28: Regenerate Xcode Project and Full Test Run

**Files:**
- Modify: `project.yml` (if not done in Task 19)

- [ ] **Step 1: Regenerate project**

Run: `just generate`

- [ ] **Step 2: Full test run**

Run: `just test`
Expected: All tests pass on both macOS and iOS.

- [ ] **Step 3: Check for warnings**

Use Xcode MCP: `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"`
Fix any warnings.

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "Regenerate Xcode project with CloudKit backend support"
```

---

### Task 29: Audit Moolah-Server Tests

**Files:**
- Read: `../moolah-server/` test files
- Modify: Various contract test files

- [ ] **Step 1: Review moolah-server tests**

Read the test files in `../moolah-server/src/` (or `tests/`) to identify edge cases tested there but not in the contract tests. Key areas:
- Transaction filtering edge cases
- Pagination boundary conditions
- Balance computation with transfers
- Earmark computed values
- Category deletion cascading
- Account soft-delete validation

- [ ] **Step 2: Add missing test scenarios**

Add any discovered edge cases to the contract test suites, with both InMemory and CloudKit backends as arguments.

- [ ] **Step 3: Run tests**

Run: `just test`

- [ ] **Step 4: Commit**

```bash
git add MoolahTests/
git commit -m "Add contract test cases from moolah-server test audit"
```
