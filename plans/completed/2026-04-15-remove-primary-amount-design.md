# Design: Remove Transaction.primaryAmount

**GitHub issue:** #10
**Date:** 2026-04-15

## Problem

`Transaction.primaryAmount` returns `legs.first?.amount`, assuming the first leg is the "main" one. This breaks for transfers in the CloudKit backend, where legs are stored in a fixed order (source first, destination second). When viewing a transfer from the destination account, `primaryAmount` returns the source leg's amount (wrong sign), corrupting both the displayed amount and the running balance.

## Design

### New type: ConvertedTransactionLeg

A wrapper pairing a `TransactionLeg` with its amount converted to a target instrument.

```swift
struct ConvertedTransactionLeg: Sendable {
  let leg: TransactionLeg
  let convertedAmount: InstrumentAmount
}
```

`convertedAmount` is always populated. When the leg's instrument matches the target, `convertedAmount` equals `leg.amount`.

### Changes to TransactionWithBalance

Add `convertedLegs`, a pre-computed `displayAmount`, and a filtering helper:

```swift
struct TransactionWithBalance: Sendable, Identifiable {
  let transaction: Transaction
  let convertedLegs: [ConvertedTransactionLeg]
  let displayAmount: InstrumentAmount  // sum of converted legs for the viewing account
  let balance: InstrumentAmount

  var id: UUID { transaction.id }

  func legs(forAccount accountId: UUID) -> [ConvertedTransactionLeg] {
    convertedLegs.filter { $0.leg.accountId == accountId }
  }
}
```

### Store changes

`TransactionStore` gains a target instrument parameter (account currency when filtered by account, profile currency otherwise). At fetch time, after loading transactions, it converts each leg using `InstrumentConversionService` and builds `ConvertedTransactionLeg` arrays.

`withRunningBalances` gains an `accountId: UUID?` parameter. When set, it sums the converted amounts of legs matching that account for each transaction. It also stores the sum as `displayAmount` on each `TransactionWithBalance`.

The store already has `currentFilter.accountId` available and passes it through.

### Account-filtered views (transaction list)

These views always have an account context from the filter.

**TransactionRowView** (`TransactionRowView.swift:55,67`): Replace `transaction.primaryAmount` with the pre-computed `displayAmount` from `TransactionWithBalance`. The row already receives `balance` this way; `displayAmount` follows the same pattern.

**withRunningBalances** (`Transaction.swift:171`): Replace `transaction.primaryAmount` with the sum of converted leg amounts for the filtered account. This is where `displayAmount` is computed.

### Scheduled/unfiltered views (upcoming)

These views have no account context.

**UpcomingTransactionsCard** (`UpcomingTransactionsCard.swift:142`) and **UpcomingView** (`UpcomingView.swift:236`): These views should also receive `TransactionWithBalance` (or at minimum `ConvertedTransactionLeg` data). For the `displayAmount` computation when there is no account context: single-leg transactions use that leg's converted amount; transfers find the leg with the negative quantity and use its converted amount. Display transfers as "Transfer from A to B".

Complex multi-leg transactions (more than 2 legs, or legs whose amounts are not negatives of each other, or legs with differing non-amount fields) are a future concern — they cannot be created currently.

### TransactionDetailView

**Instrument label** (`TransactionDetailView.swift:189`): Currently shows `transaction.primaryAmount.instrument.id`. Replace with the instrument from the relevant leg:
- When there's an account context, use a leg matching that account
- When editing a scheduled transaction, use the negative-quantity leg for transfers, or the only leg for income/expense

**Autofill** (`TransactionDetailView.swift:409`): Currently copies `abs(match.primaryAmount.quantity)`. Replace with the quantity from the leg matching the draft's current account (`draft.accountId`). The autofilled transaction is fetched without account context, so we pick the leg matching the account being edited.

**isNewTransaction** (`TransactionDetailView.swift:55`): Currently checks `transaction.primaryAmount.isZero`. Replace with checking the relevant leg's amount (same leg selection as instrument label above).

**saveIfValid** (`TransactionDetailView.swift:489`): Currently uses `transaction.primaryAmount.instrument` as `fromInstrument`. Replace with the relevant leg's instrument.

**Editability guard:** `Transaction` gains a reusable `isSimple` computed property. A transaction is simple if it has a single leg, or exactly two legs where the amounts are negations of each other and no other fields differ (type, categoryId, earmarkId). This check will also be used elsewhere (e.g. validating whether a transaction can be saved to the Remote backend, which only supports simple transactions).

```swift
extension Transaction {
  var isSimple: Bool {
    if legs.count == 1 { return true }
    guard legs.count == 2 else { return false }
    let a = legs[0], b = legs[1]
    return a.quantity == -b.quantity
      && a.type == b.type
      && a.categoryId == b.categoryId
      && a.earmarkId == b.earmarkId
  }
}
```

When `!transaction.isSimple`, the detail view is read-only. Full complex-transaction editing is tracked in #15.

**Editing simple transfers:** When editing a simple two-leg transfer, changes to the amount update both legs — the edited leg directly, and the other leg with the negated amount.

### Deletion of the accessor

After all call sites are migrated, delete `primaryAmount` from `Transaction` (line 111 of `Transaction.swift`).

### Test changes

Test call sites use `primaryAmount` for assertions. These should be updated to assert against specific legs directly (e.g. `transaction.legs[0].amount` or `transaction.legs.first { ... }?.amount`), or against the `displayAmount` / `convertedLegs` on `TransactionWithBalance` where appropriate.
