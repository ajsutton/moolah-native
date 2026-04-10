# iCloud Migration — Scheduled Transactions & Forecasting

**Date:** 2026-04-08
**Component:** Scheduled Transactions (recurrence, pay action, forecasting)
**Parent plan:** [ICLOUD_MIGRATION_PLAN.md](./ICLOUD_MIGRATION_PLAN.md)

## Overview

Scheduled transactions are stored as regular transactions with `recurPeriod != nil`. Moving to iCloud actually **simplifies** this component — the pay action orchestration and forecasting that the server handles can now be done locally in a single SwiftData context, making atomic operations trivial.

---

## Current State

### What Exists (from SCHEDULED_TRANSACTIONS_GAP_ANALYSIS.md)

**Domain Layer (complete):**
- `RecurPeriod` enum: `.once`, `.day`, `.week`, `.month`, `.year`
- `Transaction.isScheduled` / `Transaction.isRecurring` computed properties
- `Transaction.nextDueDate()` — calculates next occurrence using `Calendar`
- `Transaction.validate()` — ensures `recurPeriod` and `recurEvery` are both set or both nil
- `TransactionFilter.scheduled: Bool?` — filter by scheduled status

**Backend Layer (complete):**
- `InMemoryTransactionRepository` filters by `scheduled` correctly
- `RemoteTransactionRepository` passes `scheduled` query param
- `TransactionDTO` includes `recurPeriod` and `recurEvery`

**UI (partially complete):**
- `UpcomingView` — displays overdue and upcoming scheduled transactions
- Pay button on each row
- Recurrence description display

### What's Missing (gaps from analysis)

1. Recurrence UI in TransactionFormView (creating/editing scheduled txns)
2. Pay action doesn't update/delete the original scheduled transaction
3. Forecasting for analysis graphs
4. Short-term upcoming widget on dashboard

---

## How Scheduled Transactions Work in CloudKit Backend

### Storage

Scheduled transactions are stored as regular `TransactionRecord` entries in SwiftData. The only difference is `recurPeriod != nil`. No separate model or table needed.

### Filtering

The `CloudKitTransactionRepository` already handles the `scheduled` filter (see Transactions plan). All queries are scoped by `profileId`:
```swift
if let scheduled = filter.scheduled {
  result = result.filter { ($0.recurPeriod != nil) == scheduled }
}
```

### Balance Exclusion

Scheduled transactions are excluded from account and earmark balance computations. All predicates include `profileId` scoping:
```swift
// In CloudKitAccountRepository.fetchAll()
predicate: #Predicate<TransactionRecord> { $0.profileId == pid && $0.recurPeriod == nil }
```

This matches the server behavior — scheduled transactions represent future/projected amounts, not actual balances.

---

## Pay Action Implementation

The pay action is currently orchestrated in `TransactionStore`. With iCloud, this becomes simpler because everything happens in a single SwiftData context.

### Current Flow (from SCHEDULED_TRANSACTIONS_GAP_ANALYSIS.md)

1. Create a non-scheduled copy with today's date
2. If `recurPeriod == .once`: delete the original
3. If recurring: update the original's `date` to `nextDueDate()`

### CloudKit Implementation

With SwiftData, all three operations happen in a single `modelContext.save()`:

```swift
// In CloudKitTransactionRepository or a dedicated method
func payScheduledTransaction(_ transaction: Transaction) async throws -> Transaction {
  // 1. Create paid (non-scheduled) copy
  let paidTransaction = Transaction(
    id: UUID(),
    type: transaction.type,
    date: Date(),  // today
    accountId: transaction.accountId,
    toAccountId: transaction.toAccountId,
    amount: transaction.amount,
    payee: transaction.payee,
    notes: transaction.notes,
    categoryId: transaction.categoryId,
    earmarkId: transaction.earmarkId,
    recurPeriod: nil,    // non-scheduled
    recurEvery: nil
  )
  let paidRecord = TransactionRecord(from: paidTransaction, profileId: profileId)
  modelContext.insert(paidRecord)

  // 2. Handle the original scheduled transaction
  let originalId = transaction.id
  let descriptor = FetchDescriptor<TransactionRecord>(
    predicate: #Predicate { $0.id == originalId }
  )
  guard let originalRecord = try modelContext.fetch(descriptor).first else {
    throw BackendError.serverError(404)
  }

  if transaction.recurPeriod == .once {
    // One-time: delete the original
    modelContext.delete(originalRecord)
  } else if let nextDate = transaction.nextDueDate() {
    // Recurring: advance to next due date
    originalRecord.date = nextDate
  }

  // 3. Single atomic save
  try modelContext.save()

  return paidTransaction
}
```

### Advantages Over Server Approach

| Aspect | Server (current) | CloudKit (new) |
|--------|-----------------|----------------|
| Atomicity | Two separate HTTP requests (create + update/delete) — not atomic | Single `modelContext.save()` — fully atomic |
| Latency | Two round trips | Instant (local write) |
| Error handling | Partial failure possible (paid txn created but original not updated) | All-or-nothing |
| Offline support | Fails without network | Works offline, syncs later |

---

## Gap Resolution

### Gap 1: Recurrence UI in TransactionFormView
**Status:** Not affected by backend migration — this is a pure UI change.
**Action:** Implement as described in `SCHEDULED_TRANSACTIONS_GAP_ANALYSIS.md` Phase 1, item 3. No backend-specific work needed.

### Gap 2: Pay Action Doesn't Update Original
**Status:** Resolved by the `payScheduledTransaction` method above.
**Action:** Wire `TransactionStore.payTransaction()` to call the repository's pay method (or orchestrate create + update/delete using existing CRUD methods).

### Gap 3: Forecasting
**Status:** Becomes a local computation. See Forecasting section below.

### Gap 4: RecurPeriod Enum
**Status:** Already resolved — `RecurPeriod` enum exists in `Domain/Models/Transaction.swift`.

### Gap 5: Short-Term Upcoming Widget
**Status:** Pure UI — not affected by backend migration.

### Gap 6: Validation
**Status:** `Transaction.validate()` already exists in the domain layer.

---

## Forecasting

### Purpose
Project future balances based on scheduled transactions for the analysis/net-worth graph.

### Implementation: Local Computation

With all data local, forecasting is a straightforward computation:

```swift
/// Generates all future instances of a scheduled transaction up to a date.
func extrapolateScheduledTransaction(
  _ transaction: Transaction,
  until forecastEnd: Date
) -> [Transaction] {
  guard transaction.isRecurring else {
    // One-time scheduled: just return it if it's before forecastEnd
    if transaction.date <= forecastEnd {
      return [transaction]
    }
    return []
  }

  var instances: [Transaction] = []
  var currentDate = transaction.date
  let calendar = Calendar.current

  while currentDate <= forecastEnd {
    // Create a projected instance
    let instance = Transaction(
      id: UUID(),
      type: transaction.type,
      date: currentDate,
      accountId: transaction.accountId,
      toAccountId: transaction.toAccountId,
      amount: transaction.amount,
      payee: transaction.payee,
      categoryId: transaction.categoryId,
      earmarkId: transaction.earmarkId,
      recurPeriod: nil,  // projected instances are non-scheduled
      recurEvery: nil
    )
    instances.append(instance)

    // Advance to next occurrence
    guard let period = transaction.recurPeriod,
          let every = transaction.recurEvery else { break }

    var components = DateComponents()
    switch period {
    case .day: components.day = every
    case .week: components.weekOfYear = every
    case .month: components.month = every
    case .year: components.year = every
    case .once: break
    }

    guard let nextDate = calendar.date(byAdding: components, to: currentDate) else { break }
    currentDate = nextDate
  }

  return instances
}

/// Projects daily balances forward from a starting balance.
func forecastBalances(
  scheduledTransactions: [Transaction],
  currentNetWorth: MonetaryAmount,
  until forecastEnd: Date
) -> [DailyBalance] {
  // 1. Extrapolate all scheduled transactions
  let allProjected = scheduledTransactions
    .flatMap { extrapolateScheduledTransaction($0, until: forecastEnd) }
    .sorted { $0.date < $1.date }

  // 2. Walk forward, computing running balance
  var balance = currentNetWorth
  var result: [DailyBalance] = []

  for txn in allProjected {
    balance += txn.amount
    result.append(DailyBalance(
      date: txn.date,
      balance: balance,
      isForecast: true
    ))
  }

  return result
}
```

### Where This Lives

This computation belongs in the domain layer or in an `AnalysisRepository` implementation — it's pure business logic with no backend dependency.

**Recommended location:** `Domain/Models/TransactionForecasting.swift` or within `CloudKitAnalysisRepository` (when Step 10 is implemented).

---

## Testing Strategy

### Existing Tests
`MoolahTests/Domain/ScheduledTransactionTests.swift` already covers:
- `isScheduled` property
- Creating a paid copy
- Filtering scheduled transactions
- Overdue classification
- Recurrence period values

### Additional Tests for CloudKit Backend

```swift
@Suite("Scheduled transactions in CloudKit")
struct CloudKitScheduledTransactionTests {
  @Test("Pay one-time scheduled transaction deletes original")
  func payOnce() async throws { ... }

  @Test("Pay recurring transaction advances date")
  func payRecurring() async throws { ... }

  @Test("Scheduled transactions excluded from account balance")
  func excludedFromBalance() async throws { ... }

  @Test("Scheduled transactions excluded from earmark balance")
  func excludedFromEarmarkBalance() async throws { ... }

  @Test("Pay action is atomic — both operations succeed or both fail")
  func payAtomic() async throws { ... }
}
```

### Forecasting Tests
```swift
@Suite("Transaction forecasting")
struct TransactionForecastingTests {
  @Test("Extrapolates monthly transaction")
  func monthlyExtrapolation() { ... }

  @Test("One-time scheduled returns single instance")
  func onceExtrapolation() { ... }

  @Test("Forecast balances accumulate correctly")
  func forecastBalances() { ... }

  @Test("Empty scheduled transactions produce no forecast")
  func emptyForecast() { ... }
}
```

---

## Files to Create

| File | Purpose |
|------|---------|
| `Domain/Models/TransactionForecasting.swift` | Extrapolation and forecasting logic |
| `MoolahTests/Domain/TransactionForecastingTests.swift` | Forecasting tests |

No new backend files needed — scheduled transactions use `TransactionRecord` and `CloudKitTransactionRepository`.

---

## Estimated Effort

| Task | Estimate |
|------|----------|
| Pay action in repository | 1.5 hours |
| Forecasting logic | 2 hours |
| Forecasting tests | 1.5 hours |
| Pay action tests | 1 hour |
| **Total** | **~6 hours** |

Note: The recurrence UI gaps identified in `SCHEDULED_TRANSACTIONS_GAP_ANALYSIS.md` are UI-only work and are not affected by the backend migration. They are estimated at ~11 hours separately.
