# Transaction Edit UUID Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix transaction editing bug where uppercase UUID strings corrupt field references, causing the web UI to display edited transactions as earmark-only.

**Architecture:** Create a `ServerUUID` Codable type that always serializes to lowercase. Replace raw `String` ID fields in all DTOs with `ServerUUID`, and replace all `.uuidString` usage in repository URL paths with a `UUID.apiString` extension. Add a transaction update contract test to catch field-preservation bugs.

**Tech Stack:** Swift 6, Foundation, Swift Testing

---

## Root Cause

Swift's `UUID.uuidString` produces uppercase strings (e.g., `"E621E1F8-..."`). The moolah-server generates lowercase UUIDs. When moolah-native sends a PUT to update a transaction, it overwrites lowercase IDs in the database with uppercase ones.

The web UI's `EditTransaction.vue` (line 142-143) looks up the account via `accountById(transaction.accountId)`, which calls `accountsStore.account` — a case-sensitive `find()` comparing `account.id === accountId`. The uppercase `accountId` from the edited transaction doesn't match the lowercase account ID in the store, so the lookup returns `undefined`. This makes `isEarmarkAccount` (line 139-141) return `true`, causing the edit panel to show only earmark fields and hiding the normal transaction fields.

Some repositories already call `.uuidString.lowercased()` (accounts, investments, some earmark paths), but transactions, categories, and query parameters do not — the fix is inconsistent. A dedicated type prevents this class of bug permanently.

## File Map

| Action | File | Purpose |
|--------|------|---------|
| Create | `Backends/Remote/DTOs/ServerUUID.swift` | Codable UUID wrapper, always lowercase |
| Create | `MoolahTests/Backends/Remote/ServerUUIDTests.swift` | Unit tests for encoding/decoding |
| Modify | `Backends/Remote/DTOs/TransactionDTO.swift` | Use `ServerUUID` for all ID fields |
| Modify | `Backends/Remote/DTOs/CategoryDTO.swift` | Use `ServerUUID` for ID fields |
| Modify | `Backends/Remote/DTOs/EarmarkDTO.swift` | Use `ServerUUID` for ID field |
| Modify | `Backends/Remote/DTOs/ExpenseBreakdownDTO.swift` | Use `ServerUUID` if it has ID fields |
| Modify | `Backends/Remote/DTOs/FlexibleUUID.swift` | Keep but ServerUUID uses it internally |
| Modify | `Backends/Remote/Repositories/RemoteTransactionRepository.swift` | Use `.apiString` for URL paths and query params |
| Modify | `Backends/Remote/Repositories/RemoteCategoryRepository.swift` | Use `.apiString` for URL paths and query params |
| Modify | `Backends/Remote/Repositories/RemoteEarmarkRepository.swift` | Use `.apiString` consistently (some already lowercased) |
| Modify | `Backends/Remote/Repositories/RemoteAccountRepository.swift` | Replace `.uuidString.lowercased()` with `.apiString` |
| Modify | `Backends/Remote/Repositories/RemoteInvestmentRepository.swift` | Replace `.uuidString.lowercased()` with `.apiString` |
| Modify | `Backends/Remote/Repositories/RemoteAnalysisRepository.swift` | Use `.apiString` for query params |
| Create | `MoolahTests/Domain/TransactionUpdateContractTests.swift` | Contract test verifying update preserves all fields |
| Modify | `project.yml` | Add new files to Moolah_iOS, Moolah_macOS, and test targets |

---

### Task 1: Create ServerUUID Type and UUID Extension

**Files:**
- Create: `Backends/Remote/DTOs/ServerUUID.swift`

- [ ] **Step 1: Create ServerUUID.swift**

```swift
import Foundation

/// A UUID wrapper that always serializes to lowercase strings for server communication.
/// Use this for all ID fields in DTOs to prevent case-mismatch bugs between
/// Swift (uppercase) and the server (lowercase).
struct ServerUUID: Codable, Hashable, Sendable {
  let uuid: UUID

  init(_ uuid: UUID) {
    self.uuid = uuid
  }

  var uuidString: String {
    uuid.uuidString.lowercased()
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(uuidString)
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let string = try container.decode(String.self)
    guard let parsed = FlexibleUUID.parse(string) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid UUID string: \(string)"
      )
    }
    self.uuid = parsed
  }
}

extension UUID {
  /// Lowercase UUID string for server API communication.
  /// Use this instead of `uuidString` when constructing URL paths or query parameters.
  var apiString: String {
    uuidString.lowercased()
  }
}
```

- [ ] **Step 2: Add ServerUUID.swift to project.yml**

Add `Backends/Remote/DTOs/ServerUUID.swift` to the sources. Since `Backends/` is already a source directory for both targets, no `project.yml` change is needed — the file is auto-included. Verify by running:

```bash
just generate
```

---

### Task 2: Write ServerUUID Tests

**Files:**
- Create: `MoolahTests/Backends/Remote/ServerUUIDTests.swift`

- [ ] **Step 1: Write tests for encoding, decoding, and round-trip**

```swift
import Foundation
import Testing

@testable import Moolah

struct ServerUUIDTests {
  let testUUID = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

  @Test func encodesToLowercaseJSON() throws {
    let serverUUID = ServerUUID(testUUID)
    let data = try JSONEncoder().encode(serverUUID)
    let json = String(data: data, encoding: .utf8)!
    #expect(json == "\"e621e1f8-c36c-495a-93fc-0c247a3e6e5f\"")
  }

  @Test func uuidStringIsLowercase() {
    let serverUUID = ServerUUID(testUUID)
    #expect(serverUUID.uuidString == "e621e1f8-c36c-495a-93fc-0c247a3e6e5f")
  }

  @Test func decodesLowercaseUUID() throws {
    let json = "\"e621e1f8-c36c-495a-93fc-0c247a3e6e5f\""
    let data = json.data(using: .utf8)!
    let result = try JSONDecoder().decode(ServerUUID.self, from: data)
    #expect(result.uuid == testUUID)
  }

  @Test func decodesUppercaseUUID() throws {
    let json = "\"E621E1F8-C36C-495A-93FC-0C247A3E6E5F\""
    let data = json.data(using: .utf8)!
    let result = try JSONDecoder().decode(ServerUUID.self, from: data)
    #expect(result.uuid == testUUID)
  }

  @Test func decodesUnhyphenatedUUID() throws {
    let json = "\"e621e1f8c36c495a93fc0c247a3e6e5f\""
    let data = json.data(using: .utf8)!
    let result = try JSONDecoder().decode(ServerUUID.self, from: data)
    #expect(result.uuid == testUUID)
  }

  @Test func roundTripPreservesUUID() throws {
    let original = ServerUUID(testUUID)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ServerUUID.self, from: data)
    #expect(decoded.uuid == original.uuid)
  }

  @Test func optionalNullDecodesAsNil() throws {
    let json = "null"
    let data = json.data(using: .utf8)!
    let result = try JSONDecoder().decode(ServerUUID?.self, from: data)
    #expect(result == nil)
  }

  @Test func apiStringExtensionIsLowercase() {
    let uuid = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
    #expect(uuid.apiString == "e621e1f8-c36c-495a-93fc-0c247a3e6e5f")
  }
}
```

- [ ] **Step 2: Run tests to verify they pass**

```bash
just test
```

- [ ] **Step 3: Commit**

```bash
git add Backends/Remote/DTOs/ServerUUID.swift MoolahTests/Backends/Remote/ServerUUIDTests.swift
git commit -m "feat: add ServerUUID type for lowercase UUID encoding"
```

---

### Task 3: Update TransactionDTO to Use ServerUUID

**Files:**
- Modify: `Backends/Remote/DTOs/TransactionDTO.swift`

- [ ] **Step 1: Replace String ID fields with ServerUUID in TransactionDTO**

Change the struct fields and update `fromDomain()` and `toDomain()`:

```swift
struct TransactionDTO: Codable {
  let id: ServerUUID
  let type: String
  let date: String  // "YYYY-MM-DD"
  let accountId: ServerUUID?
  let toAccountId: ServerUUID?
  let amount: Int
  let payee: String?
  let notes: String?
  let categoryId: ServerUUID?
  let earmark: ServerUUID?  // Server uses "earmark", domain uses "earmarkId"
  let recurPeriod: String?
  let recurEvery: Int?

  func toDomain(currency: Currency) -> Transaction {
    let parsedDate = BackendDateFormatter.date(from: date) ?? Date()

    return Transaction(
      id: id.uuid,
      type: TransactionType(rawValue: type) ?? .expense,
      date: parsedDate,
      accountId: accountId?.uuid,
      toAccountId: toAccountId?.uuid,
      amount: MonetaryAmount(cents: amount, currency: currency),
      payee: payee,
      notes: notes,
      categoryId: categoryId?.uuid,
      earmarkId: earmark?.uuid,
      recurPeriod: recurPeriod.flatMap { RecurPeriod(rawValue: $0) },
      recurEvery: recurEvery
    )
  }

  static func fromDomain(_ transaction: Transaction) -> TransactionDTO {
    let dateString = BackendDateFormatter.string(from: transaction.date)
    return TransactionDTO(
      id: ServerUUID(transaction.id),
      type: transaction.type.rawValue,
      date: dateString,
      accountId: transaction.accountId.map(ServerUUID.init),
      toAccountId: transaction.toAccountId.map(ServerUUID.init),
      amount: transaction.amount.cents,
      payee: transaction.payee,
      notes: transaction.notes,
      categoryId: transaction.categoryId.map(ServerUUID.init),
      earmark: transaction.earmarkId.map(ServerUUID.init),
      recurPeriod: transaction.recurPeriod?.rawValue,
      recurEvery: transaction.recurEvery
    )
  }

  struct ListWrapper: Codable {
    let transactions: [TransactionDTO]
    let hasMore: Bool
    let priorBalance: Int
    let totalNumberOfTransactions: Int
  }
}
```

- [ ] **Step 2: Update CreateTransactionDTO the same way**

```swift
struct CreateTransactionDTO: Codable {
  let type: String
  let date: String  // "YYYY-MM-DD"
  let accountId: ServerUUID?
  let toAccountId: ServerUUID?
  let amount: Int
  let payee: String?
  let notes: String?
  let categoryId: ServerUUID?
  let earmark: ServerUUID?
  let recurPeriod: String?
  let recurEvery: Int?

  static func fromDomain(_ transaction: Transaction) -> CreateTransactionDTO {
    let dateString = BackendDateFormatter.string(from: transaction.date)
    return CreateTransactionDTO(
      type: transaction.type.rawValue,
      date: dateString,
      accountId: transaction.accountId.map(ServerUUID.init),
      toAccountId: transaction.toAccountId.map(ServerUUID.init),
      amount: transaction.amount.cents,
      payee: transaction.payee,
      notes: transaction.notes,
      categoryId: transaction.categoryId.map(ServerUUID.init),
      earmark: transaction.earmarkId.map(ServerUUID.init),
      recurPeriod: transaction.recurPeriod?.rawValue,
      recurEvery: transaction.recurEvery
    )
  }
}
```

- [ ] **Step 3: Build to verify compilation**

```bash
just build-mac
```

- [ ] **Step 4: Run tests**

```bash
just test
```

- [ ] **Step 5: Commit**

```bash
git add Backends/Remote/DTOs/TransactionDTO.swift
git commit -m "fix: use ServerUUID in TransactionDTO to prevent uppercase UUID corruption"
```

---

### Task 4: Update CategoryDTO and EarmarkDTO

**Files:**
- Modify: `Backends/Remote/DTOs/CategoryDTO.swift`
- Modify: `Backends/Remote/DTOs/EarmarkDTO.swift`

- [ ] **Step 1: Read CategoryDTO.swift and EarmarkDTO.swift**

Read both files to see current field types and `fromDomain()`/`toDomain()` methods.

- [ ] **Step 2: Update CategoryDTO**

Replace `String` ID fields with `ServerUUID`:
- `id` field: `String` → `ServerUUID`
- `parentId` field: `String?` → `ServerUUID?`
- Update `fromDomain()`: use `ServerUUID(category.id)` and `category.parentId.map(ServerUUID.init)`
- Update `toDomain()`: use `id.uuid` and `parentId?.uuid`

- [ ] **Step 3: Update EarmarkDTO**

Replace `String` ID field with `ServerUUID`:
- `id` field: `String` → `ServerUUID`
- Update `fromDomain()`: use `ServerUUID(earmark.id)`
- Update `toDomain()`: use `id.uuid`

- [ ] **Step 4: Check ExpenseBreakdownDTO for any ID fields**

Read `Backends/Remote/DTOs/ExpenseBreakdownDTO.swift` and update any UUID string fields to use `ServerUUID`.

- [ ] **Step 5: Build and test**

```bash
just build-mac && just test
```

- [ ] **Step 6: Commit**

```bash
git add Backends/Remote/DTOs/CategoryDTO.swift Backends/Remote/DTOs/EarmarkDTO.swift
git commit -m "fix: use ServerUUID in CategoryDTO and EarmarkDTO"
```

---

### Task 5: Update Repository URL Paths and Query Parameters

**Files:**
- Modify: `Backends/Remote/Repositories/RemoteTransactionRepository.swift`
- Modify: `Backends/Remote/Repositories/RemoteCategoryRepository.swift`
- Modify: `Backends/Remote/Repositories/RemoteEarmarkRepository.swift`
- Modify: `Backends/Remote/Repositories/RemoteAccountRepository.swift`
- Modify: `Backends/Remote/Repositories/RemoteInvestmentRepository.swift`
- Modify: `Backends/Remote/Repositories/RemoteAnalysisRepository.swift`

Replace every `.uuidString` and `.uuidString.lowercased()` call with `.apiString`.

- [ ] **Step 1: Update RemoteTransactionRepository.swift**

Five occurrences to change:
- Line 21: `accountId.uuidString` → `accountId.apiString`
- Line 25: `earmarkId.uuidString` → `earmarkId.apiString`
- Line 43: `categoryId.uuidString` → `categoryId.apiString`
- Line 76: `transaction.id.uuidString` → `transaction.id.apiString`
- Line 82: `id.uuidString` → `id.apiString`

- [ ] **Step 2: Update RemoteCategoryRepository.swift**

Three occurrences to change:
- Line 34: `category.id.uuidString` → `category.id.apiString`
- Line 42: `replacementId.uuidString` → `replacementId.apiString`
- Line 44: `id.uuidString` → `id.apiString`

- [ ] **Step 3: Update RemoteEarmarkRepository.swift**

Replace all `.uuidString` and `.uuidString.lowercased()` with `.apiString`:
- Line 36: `earmark.id.uuidString` → `earmark.id.apiString`
- Line 42: `earmarkId.uuidString.lowercased()` → `earmarkId.apiString`
- Line 64: `earmarkId.uuidString.lowercased()` → `earmarkId.apiString`
- Line 64: `categoryId.uuidString.lowercased()` → `categoryId.apiString`

- [ ] **Step 4: Update RemoteAccountRepository.swift**

Replace `.uuidString.lowercased()` with `.apiString`:
- Line 84: `account.id.uuidString.lowercased()` → `account.id.apiString`
- Line 91: `account.id.uuidString.lowercased()` → `account.id.apiString`

- [ ] **Step 5: Update RemoteInvestmentRepository.swift**

Replace `.uuidString.lowercased()` with `.apiString`:
- Line 20: `accountId.uuidString.lowercased()` → `accountId.apiString`
- Line 32: `accountId.uuidString.lowercased()` → `accountId.apiString`
- Line 38: `accountId.uuidString.lowercased()` → `accountId.apiString`
- Line 43: `accountId.uuidString.lowercased()` → `accountId.apiString`

- [ ] **Step 6: Update RemoteAnalysisRepository.swift**

Three occurrences:
- Line 82: `accountId.uuidString` → `accountId.apiString`
- Line 85: `earmarkId.uuidString` → `earmarkId.apiString`
- Line 90: `$0.uuidString` → `$0.apiString`

- [ ] **Step 7: Search for any remaining `.uuidString` usage in the Remote backend**

```bash
grep -rn '\.uuidString' Backends/Remote/
```

The only remaining usage should be in `FlexibleUUID.swift` (which uses `UUID(uuidString:)` for parsing, not encoding). If any other `.uuidString` calls remain, replace them with `.apiString`.

- [ ] **Step 8: Build and test**

```bash
just build-mac && just test
```

- [ ] **Step 9: Commit**

```bash
git add Backends/Remote/Repositories/
git commit -m "fix: use UUID.apiString consistently in all repository URL paths"
```

---

### Task 6: Add Transaction Update Contract Test

There is currently no contract test verifying that `update()` preserves all transaction fields. Add one.

**Files:**
- Modify: `MoolahTests/Domain/TransactionRepositoryContractTests.swift`

- [ ] **Step 1: Read the existing contract test file**

Read `MoolahTests/Domain/TransactionRepositoryContractTests.swift` to understand the test pattern, helper methods, and how the repository is created.

- [ ] **Step 2: Add a test that verifies update preserves all fields**

Add a test method that:
1. Creates a transaction with ALL optional fields populated (accountId, toAccountId, categoryId, earmarkId, payee, notes, recurPeriod, recurEvery)
2. Creates it via the repository
3. Modifies one field (e.g., payee)
4. Calls `update()`
5. Fetches the transaction back
6. Asserts ALL fields match the updated transaction — not just the modified field

```swift
@Test func updatePreservesAllFields() async throws {
  let accountId = UUID()
  let toAccountId = UUID()
  let categoryId = UUID()
  let earmarkId = UUID()

  let original = Transaction(
    type: .transfer,
    date: makeDate("2024-06-15"),
    accountId: accountId,
    toAccountId: toAccountId,
    amount: MonetaryAmount(cents: -5000, currency: Currency.defaultTestCurrency),
    payee: "Original Payee",
    notes: "Some notes",
    categoryId: categoryId,
    earmarkId: earmarkId,
    recurPeriod: .month,
    recurEvery: 2
  )

  let created = try await repository.create(original)

  var modified = created
  modified.payee = "Updated Payee"
  let updated = try await repository.update(modified)

  // Verify the modified field changed
  #expect(updated.payee == "Updated Payee")

  // Verify all other fields are preserved
  #expect(updated.id == created.id)
  #expect(updated.type == .transfer)
  #expect(updated.accountId == accountId)
  #expect(updated.toAccountId == toAccountId)
  #expect(updated.amount.cents == -5000)
  #expect(updated.notes == "Some notes")
  #expect(updated.categoryId == categoryId)
  #expect(updated.earmarkId == earmarkId)
  #expect(updated.recurPeriod == .month)
  #expect(updated.recurEvery == 2)

  // Fetch back and verify persistence
  let page = try await repository.fetch(
    filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 10)
  let fetched = page.transactions.first { $0.id == created.id }
  #expect(fetched != nil)
  #expect(fetched?.payee == "Updated Payee")
  #expect(fetched?.earmarkId == earmarkId)
  #expect(fetched?.categoryId == categoryId)
  #expect(fetched?.notes == "Some notes")
}
```

Note: Adapt this to match the existing test patterns in the file (how `repository` is provided, how `makeDate` works, etc.). The test must run against both `InMemoryBackend` and (via fixture stubs) `RemoteBackend`.

- [ ] **Step 3: Run the test**

```bash
just test
```

- [ ] **Step 4: Commit**

```bash
git add MoolahTests/Domain/TransactionRepositoryContractTests.swift
git commit -m "test: add contract test verifying update preserves all transaction fields"
```

---

### Task 7: Verify No Remaining Uppercase UUID Usage

- [ ] **Step 1: Search entire Remote backend for raw `.uuidString` usage**

```bash
grep -rn '\.uuidString' Backends/Remote/
```

Only acceptable remaining usage: `UUID(uuidString:)` calls in `FlexibleUUID.swift` (these are for parsing, not encoding).

- [ ] **Step 2: Search for any `.lowercased()` that should now be `.apiString`**

```bash
grep -rn 'uuidString.lowercased' Backends/
```

Should return zero results — all have been replaced by `.apiString`.

- [ ] **Step 3: Run full test suite one final time**

```bash
just test
```

- [ ] **Step 4: Final commit if any cleanup was needed**
