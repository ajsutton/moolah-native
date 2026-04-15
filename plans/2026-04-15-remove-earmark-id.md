# Remove Transaction.earmarkId Convenience Accessor

**Issue:** #14 (Parent: #9)
**Assumes:** #11 (primaryAccountId removal) is complete — `isSimple`, `sourceLeg` DTO pattern, and `TransactionWithBalance` with viewing account context all exist.

## Definition

```swift
var earmarkId: UUID? { legs.first?.earmarkId }
```

## Problem

`earmarkId` returns the first leg's earmark, hiding that earmark is a per-leg property. A complex transaction can have different earmarks on different legs. The accessor silently returns only the first leg's value regardless of which legs are relevant to the viewing context.

## Call Sites

### Production Code

| # | Location | Current Usage | Status |
|---|----------|---------------|--------|
| P1 | `TransactionRowView.swift:97` | `earmarkName` computed property: looks up earmark by `transaction.earmarkId` | Needs change |
| P2 | `TransactionRowView.swift:121` | `displayPayee` fallback: "Earmark funds for X" via `transaction.earmarkId` | Needs change |
| P3 | `UpcomingView.swift:225` | Shows earmark name in upcoming row metadata | Needs change |
| P4 | `UpcomingView.swift:267` | `displayPayee` fallback in upcoming row | Needs change |
| P5 | `UpcomingTransactionsCard.swift:190` | `displayPayee` fallback in upcoming card | Needs change |
| P6 | `TransactionDTO.swift:92` | DTO mapping | Already handled by #11 (`sourceLeg?.earmarkId`) |
| P7 | `TransactionDTO.swift:148` | DTO mapping | Already handled by #11 (`sourceLeg?.earmarkId`) |

### Indirect Usage (same semantic issue)

| # | Location | Current Usage |
|---|----------|---------------|
| P8 | `TransactionDraft.swift:148` | `primaryLeg?.earmarkId` — uses `legs.first`, same assumption as the accessor |

### Test Code

| # | Location | Current Usage |
|---|----------|---------------|
| T1 | `TransactionDraftTests.swift:193` | Round-trip assertion |
| T2 | `TransactionStoreTests.swift:890,892` | onMutate: old/new tx preserve earmark on amount change |
| T3 | `TransactionStoreTests.swift:942,943` | onMutate: old has earmarkId1, new has earmarkId2 |
| T4 | `TransactionStoreTests.swift:990,991` | onMutate: old has nil earmark, new has earmarkId |
| T5 | `TransactionStoreTests.swift:1038,1039` | onMutate: old has earmarkId, new has nil |
| T6 | `TransactionStoreTests.swift:1511` | Pay scheduled tx preserves earmark |
| T7 | `TransactionRepositoryContractTests.swift:152` | Transfer create preserves earmark |
| T8 | `TransactionRepositoryContractTests.swift:174` | Fetched transfer preserves earmark |
| T9 | `TransactionRepositoryContractTests.swift:322,325,333` | Earmark filter: find earmarked tx, extract id, assert filter result |
| T10 | `RemoteTransactionRepositoryTests.swift:278` | Decoded income has earmark |

## Design

### Applicable Legs

Throughout this plan, "applicable legs" means:
- **Account-filtered context** (transaction list, detail view): legs whose `accountId` matches the viewing account.
- **Earmark-filtered context** (earmark detail, no account filter): legs whose `earmarkId` matches the viewing earmark.
- **Unfiltered context** (upcoming/scheduled views): all legs.

When multiple applicable legs have different earmarks, **show all unique earmarks**.

### Balance Computation — Earmark-Aware displayAmount

`TransactionPage.withRunningBalances` currently filters legs by `accountId` to compute `displayAmount` and running balance. When the viewing context is an earmark (not an account), the same per-leg filtering must happen by `earmarkId` — otherwise `displayAmount` sums all legs regardless of earmark, producing incorrect totals.

**Current signature:**

```swift
static func withRunningBalances(
    transactions: [Transaction],
    priorBalance: InstrumentAmount,
    accountId: UUID?,
    targetInstrument: Instrument,
    conversionService: InstrumentConversionService
) async throws -> [TransactionWithBalance]
```

**New signature:**

```swift
static func withRunningBalances(
    transactions: [Transaction],
    priorBalance: InstrumentAmount,
    accountId: UUID?,
    earmarkId: UUID?,
    targetInstrument: Instrument,
    conversionService: InstrumentConversionService
) async throws -> [TransactionWithBalance]
```

**New displayAmount logic:**

```swift
let displayAmount: InstrumentAmount
if let accountId {
    // Account context: sum legs matching the viewing account
    displayAmount = convertedLegs
        .filter { $0.leg.accountId == accountId }
        .reduce(.zero(instrument: targetInstrument)) { $0 + $1.convertedAmount }
} else if let earmarkId {
    // Earmark context (no account): sum legs matching the viewing earmark
    displayAmount = convertedLegs
        .filter { $0.leg.earmarkId == earmarkId }
        .reduce(.zero(instrument: targetInstrument)) { $0 + $1.convertedAmount }
} else {
    // No context (scheduled view): existing transfer/sum-all logic
    let isTransfer = transaction.legs.contains { $0.type == .transfer }
    if isTransfer {
        let negativeLeg = convertedLegs.first { $0.leg.quantity < 0 }
        displayAmount = negativeLeg?.convertedAmount ?? .zero(instrument: targetInstrument)
    } else {
        displayAmount = convertedLegs
            .reduce(.zero(instrument: targetInstrument)) { $0 + $1.convertedAmount }
    }
}
```

When both `accountId` and `earmarkId` are set, `accountId` takes precedence — the account is the viewing perspective, and the earmark filter only narrows which transactions appear (handled by the repository).

**TransactionStore call site** (`TransactionStore.swift:287`):

```swift
// Before
transactions = try await TransactionPage.withRunningBalances(
    transactions: rawTransactions,
    priorBalance: priorBalance,
    accountId: currentFilter.accountId,
    targetInstrument: targetInstrument,
    conversionService: conversionService
)

// After
transactions = try await TransactionPage.withRunningBalances(
    transactions: rawTransactions,
    priorBalance: priorBalance,
    accountId: currentFilter.accountId,
    earmarkId: currentFilter.earmarkId,
    targetInstrument: targetInstrument,
    conversionService: conversionService
)
```

**TransactionWithBalance helper:**

Add a `legs(forEarmark:)` method parallel to the existing `legs(forAccount:)`:

```swift
/// Returns converted legs belonging to the given earmark.
func legs(forEarmark earmarkId: UUID) -> [ConvertedTransactionLeg] {
    convertedLegs.filter { $0.leg.earmarkId == earmarkId }
}
```

### TransactionRowView (P1) — Show All Applicable Earmarks

The current computed property returns a single optional string:

```swift
private var earmarkName: String? {
    guard let earmarkId = transaction.earmarkId else { return nil }
    return earmarks.by(id: earmarkId)?.name
}
```

Replace with a computed property that returns all unique earmark names from applicable legs:

```swift
private var earmarkNames: [String] {
    let applicable = viewingAccountId.map { id in
        transaction.legs.filter { $0.accountId == id }
    } ?? transaction.legs

    let uniqueIds = applicable.compactMap(\.earmarkId).uniqued()
    return uniqueIds.compactMap { earmarks.by(id: $0)?.name }
}
```

(`uniqueIds` preserves order of first appearance via the same `uniqued()` helper used by the categoryId change.)

In the view body, replace the single-earmark block:

```swift
// Before
if !hideEarmark, let earmarkName {
    Text("·")
    Label(earmarkName, systemImage: "bookmark.fill")
        .labelStyle(.iconOnly)
        .imageScale(.small)
    Text(earmarkName)
}

// After
if !hideEarmark {
    ForEach(earmarkNames, id: \.self) { name in
        Text("·")
        Label(name, systemImage: "bookmark.fill")
            .labelStyle(.iconOnly)
            .imageScale(.small)
        Text(name)
    }
}
```

Each earmark gets its own bookmark icon + name, separated by `·` from the date and from each other. This gracefully handles zero, one, or many earmarks.

### TransactionRowView displayPayee (P2) — First Applicable Earmark

The `displayPayee` fallback generates "Earmark funds for X" when no payee is set. Since this produces a single string used as the transaction's display name, use the first applicable earmark:

```swift
// Before
if let earmarkId = transaction.earmarkId,
   let earmark = earmarks.by(id: earmarkId) {
    return "Earmark funds for \(earmark.name)"
}

// After
let applicable = viewingAccountId.map { id in
    transaction.legs.filter { $0.accountId == id }
} ?? transaction.legs
if let earmarkId = applicable.first(where: { $0.earmarkId != nil })?.earmarkId,
   let earmark = earmarks.by(id: earmarkId) {
    return "Earmark funds for \(earmark.name)"
}
```

To avoid duplicating the applicable-legs computation between `earmarkNames` and `displayPayee`, extract a shared helper:

```swift
private var applicableEarmarkIds: [UUID] {
    let applicable = viewingAccountId.map { id in
        transaction.legs.filter { $0.accountId == id }
    } ?? transaction.legs
    return applicable.compactMap(\.earmarkId).uniqued()
}
```

Then `earmarkNames` maps over `applicableEarmarkIds`, and `displayPayee` uses `applicableEarmarkIds.first`.

### UpcomingView (P3, P4) — Same Pattern, No Account Filter

Scheduled/upcoming transactions have no viewing account context. Use all legs:

```swift
let earmarkIds = transaction.legs.compactMap(\.earmarkId).uniqued()
```

**P3** — Show all unique earmark names in the metadata row, same layout as TransactionRowView:

```swift
// Before
if let earmarkId = transaction.earmarkId,
   let earmark = earmarks.by(id: earmarkId) {
    Text("•")
        .foregroundStyle(.secondary)
    Text(earmark.name)
        .font(.caption)
        .foregroundStyle(.secondary)
}

// After
let earmarkIds = transaction.legs.compactMap(\.earmarkId).uniqued()
ForEach(earmarkIds, id: \.self) { earmarkId in
    if let earmark = earmarks.by(id: earmarkId) {
        Text("•")
            .foregroundStyle(.secondary)
        Text(earmark.name)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
```

**P4** — `displayPayee` fallback uses the first earmark from all legs:

```swift
if let earmarkId = transaction.legs.first(where: { $0.earmarkId != nil })?.earmarkId,
   let earmark = earmarks.by(id: earmarkId) {
    return "Earmark funds for \(earmark.name)"
}
```

### UpcomingTransactionsCard (P5) — Same as UpcomingView P4

Same unfiltered context. Replace `transaction.earmarkId` with first earmark from all legs:

```swift
// Before
if let earmarkId = transaction.earmarkId,
   let earmark = earmarks.by(id: earmarkId) {
    return "Earmark funds for \(earmark.name)"
}

// After
if let earmarkId = transaction.legs.first(where: { $0.earmarkId != nil })?.earmarkId,
   let earmark = earmarks.by(id: earmarkId) {
    return "Earmark funds for \(earmark.name)"
}
```

### TransactionDraft.init(from:) (P8) — Per-Leg Access

Line 148 currently reads `earmarkId: primaryLeg?.earmarkId` where `primaryLeg = legs.first`. Replace with:

```swift
earmarkId: transaction.legs.first(where: { $0.earmarkId != nil })?.earmarkId,
```

This finds the first leg that carries an earmark regardless of position. (Other fields in this init that still use `primaryLeg` are addressed by their respective issue plans.)

### Test Assertions — Assert on Legs

All test assertions should use leg-level access or `legs.contains(where:)` with the test's known earmarkId.

**T1** (`TransactionDraftTests.swift:193`): Compare earmark structures across legs:
```swift
#expect(roundTripped!.legs.compactMap(\.earmarkId) == original.legs.compactMap(\.earmarkId))
```

**T2–T5** (`TransactionStoreTests.swift:890–1039`): onMutate earmark assertions. These test single-leg transactions, so `legs.first?.earmarkId` is the direct replacement:
```swift
// Before
#expect(receivedOld?.earmarkId == earmarkId)
#expect(receivedNew?.earmarkId == earmarkId)

// After
#expect(receivedOld?.legs.first?.earmarkId == earmarkId)
#expect(receivedNew?.legs.first?.earmarkId == earmarkId)
```

Same pattern for nil comparisons:
```swift
// Before
#expect(receivedOld?.earmarkId == nil)

// After
#expect(receivedOld?.legs.first?.earmarkId == nil)
```

**T6** (`TransactionStoreTests.swift:1511`): Paid tx preserves earmark:
```swift
#expect(paidTx?.legs.contains(where: { $0.earmarkId == earmarkId }) == true)
```

**T7, T8** (`TransactionRepositoryContractTests.swift:152,174`): Transfer preserves earmark:
```swift
#expect(result.legs.contains(where: { $0.earmarkId == earmarkId }))
#expect(fetched.legs.contains(where: { $0.earmarkId == earmarkId }))
```

**T9** (`TransactionRepositoryContractTests.swift:322,325,333`): Earmark filter:
```swift
let earmarked = allPage.transactions.filter { $0.legs.contains(where: { $0.earmarkId != nil }) }
let earmarkId = earmarked[0].legs.first(where: { $0.earmarkId != nil })!.earmarkId!
#expect(filteredPage.transactions[0].legs.contains(where: { $0.earmarkId == earmarkId }))
```

**T10** (`RemoteTransactionRepositoryTests.swift:278`): Decoded income has earmark:
```swift
#expect(txn.legs.contains(where: { $0.earmarkId == earmarkId }))
```

## Implementation Steps

### Step 1: Balance Computation

Add `earmarkId: UUID?` parameter to `TransactionPage.withRunningBalances`. Add earmark leg filtering in the `displayAmount` computation. Add `TransactionWithBalance.legs(forEarmark:)` helper. Update `TransactionStore.recomputeBalances()` to pass `currentFilter.earmarkId`. This step is foundational — it makes earmark-filtered transaction lists show correct per-transaction amounts and running balances.

### Step 2: TransactionRowView (P1, P2)

Replace `earmarkName: String?` with `earmarkNames: [String]` sourced from applicable legs. Extract `applicableEarmarkIds` helper. Update the view body to iterate with `ForEach`. Update `displayPayee` to use `applicableEarmarkIds.first`. Requires viewing account context from `TransactionWithBalance`.

### Step 3: UpcomingView (P3, P4)

Same pattern as step 2 but using all legs (no account filter). Show all unique earmarks in the metadata row. Use first earmark for `displayPayee` fallback.

### Step 4: UpcomingTransactionsCard (P5)

Same pattern as UpcomingView P4 — replace `transaction.earmarkId` in `displayPayee`.

### Step 5: TransactionDraft.init(from:)

Replace `primaryLeg?.earmarkId` with `transaction.legs.first(where: { $0.earmarkId != nil })?.earmarkId`.

### Step 6: Test Updates (T1–T10)

Update all assertions to use leg-level access as described above. Add tests for earmark-aware `withRunningBalances` — verify that `displayAmount` sums only earmark-matching legs when `earmarkId` is passed, with instrument conversion.

### Step 7: Delete the Accessor

Remove from `Domain/Models/Transaction.swift`:
```swift
var earmarkId: UUID? { legs.first?.earmarkId }
```

### Step 8: Update BUGS.md

Remove the `earmarkId → legs.first?.earmarkId` line from the convenience accessor bug entry.

## Risk Assessment

**Low–medium risk.** The accessor removal itself is low risk — every production replacement either:
- Collects earmarks from applicable legs (views) — correct for both simple and complex transactions
- Finds the first leg with an earmark (detail view, draft init) — sufficient for read-only complex tx display
- Uses `sourceLeg?.earmarkId` (DTOs, already handled by #11) — correct for the source-oriented server API

The balance computation change (Step 1) carries slightly more risk because it changes `displayAmount` and running balance values for earmark-filtered views. However, the pattern is identical to the existing `accountId` filtering — the only difference is which leg field is matched. The existing `accountId` path is unaffected.

Visible behavior changes:
- Complex transactions with multiple earmarks will show all of them instead of just the first leg's earmark.
- Earmark-filtered transaction lists will show per-earmark amounts instead of whole-transaction amounts. Both are the correct behavior.
