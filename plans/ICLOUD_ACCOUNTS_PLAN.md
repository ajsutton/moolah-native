# iCloud Migration — Accounts

**Date:** 2026-04-08
**Component:** Accounts (read, balance computation, ordering)
**Parent plan:** [ICLOUD_MIGRATION_PLAN.md](./ICLOUD_MIGRATION_PLAN.md)

## Overview

Accounts are relatively simple in terms of CRUD (currently read-only via `AccountRepository`), but the key challenge is **balance computation**. The server computes account balances from the sum of transactions. In the iCloud backend, this must be done locally.

---

## Current Implementation

### AccountRepository Protocol (`Domain/Repositories/AccountRepository.swift`)
```swift
protocol AccountRepository: Sendable {
  func fetchAll() async throws -> [Account]
}
```

Currently read-only. The `NATIVE_APP_PLAN.md` Step 13 plans to add `create`, `update`, and `delete` methods.

### Account Domain Model (`Domain/Models/Account.swift`)
```swift
struct Account: Codable, Sendable, Identifiable, Hashable, Comparable {
  let id: UUID
  var name: String
  var type: AccountType        // bank, creditCard, asset, investment
  var balance: MonetaryAmount  // computed from transactions on server
  var position: Int            // sort order
  var isHidden: Bool
}
```

### Server Behavior
- `GET /api/accounts/` returns all accounts with pre-computed `balance`
- Balance = sum of all non-scheduled transaction amounts for that account
- For investments, server also returns `value` (latest market valuation); the DTO uses `value` if present, otherwise falls back to `balance`
- Sorted by `position` ascending

### AccountStore (`Features/Accounts/AccountStore.swift`)
- Loads accounts via `repository.fetchAll()`
- Provides computed properties: `currentAccounts`, `investmentAccounts`, `currentTotal`, `investmentTotal`, `netWorth`
- `applyTransactionDelta(old:new:)` — optimistically adjusts balances locally when transactions change

### Balance Computation Logic (from AccountStore)
- Income: `accountId` balance += amount (amount is positive)
- Expense: `accountId` balance += amount (amount is negative)
- Transfer: `accountId` balance += amount (negative), `toAccountId` balance -= amount (positive effect)

---

## SwiftData Model

### File: `Backends/CloudKit/Models/AccountRecord.swift`

```swift
import Foundation
import SwiftData

@Model
final class AccountRecord {
  #Unique<AccountRecord>([\.id])

  @Attribute(.preserveValueOnDeletion)
  var id: UUID

  var profileId: UUID    // multi-profile scoping — all queries filter by this
  var name: String
  var type: String       // raw value: "bank", "cc", "asset", "investment"
  var position: Int
  var isHidden: Bool
  var currencyCode: String  // ISO currency code — initially from profile, future per-account currency

  init(id: UUID, profileId: UUID, name: String, type: String, position: Int, isHidden: Bool, currencyCode: String) {
    self.id = id
    self.profileId = profileId
    self.name = name
    self.type = type
    self.position = position
    self.isHidden = isHidden
    self.currencyCode = currencyCode
  }
}
```

### Key Decision: No Stored Balance

The `AccountRecord` does **not** store `balance`. Rationale:

| Option | Pros | Cons |
|--------|------|------|
| **A: Compute on fetch** | Always correct; no sync issues | Slower — requires transaction query per account |
| **B: Denormalized field** | Fast reads | Can become stale; sync conflicts; must update on every transaction change |

**Recommendation: Option A (compute on fetch)** for correctness, with caching optimization if needed.

- Balance is computed by summing `TransactionRecord` amounts where `accountId` or `toAccountId` matches
- Only non-scheduled transactions contribute to balance (`recurPeriod == nil`)
- This matches the server behavior exactly

---

## CloudKitAccountRepository

### File: `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift`

```swift
import Foundation
import SwiftData
import OSLog

@ModelActor
actor CloudKitAccountRepository: AccountRepository {
  private let logger = Logger(subsystem: "com.moolah.app", category: "CloudKitAccountRepo")
  private let profileId: UUID

  init(modelContainer: ModelContainer, profileId: UUID) {
    self.profileId = profileId
    // @ModelActor init
  }

  func fetchAll() async throws -> [Account] {
    let pid = profileId

    // 1. Fetch all account records for this profile, sorted by position
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate<AccountRecord> { $0.profileId == pid },
      sortBy: [SortDescriptor(\.position, order: .forward)]
    )
    let accountRecords = try modelContext.fetch(descriptor)

    // 2. Fetch all non-scheduled transactions for this profile for balance computation
    let txnDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate<TransactionRecord> { $0.profileId == pid && $0.recurPeriod == nil }
    )
    let transactions = try modelContext.fetch(txnDescriptor)

    // 3. Pre-compute balances by account ID
    var balances: [UUID: Int] = [:]
    for txn in transactions {
      if let accountId = txn.accountId {
        balances[accountId, default: 0] += txn.amount
      }
      if let toAccountId = txn.toAccountId {
        // Transfers: the amount on the transaction is negative (debit from source).
        // The destination receives the negated amount (credit).
        balances[toAccountId, default: 0] -= txn.amount
      }
    }

    // 4. Map to domain models with computed balances
    // Currency is read from each record (future: per-account currency)
    return accountRecords.map { record in
      let balanceCents = balances[record.id] ?? 0
      let currency = Currency.from(code: record.currencyCode)
      return Account(
        id: record.id,
        name: record.name,
        type: AccountType(rawValue: record.type) ?? .asset,
        balance: MonetaryAmount(cents: balanceCents, currency: currency),
        position: record.position,
        isHidden: record.isHidden
      )
    }
  }
}
```

### Balance Computation Detail

The balance calculation must match the server precisely. Based on the `AccountStore.applyTransactionDelta` logic:

| Transaction Type | accountId Effect | toAccountId Effect |
|-----------------|-----------------|-------------------|
| Income | `+= amount` (positive) | N/A |
| Expense | `+= amount` (negative) | N/A |
| Transfer | `+= amount` (negative, debit) | `-= amount` (positive, credit) |

The key insight: the `amount` field on a transaction already has the correct sign for the `accountId`. For `toAccountId` (transfer destination), negate the amount.

### Excluding Scheduled Transactions

Only non-scheduled transactions (where `recurPeriod == nil`) contribute to the actual balance. Scheduled transactions are future/projected and should not affect the current balance. The predicate `$0.recurPeriod == nil` handles this.

---

## Future CRUD Operations

When Step 13 of `NATIVE_APP_PLAN.md` adds account management, the repository protocol will grow:

```swift
protocol AccountRepository: Sendable {
  func fetchAll() async throws -> [Account]
  func create(_ account: Account) async throws -> Account
  func update(_ account: Account) async throws -> Account
  func delete(id: UUID) async throws
}
```

The CloudKit implementation is straightforward:

```swift
func create(_ account: Account) async throws -> Account {
  let record = AccountRecord(
    id: account.id,
    name: account.name,
    type: account.type.rawValue,
    position: account.position,
    isHidden: account.isHidden
  )
  modelContext.insert(record)
  try modelContext.save()
  return account  // balance will be 0 for new accounts
}

func update(_ account: Account) async throws -> Account {
  let id = account.id
  let descriptor = FetchDescriptor<AccountRecord>(
    predicate: #Predicate { $0.id == id }
  )
  guard let record = try modelContext.fetch(descriptor).first else {
    throw BackendError.serverError(404)
  }
  record.name = account.name
  record.type = account.type.rawValue
  record.position = account.position
  record.isHidden = account.isHidden
  try modelContext.save()
  return account
}

func delete(id: UUID) async throws {
  let descriptor = FetchDescriptor<AccountRecord>(
    predicate: #Predicate { $0.id == id }
  )
  guard let record = try modelContext.fetch(descriptor).first else {
    throw BackendError.serverError(404)
  }
  modelContext.delete(record)
  try modelContext.save()
}
```

---

## CloudKit Sync Considerations

### Conflict Resolution
- Account metadata (name, type, position, hidden) uses last-writer-wins
- This is acceptable — users rarely edit account properties simultaneously from multiple devices
- Balance is not stored, so there's no balance conflict

### Eventual Consistency
- If a transaction syncs before an account record, the balance computation will include a transaction for a non-existent account — this is harmless (the balance entry is computed but no account displays it)
- If an account syncs before its transactions, the account will show balance = 0 until transactions arrive — this is temporary and self-correcting

### Position Reordering
- If two devices reorder accounts simultaneously, last-writer-wins applies to each account's `position` field independently
- This could result in duplicate positions — the sort is stable so no crash, but order may be surprising
- Low-risk: simultaneous reordering from two devices is extremely unlikely for a single-user app

---

## Performance Considerations

### Balance Computation Cost
- Fetching ALL non-scheduled transactions on every `fetchAll()` is O(n) where n = total transaction count
- For 10,000 transactions, this is a scan of ~10,000 records + integer summation — fast on modern hardware
- SwiftData keeps an in-memory cache, so repeated fetches are fast

### Optimization Strategies (if needed)
1. **Cached balances:** Compute balances once on app launch, then update incrementally via `applyTransactionDelta()` (already done in `AccountStore`)
2. **Denormalized balance field:** Store balance on `AccountRecord`, update on transaction changes. Adds complexity but eliminates the full-table scan.
3. **Background computation:** Compute balances off the main actor, update UI when ready.

**Recommendation:** Start with the simple approach. The `AccountStore` already caches balances and updates them incrementally — the full computation only happens on `load()` (app launch / pull-to-refresh).

---

## Domain Model Mapping

### AccountRecord → Account
```swift
extension AccountRecord {
  func toDomain(balanceCents: Int) -> Account {
    let currency = Currency.from(code: currencyCode)
    return Account(
      id: id,
      name: name,
      type: AccountType(rawValue: type) ?? .asset,
      balance: MonetaryAmount(cents: balanceCents, currency: currency),
      position: position,
      isHidden: isHidden
    )
  }
}
```

### Account → AccountRecord
```swift
extension AccountRecord {
  convenience init(from domain: Account, profileId: UUID) {
    self.init(
      id: domain.id,
      profileId: profileId,
      name: domain.name,
      type: domain.type.rawValue,
      position: domain.position,
      isHidden: domain.isHidden,
      currencyCode: domain.balance.currency.code
    )
  }
}
```

---

## Testing Strategy

### Contract Tests
Run existing contract tests against `CloudKitAccountRepository` with an in-memory `ModelContainer`:

```swift
@Suite("CloudKitAccountRepository contract")
struct CloudKitAccountRepositoryContractTests {
  private func makeRepository() throws -> (
    CloudKitAccountRepository, ModelContainer
  ) {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: AccountRecord.self, TransactionRecord.self,
      configurations: config
    )
    return (CloudKitAccountRepository(modelContainer: container), container)
  }

  @Test("fetches accounts sorted by position")
  func fetchSortedByPosition() async throws { ... }

  @Test("computes balance from transactions")
  func computesBalance() async throws { ... }

  @Test("excludes scheduled transactions from balance")
  func excludesScheduledFromBalance() async throws { ... }

  @Test("transfer affects both accounts")
  func transferAffectsBothAccounts() async throws { ... }
}
```

### Specific Test Cases
1. Empty accounts list returns `[]`
2. Accounts sorted by position ascending
3. Balance computed correctly for income, expense, and transfer transactions
4. Scheduled transactions excluded from balance
5. Account with no transactions has balance = 0
6. Transfer transaction affects both source and destination balances
7. Hidden accounts are still returned (UI filters them)

---

## Files to Create

| File | Purpose |
|------|---------|
| `Backends/CloudKit/Models/AccountRecord.swift` | SwiftData `@Model` |
| `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift` | Repository implementation |
| `MoolahTests/Backends/CloudKitAccountRepositoryTests.swift` | Contract + balance tests |

---

## Estimated Effort

| Task | Estimate |
|------|----------|
| `AccountRecord` model | 30 minutes |
| Domain ↔ Record mapping | 30 minutes |
| `fetchAll()` with balance computation | 2 hours |
| Future CRUD stubs | 1 hour |
| Tests | 2 hours |
| **Total** | **~6 hours** |
