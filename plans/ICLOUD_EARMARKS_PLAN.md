# iCloud Migration — Earmarks / Savings Goals

**Date:** 2026-04-08
**Component:** Earmarks (CRUD, budgets, computed balances)
**Parent plan:** [ICLOUD_MIGRATION_PLAN.md](./ICLOUD_MIGRATION_PLAN.md)

## Overview

Earmarks (savings goals) have two key challenges: (1) **computed values** — balance, saved, and spent are derived from transactions, not stored; and (2) **budget items** — a separate sub-collection per earmark.

---

## Current Implementation

### EarmarkRepository Protocol (`Domain/Repositories/EarmarkRepository.swift`)
```swift
protocol EarmarkRepository: Sendable {
  func fetchAll() async throws -> [Earmark]
  func create(_ earmark: Earmark) async throws -> Earmark
  func update(_ earmark: Earmark) async throws -> Earmark
  func fetchBudget(earmarkId: UUID) async throws -> [EarmarkBudgetItem]
  func updateBudget(earmarkId: UUID, items: [EarmarkBudgetItem]) async throws
}
```

### Earmark Domain Model (`Domain/Models/Earmark.swift`)
```swift
struct Earmark: Codable, Sendable, Identifiable, Hashable, Comparable {
  let id: UUID
  var name: String
  var balance: MonetaryAmount    // computed: sum of all earmark transactions
  var saved: MonetaryAmount      // computed: sum of positive amounts
  var spent: MonetaryAmount      // computed: sum of abs(negative amounts)
  var isHidden: Bool
  var position: Int
  var savingsGoal: MonetaryAmount?
  var savingsStartDate: Date?
  var savingsEndDate: Date?
}
```

### EarmarkBudgetItem
```swift
struct EarmarkBudgetItem: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  var categoryId: UUID
  var amount: MonetaryAmount
}
```

### Server Behavior
- `balance` = sum of ALL transaction amounts where `earmarkId` matches
- `saved` = sum of POSITIVE transaction amounts (income into earmark)
- `spent` = sum of absolute values of NEGATIVE transaction amounts (expenses from earmark)
- Budgets are a separate sub-resource: `GET/PUT /api/earmarks/{id}/budget/`
- Budget `updateBudget` replaces the entire budget array (not incremental)

### Field Name Mapping
- Domain `savingsGoal` ↔ Server `savingsTarget` (handled by `CodingKeys`)

---

## SwiftData Models

### File: `Backends/CloudKit/Models/EarmarkRecord.swift`

```swift
import Foundation
import SwiftData

@Model
final class EarmarkRecord {
  #Unique<EarmarkRecord>([\.id])

  @Attribute(.preserveValueOnDeletion)
  var id: UUID

  var name: String
  var position: Int
  var isHidden: Bool
  var savingsTarget: Int?   // cents (nil = no savings goal)
  var savingsStartDate: Date?
  var savingsEndDate: Date?

  init(
    id: UUID,
    name: String,
    position: Int = 0,
    isHidden: Bool = false,
    savingsTarget: Int? = nil,
    savingsStartDate: Date? = nil,
    savingsEndDate: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.position = position
    self.isHidden = isHidden
    self.savingsTarget = savingsTarget
    self.savingsStartDate = savingsStartDate
    self.savingsEndDate = savingsEndDate
  }
}
```

**Note:** `balance`, `saved`, and `spent` are NOT stored — they are computed from `TransactionRecord` data at fetch time.

### File: `Backends/CloudKit/Models/EarmarkBudgetItemRecord.swift`

```swift
import Foundation
import SwiftData

@Model
final class EarmarkBudgetItemRecord {
  #Unique<EarmarkBudgetItemRecord>([\.id])

  @Attribute(.preserveValueOnDeletion)
  var id: UUID

  var earmarkId: UUID
  var categoryId: UUID
  var amount: Int   // cents

  init(id: UUID, earmarkId: UUID, categoryId: UUID, amount: Int) {
    self.id = id
    self.earmarkId = earmarkId
    self.categoryId = categoryId
    self.amount = amount
  }
}
```

---

## CloudKitEarmarkRepository

### File: `Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift`

```swift
import Foundation
import SwiftData
import OSLog

@ModelActor
actor CloudKitEarmarkRepository: EarmarkRepository {
  private let logger = Logger(subsystem: "com.moolah.app", category: "CloudKitEarmarkRepo")

  func fetchAll() async throws -> [Earmark] {
    // 1. Fetch all earmark records
    let descriptor = FetchDescriptor<EarmarkRecord>(
      sortBy: [SortDescriptor(\.position, order: .forward)]
    )
    let earmarkRecords = try modelContext.fetch(descriptor)

    // 2. Fetch all non-scheduled transactions with earmarkIds
    let txnDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate<TransactionRecord> {
        $0.earmarkId != nil && $0.recurPeriod == nil
      }
    )
    let transactions = try modelContext.fetch(txnDescriptor)

    // 3. Group transactions by earmarkId and compute totals
    var balances: [UUID: Int] = [:]
    var savedAmounts: [UUID: Int] = [:]
    var spentAmounts: [UUID: Int] = [:]

    for txn in transactions {
      guard let earmarkId = txn.earmarkId else { continue }
      balances[earmarkId, default: 0] += txn.amount
      if txn.amount > 0 {
        savedAmounts[earmarkId, default: 0] += txn.amount
      } else if txn.amount < 0 {
        spentAmounts[earmarkId, default: 0] += abs(txn.amount)
      }
    }

    // 4. Map to domain models
    return earmarkRecords.map { record in
      Earmark(
        id: record.id,
        name: record.name,
        balance: MonetaryAmount(
          cents: balances[record.id] ?? 0, currency: .defaultCurrency),
        saved: MonetaryAmount(
          cents: savedAmounts[record.id] ?? 0, currency: .defaultCurrency),
        spent: MonetaryAmount(
          cents: spentAmounts[record.id] ?? 0, currency: .defaultCurrency),
        isHidden: record.isHidden,
        position: record.position,
        savingsGoal: record.savingsTarget.map {
          MonetaryAmount(cents: $0, currency: .defaultCurrency)
        },
        savingsStartDate: record.savingsStartDate,
        savingsEndDate: record.savingsEndDate
      )
    }
  }

  func create(_ earmark: Earmark) async throws -> Earmark {
    let record = EarmarkRecord(
      id: earmark.id,
      name: earmark.name,
      position: earmark.position,
      isHidden: earmark.isHidden,
      savingsTarget: earmark.savingsGoal?.cents,
      savingsStartDate: earmark.savingsStartDate,
      savingsEndDate: earmark.savingsEndDate
    )
    modelContext.insert(record)
    try modelContext.save()
    // Return with zero computed values (new earmark has no transactions)
    return Earmark(
      id: earmark.id,
      name: earmark.name,
      balance: .zero,
      saved: .zero,
      spent: .zero,
      isHidden: earmark.isHidden,
      position: earmark.position,
      savingsGoal: earmark.savingsGoal,
      savingsStartDate: earmark.savingsStartDate,
      savingsEndDate: earmark.savingsEndDate
    )
  }

  func update(_ earmark: Earmark) async throws -> Earmark {
    let id = earmark.id
    let descriptor = FetchDescriptor<EarmarkRecord>(
      predicate: #Predicate { $0.id == id }
    )
    guard let record = try modelContext.fetch(descriptor).first else {
      throw BackendError.serverError(404)
    }
    record.name = earmark.name
    record.position = earmark.position
    record.isHidden = earmark.isHidden
    record.savingsTarget = earmark.savingsGoal?.cents
    record.savingsStartDate = earmark.savingsStartDate
    record.savingsEndDate = earmark.savingsEndDate
    try modelContext.save()
    return earmark
  }

  func fetchBudget(earmarkId: UUID) async throws -> [EarmarkBudgetItem] {
    let descriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
      predicate: #Predicate<EarmarkBudgetItemRecord> { $0.earmarkId == earmarkId }
    )
    let records = try modelContext.fetch(descriptor)
    return records.map { record in
      EarmarkBudgetItem(
        id: record.id,
        categoryId: record.categoryId,
        amount: MonetaryAmount(cents: record.amount, currency: .defaultCurrency)
      )
    }
  }

  func updateBudget(earmarkId: UUID, items: [EarmarkBudgetItem]) async throws {
    // Verify earmark exists
    let earmarkDescriptor = FetchDescriptor<EarmarkRecord>(
      predicate: #Predicate<EarmarkRecord> { $0.id == earmarkId }
    )
    guard try modelContext.fetch(earmarkDescriptor).first != nil else {
      throw BackendError.serverError(404)
    }

    // Delete existing budget items for this earmark
    let existingDescriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
      predicate: #Predicate<EarmarkBudgetItemRecord> { $0.earmarkId == earmarkId }
    )
    let existing = try modelContext.fetch(existingDescriptor)
    for item in existing {
      modelContext.delete(item)
    }

    // Insert new budget items
    for item in items {
      let record = EarmarkBudgetItemRecord(
        id: item.id,
        earmarkId: earmarkId,
        categoryId: item.categoryId,
        amount: item.amount.cents
      )
      modelContext.insert(record)
    }

    try modelContext.save()
  }
}
```

---

## Balance Computation Details

### Matching Server Behavior

The server computes earmark totals from all transactions where `earmarkId` matches:

| Metric | Computation |
|--------|-------------|
| `balance` | `SUM(amount)` for all matching transactions |
| `saved` | `SUM(amount)` where `amount > 0` |
| `spent` | `SUM(ABS(amount))` where `amount < 0` |

### Relationship: `balance = saved - spent`

This is always true by construction:
- `balance = sum_positive + sum_negative = saved - spent`

### Excluding Scheduled Transactions

Like account balances, only non-scheduled transactions contribute to earmark totals. The predicate filters `recurPeriod == nil`.

---

## CloudKit Sync Considerations

### Computed Values
- `balance`, `saved`, `spent` are always recomputed from local transactions
- If transactions sync before the earmark, the values are computed for a non-existent earmark (harmless — no UI shows them)
- If the earmark syncs before its transactions, it shows zero values temporarily

### Budget Items
- Budget items reference `earmarkId` via UUID
- `updateBudget` is a replace-all operation — if two devices update budgets simultaneously, last-writer-wins applies to each `EarmarkBudgetItemRecord` independently
- This could result in a merged set of budget items from both devices — which may be incorrect
- **Mitigation:** Budget editing is rare; accept the risk for now

### Position Conflicts
- Same considerations as accounts — last-writer-wins on position field

---

## Performance Considerations

### Batch Transaction Fetch
`fetchAll()` fetches all earmarked transactions once, then groups by earmarkId. This is efficient:
- Single SwiftData fetch for all earmarked transactions
- O(n) grouping and summation
- For 1,000 earmarked transactions across 10 earmarks, this is trivial

### Budget Items
- Budget items are few per earmark (typically 5-20 categories)
- `updateBudget` deletes and re-inserts, which is fine for small sets
- No performance concern

---

## Testing Strategy

### Contract Tests
```swift
@Suite("CloudKitEarmarkRepository contract")
struct CloudKitEarmarkRepositoryContractTests {
  private func makeRepository() throws -> (
    CloudKitEarmarkRepository, ModelContainer
  ) {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: EarmarkRecord.self, EarmarkBudgetItemRecord.self, TransactionRecord.self,
      configurations: config
    )
    return (CloudKitEarmarkRepository(modelContainer: container), container)
  }
}
```

### Test Cases
1. `fetchAll()` returns earmarks sorted by position
2. `fetchAll()` computes balance from positive + negative transactions
3. `fetchAll()` computes saved (positive only) and spent (abs negative only)
4. `create()` returns earmark with zero computed values
5. `update()` changes metadata without affecting computed values
6. `update()` throws 404 for non-existent earmark
7. `fetchBudget()` returns items for specific earmark
8. `updateBudget()` replaces entire budget
9. `updateBudget()` throws 404 for non-existent earmark
10. Earmark with no transactions has all-zero computed values
11. Scheduled transactions excluded from computed values

---

## Files to Create

| File | Purpose |
|------|---------|
| `Backends/CloudKit/Models/EarmarkRecord.swift` | SwiftData `@Model` |
| `Backends/CloudKit/Models/EarmarkBudgetItemRecord.swift` | SwiftData `@Model` |
| `Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift` | Repository implementation |
| `MoolahTests/Backends/CloudKitEarmarkRepositoryTests.swift` | Contract tests |

---

## Estimated Effort

| Task | Estimate |
|------|----------|
| `EarmarkRecord` + `EarmarkBudgetItemRecord` models | 1 hour |
| `fetchAll()` with balance computation | 2 hours |
| CRUD operations | 1 hour |
| Budget fetch/update | 1.5 hours |
| Tests | 2.5 hours |
| **Total** | **~8 hours** |
