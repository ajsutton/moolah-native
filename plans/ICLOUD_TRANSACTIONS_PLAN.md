# iCloud Migration — Transactions

**Date:** 2026-04-08
**Component:** Transactions (CRUD, filtering, pagination, balance computation)
**Parent plan:** [ICLOUD_MIGRATION_PLAN.md](./ICLOUD_MIGRATION_PLAN.md)

## Overview

Transactions are the most complex component of the migration. The server currently handles paginated queries with multi-field filtering, sort ordering, `priorBalance` computation, and payee suggestions — all of which must be reimplemented locally using SwiftData queries.

---

## Current Implementation

### TransactionRepository Protocol (`Domain/Repositories/TransactionRepository.swift`)
```swift
protocol TransactionRepository: Sendable {
  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage
  func create(_ transaction: Transaction) async throws -> Transaction
  func update(_ transaction: Transaction) async throws -> Transaction
  func delete(id: UUID) async throws
  func fetchPayeeSuggestions(prefix: String) async throws -> [String]
}
```

### TransactionFilter (`Domain/Models/Transaction.swift`)
```swift
struct TransactionFilter: Sendable, Equatable {
  var accountId: UUID?
  var earmarkId: UUID?
  var scheduled: Bool?
  var dateRange: ClosedRange<Date>?
  var categoryIds: Set<UUID>?
  var payee: String?
}
```

### TransactionPage
```swift
struct TransactionPage: Sendable {
  let transactions: [Transaction]
  let priorBalance: MonetaryAmount  // balance before the oldest txn in this page
}
```

### Server Behavior (from InMemoryTransactionRepository)
- **Account filter:** matches `accountId == X` OR `toAccountId == X` (transfers appear in both accounts)
- **Earmark filter:** matches `earmarkId == X`
- **Scheduled filter:** `true` = `recurPeriod != nil`, `false` = `recurPeriod == nil`
- **Date range:** inclusive on both ends
- **Category filter:** OR logic — transaction matches ANY of the category IDs
- **Payee filter:** case-insensitive substring match
- **All filters combine with AND logic**
- **Sort:** date DESC, then id ASC (stable ordering)
- **Pagination:** offset-based (`page * pageSize`)
- **priorBalance:** sum of all transaction amounts AFTER the current page (older transactions)

---

## SwiftData Model

### File: `Backends/CloudKit/Models/TransactionRecord.swift`

```swift
import Foundation
import SwiftData

@Model
final class TransactionRecord {
  #Unique<TransactionRecord>([\.id])

  @Attribute(.preserveValueOnDeletion)
  var id: UUID

  var type: String          // "income", "expense", "transfer"
  var date: Date
  var accountId: UUID?
  var toAccountId: UUID?
  var amount: Int           // cents
  var payee: String?
  var notes: String?
  var categoryId: UUID?
  var earmarkId: UUID?
  var recurPeriod: String?  // "ONCE", "DAY", "WEEK", "MONTH", "YEAR"
  var recurEvery: Int?

  // Denormalized lowercase payee for case-insensitive search
  var payeeLower: String?

  init(
    id: UUID,
    type: String,
    date: Date,
    accountId: UUID? = nil,
    toAccountId: UUID? = nil,
    amount: Int,
    payee: String? = nil,
    notes: String? = nil,
    categoryId: UUID? = nil,
    earmarkId: UUID? = nil,
    recurPeriod: String? = nil,
    recurEvery: Int? = nil
  ) {
    self.id = id
    self.type = type
    self.date = date
    self.accountId = accountId
    self.toAccountId = toAccountId
    self.amount = amount
    self.payee = payee
    self.notes = notes
    self.categoryId = categoryId
    self.earmarkId = earmarkId
    self.recurPeriod = recurPeriod
    self.recurEvery = recurEvery
    self.payeeLower = payee?.lowercased()
  }
}
```

### Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Store `type` as `String` | Yes | CloudKit doesn't support custom enums; raw values work |
| Store `recurPeriod` as `String?` | Yes | Same reason; map to `RecurPeriod` enum in domain layer |
| Store `amount` as `Int` | Yes | Cents, matches domain model |
| Denormalized `payeeLower` | Yes | SwiftData `#Predicate` doesn't support `.lowercased()` calls |
| No SwiftData relationships | Yes | Use UUID foreign keys; relationships complicate CloudKit sync |
| `@Attribute(.preserveValueOnDeletion)` on `id` | Yes | Helps CloudKit tombstone tracking |

---

## CloudKitTransactionRepository

### File: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift`

### Filtering Strategy

SwiftData `#Predicate` with CloudKit has significant limitations:
- No `.lowercased()` or `.localizedCaseInsensitiveContains()` in predicates
- No OR logic across different fields in a single predicate
- Limited compound predicate support
- No aggregate functions in predicates

**Approach: Build predicate dynamically + post-filter for unsupported operations.**

```swift
@ModelActor
actor CloudKitTransactionRepository: TransactionRepository {
  func fetch(
    filter: TransactionFilter, page: Int, pageSize: Int
  ) async throws -> TransactionPage {

    // Phase 1: SwiftData predicate for filters it CAN handle
    var descriptor = FetchDescriptor<TransactionRecord>(
      sortBy: [
        SortDescriptor(\.date, order: .reverse),
        SortDescriptor(\.id, order: .forward)
      ]
    )

    // Phase 2: Fetch all matching, then post-filter for complex conditions
    let allRecords = try modelContext.fetch(descriptor)
    let filtered = applyFilters(allRecords, filter: filter)

    // Phase 3: Paginate
    let offset = page * pageSize
    guard offset < filtered.count else {
      return TransactionPage(transactions: [], priorBalance: .zero)
    }
    let end = min(offset + pageSize, filtered.count)
    let pageRecords = Array(filtered[offset..<end])

    // Phase 4: Compute priorBalance (sum of transactions after this page)
    let priorCents = filtered[end...].reduce(0) { $0 + $1.amount }
    let priorBalance = MonetaryAmount(cents: priorCents, currency: .defaultCurrency)

    // Phase 5: Map to domain models
    let transactions = pageRecords.map { $0.toDomain() }
    return TransactionPage(transactions: transactions, priorBalance: priorBalance)
  }
}
```

### Filter Implementation

Because SwiftData predicates have limited expressiveness (especially with CloudKit), the safest approach is predicate for simple filters + in-memory post-filtering for complex ones:

```swift
private func applyFilters(
  _ records: [TransactionRecord],
  filter: TransactionFilter
) -> [TransactionRecord] {
  var result = records

  // Account filter: matches accountId OR toAccountId
  if let accountId = filter.accountId {
    result = result.filter { $0.accountId == accountId || $0.toAccountId == accountId }
  }

  // Earmark filter
  if let earmarkId = filter.earmarkId {
    result = result.filter { $0.earmarkId == earmarkId }
  }

  // Scheduled filter
  if let scheduled = filter.scheduled {
    result = result.filter { ($0.recurPeriod != nil) == scheduled }
  }

  // Date range filter
  if let dateRange = filter.dateRange {
    result = result.filter { dateRange.contains($0.date) }
  }

  // Category filter (OR logic across multiple categories)
  if let categoryIds = filter.categoryIds, !categoryIds.isEmpty {
    result = result.filter { record in
      guard let catId = record.categoryId else { return false }
      return categoryIds.contains(catId)
    }
  }

  // Payee filter (case-insensitive contains)
  if let payee = filter.payee, !payee.isEmpty {
    let lowered = payee.lowercased()
    result = result.filter { record in
      guard let p = record.payeeLower else { return false }
      return p.contains(lowered)
    }
  }

  return result
}
```

### Performance Optimization: Predicate Push-Down

For large datasets, loading all transactions into memory for filtering is expensive. As an optimization, push simple filters into the SwiftData predicate when possible:

```swift
// When only earmarkId filter is set (common case)
if let earmarkId = filter.earmarkId,
   filter.accountId == nil, filter.scheduled == nil,
   filter.dateRange == nil, filter.categoryIds == nil, filter.payee == nil {
  descriptor.predicate = #Predicate<TransactionRecord> { record in
    record.earmarkId == earmarkId
  }
}

// When only scheduled filter is set
if let scheduled = filter.scheduled,
   filter.accountId == nil, filter.earmarkId == nil,
   filter.dateRange == nil, filter.categoryIds == nil, filter.payee == nil {
  if scheduled {
    descriptor.predicate = #Predicate<TransactionRecord> { $0.recurPeriod != nil }
  } else {
    descriptor.predicate = #Predicate<TransactionRecord> { $0.recurPeriod == nil }
  }
}
```

A more complete optimization can build compound predicates for filter combinations that SwiftData supports. The post-filter approach is the safe fallback that guarantees correctness.

### CRUD Operations

```swift
func create(_ transaction: Transaction) async throws -> Transaction {
  let record = TransactionRecord(from: transaction)
  modelContext.insert(record)
  try modelContext.save()
  return transaction
}

func update(_ transaction: Transaction) async throws -> Transaction {
  let id = transaction.id
  let descriptor = FetchDescriptor<TransactionRecord>(
    predicate: #Predicate { $0.id == id }
  )
  guard let record = try modelContext.fetch(descriptor).first else {
    throw BackendError.serverError(404)
  }
  record.update(from: transaction)
  try modelContext.save()
  return transaction
}

func delete(id: UUID) async throws {
  let descriptor = FetchDescriptor<TransactionRecord>(
    predicate: #Predicate { $0.id == id }
  )
  guard let record = try modelContext.fetch(descriptor).first else {
    throw BackendError.serverError(404)
  }
  modelContext.delete(record)
  try modelContext.save()
}
```

### Payee Suggestions

```swift
func fetchPayeeSuggestions(prefix: String) async throws -> [String] {
  let lowered = prefix.lowercased()
  let descriptor = FetchDescriptor<TransactionRecord>()
  let records = try modelContext.fetch(descriptor)

  let payees = Set(
    records
      .compactMap(\.payee)
      .filter { !$0.isEmpty && $0.lowercased().hasPrefix(lowered) }
  )
  return payees.sorted()
}
```

**Optimization:** If performance is an issue, maintain a separate `PayeeRecord` model that stores distinct payees, updated on transaction create/update.

---

## Domain Model Mapping

### TransactionRecord → Transaction

```swift
extension TransactionRecord {
  func toDomain() -> Transaction {
    Transaction(
      id: id,
      type: TransactionType(rawValue: type) ?? .expense,
      date: date,
      accountId: accountId,
      toAccountId: toAccountId,
      amount: MonetaryAmount(cents: amount, currency: .defaultCurrency),
      payee: payee,
      notes: notes,
      categoryId: categoryId,
      earmarkId: earmarkId,
      recurPeriod: recurPeriod.flatMap { RecurPeriod(rawValue: $0) },
      recurEvery: recurEvery
    )
  }
}
```

### Transaction → TransactionRecord

```swift
extension TransactionRecord {
  convenience init(from domain: Transaction) {
    self.init(
      id: domain.id,
      type: domain.type.rawValue,
      date: domain.date,
      accountId: domain.accountId,
      toAccountId: domain.toAccountId,
      amount: domain.amount.cents,
      payee: domain.payee,
      notes: domain.notes,
      categoryId: domain.categoryId,
      earmarkId: domain.earmarkId,
      recurPeriod: domain.recurPeriod?.rawValue,
      recurEvery: domain.recurEvery
    )
  }

  func update(from domain: Transaction) {
    type = domain.type.rawValue
    date = domain.date
    accountId = domain.accountId
    toAccountId = domain.toAccountId
    amount = domain.amount.cents
    payee = domain.payee
    payeeLower = domain.payee?.lowercased()
    notes = domain.notes
    categoryId = domain.categoryId
    earmarkId = domain.earmarkId
    recurPeriod = domain.recurPeriod?.rawValue
    recurEvery = domain.recurEvery
  }
}
```

---

## priorBalance Computation

The `priorBalance` represents the sum of all transaction amounts that are older than the current page. This is used to compute running balances in the transaction list.

### Approach

After filtering and sorting, the transactions older than the current page are at indices `[end...]`. Sum their amounts:

```swift
let priorCents = filtered[end...].reduce(0) { $0 + $1.amount }
```

### Performance Note

For an account with 10,000 transactions viewing page 1 (50 items), this sums 9,950 values. This is O(n) but integer addition is fast. If it becomes a bottleneck:
- Cache cumulative balance per account
- Use a denormalized running balance field
- Compute incrementally on insert/delete

For now, the simple approach matches the InMemoryBackend exactly and is correct.

---

## Account Balance Computation

Account balances are not stored on the `AccountRecord` — they're computed by summing transactions. This query is needed by `CloudKitAccountRepository.fetchAll()`:

```swift
func computeBalance(for accountId: UUID) throws -> Int {
  let descriptor = FetchDescriptor<TransactionRecord>()
  let allTransactions = try modelContext.fetch(descriptor)

  return allTransactions
    .filter { $0.accountId == accountId || $0.toAccountId == accountId }
    .reduce(0) { sum, txn in
      if txn.accountId == accountId {
        return sum + txn.amount
      } else {
        // Transfer TO this account — amount is the transfer amount (positive)
        return sum + txn.amount
      }
    }
}
```

Note: The actual balance logic depends on the transaction type and whether this is the source or destination account. The exact semantics should match the server's computation. See the Accounts plan for details.

---

## SwiftData / CloudKit Limitations & Workarounds

### 1. Case-Insensitive String Matching
**Problem:** `#Predicate` doesn't support `.lowercased()` or `.localizedCaseInsensitiveContains()`
**Workaround:** Store denormalized `payeeLower` field, keep it in sync on create/update

### 2. OR Logic Across Fields
**Problem:** Account filter needs `accountId == X || toAccountId == X`
**Workaround:** Post-filter in memory after fetching. For the common case of filtering by one account, this is acceptable — most transactions don't match, so the filtered set is small.

### 3. Aggregate Queries
**Problem:** SwiftData doesn't support `SUM()`, `COUNT()`, or `DISTINCT` in predicates
**Workaround:** Fetch records and compute in memory. For balance computation, this is unavoidable with SwiftData.

### 4. Compound Predicates with Optional Fields
**Problem:** Predicates on optional fields can be tricky with CloudKit
**Workaround:** Use post-filtering for optional field comparisons

### 5. CloudKit Sync Latency
**Problem:** A transaction created on device A may not appear on device B immediately
**Workaround:** Accept eventual consistency. The UI should show local data immediately. CloudKit will sync in the background.

---

## Indexing Strategy

SwiftData automatically indexes `@Attribute` properties used in `#Predicate`. Ensure these fields are used in predicates to get automatic indexing:

| Field | Used In | Index Priority |
|-------|---------|---------------|
| `id` | Lookups, updates, deletes | High (unique constraint) |
| `date` | Date range filter, sorting | High |
| `accountId` | Account filter | High |
| `earmarkId` | Earmark filter | Medium |
| `recurPeriod` | Scheduled filter | Medium |
| `categoryId` | Category filter | Medium |
| `payeeLower` | Payee search | Low |

---

## Testing Strategy

### Contract Tests
The existing `TransactionRepositoryContractTests` should be runnable against `CloudKitTransactionRepository` using an in-memory SwiftData `ModelContainer` (no CloudKit):

```swift
@Suite("CloudKitTransactionRepository contract")
struct CloudKitTransactionRepositoryContractTests {
  private func makeRepository() -> CloudKitTransactionRepository {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(
      for: TransactionRecord.self,
      configurations: config
    )
    return CloudKitTransactionRepository(modelContainer: container)
  }

  // Run all contract tests against this repository...
}
```

### Specific Test Cases
1. **Filtering:** Each filter in isolation and in combination (mirrors InMemory tests)
2. **Pagination:** First page, subsequent pages, empty page, single item
3. **priorBalance:** Correct for each page
4. **CRUD:** Create → fetch → update → fetch → delete → fetch
5. **Payee suggestions:** Prefix matching, case-insensitive, distinct values
6. **Sort order:** Date DESC, ID ASC
7. **Account filter:** Matches both accountId and toAccountId for transfers
8. **Scheduled filter:** Correctly distinguishes scheduled from non-scheduled

### Performance Tests
- Fetch with 10,000 transactions (baseline)
- Filter by account with 10,000 transactions
- Payee suggestions with 1,000 unique payees
- priorBalance computation at various page depths

---

## Files to Create

| File | Purpose |
|------|---------|
| `Backends/CloudKit/Models/TransactionRecord.swift` | SwiftData `@Model` |
| `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift` | Repository implementation |
| `MoolahTests/Backends/CloudKitTransactionRepositoryTests.swift` | Contract + specific tests |

---

## Estimated Effort

| Task | Estimate |
|------|----------|
| `TransactionRecord` model | 1 hour |
| Domain ↔ Record mapping | 1 hour |
| `fetch()` with filtering & pagination | 4 hours |
| `priorBalance` computation | 1 hour |
| CRUD operations | 1 hour |
| Payee suggestions | 1 hour |
| Predicate optimization | 2 hours |
| Tests | 3 hours |
| **Total** | **~14 hours** |

---

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Post-filter performance with many transactions | Medium | Predicate push-down for common single-filter cases |
| `payeeLower` getting out of sync | Low | Always update in `create()` and `update()` |
| CloudKit sync conflicts on rapid edits | Low | Last-writer-wins is acceptable for single-user |
| SwiftData predicate limitations change in future OS | Low | Post-filter is always correct; predicates are optimizations |
