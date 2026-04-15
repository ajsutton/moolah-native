# Remove Transaction.earmarkId Convenience Accessor

**Issue:** #14 (Parent: #9)
**Assumes:** #11 (primaryAccountId removal) is complete — `isSimple`, `sourceLeg` DTO pattern, and `TransactionWithBalance` with viewing account context all exist.

## Definition

```swift
var earmarkId: UUID? { legs.first?.earmarkId }
```

## Problem

`earmarkId` returns the first leg's earmark, hiding that earmark is a per-leg property. While in practice only the source leg carries an earmark (matching server semantics where earmark balance uses the source leg's sign convention), the accessor silently assumes the first leg is always the relevant one. When viewing a transfer from the destination account's perspective, the first leg is still the source — so the earmark shows even though the destination leg has no earmark association.

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
- **Account-filtered context** (transaction list, row view): legs whose `accountId` matches the viewing account.
- **Unfiltered context** (upcoming/scheduled views, analysis cards): all legs.

Unlike `categoryId` where multiple legs can have different categories, only the source leg typically carries an earmark. The replacement pattern returns a single optional earmark — not a list — but sources it from applicable legs instead of blindly using `legs.first`.

### TransactionRowView (P1, P2) — Applicable Legs

The current computed property returns a single optional string from the convenience accessor:

```swift
private var earmarkName: String? {
    guard let earmarkId = transaction.earmarkId else { return nil }
    return earmarks.by(id: earmarkId)?.name
}
```

Replace with a computed property that finds the earmark from applicable legs:

```swift
private var earmarkName: String? {
    let applicable = viewingAccountId.map { id in
        transaction.legs.filter { $0.accountId == id }
    } ?? transaction.legs
    guard let earmarkId = applicable.first(where: { $0.earmarkId != nil })?.earmarkId else {
        return nil
    }
    return earmarks.by(id: earmarkId)?.name
}
```

The `displayPayee` fallback (P2) uses the same applicable-legs pattern:

```swift
// Before
if let earmarkId = transaction.earmarkId,
   let earmark = earmarks.by(id: earmarkId) {
    return "Earmark funds for \(earmark.name)"
}

// After
let applicableForPayee = viewingAccountId.map { id in
    transaction.legs.filter { $0.accountId == id }
} ?? transaction.legs
if let earmarkId = applicableForPayee.first(where: { $0.earmarkId != nil })?.earmarkId,
   let earmark = earmarks.by(id: earmarkId) {
    return "Earmark funds for \(earmark.name)"
}
```

To avoid duplicating the applicable-legs computation, extract a shared helper:

```swift
private var applicableEarmarkId: UUID? {
    let applicable = viewingAccountId.map { id in
        transaction.legs.filter { $0.accountId == id }
    } ?? transaction.legs
    return applicable.first(where: { $0.earmarkId != nil })?.earmarkId
}
```

Then both `earmarkName` and `displayPayee` use `applicableEarmarkId`.

### UpcomingView (P3, P4) — All Legs, No Account Filter

Scheduled/upcoming transactions have no viewing account context. Use all legs:

```swift
// P3 — earmark name in metadata row
if let earmarkId = transaction.legs.first(where: { $0.earmarkId != nil })?.earmarkId,
   let earmark = earmarks.by(id: earmarkId) {
    Text("•")
        .foregroundStyle(.secondary)
    Text(earmark.name)
        .font(.caption)
        .foregroundStyle(.secondary)
}

// P4 — displayPayee fallback
if let earmarkId = transaction.legs.first(where: { $0.earmarkId != nil })?.earmarkId,
   let earmark = earmarks.by(id: earmarkId) {
    return "Earmark funds for \(earmark.name)"
}
```

### UpcomingTransactionsCard (P5) — Same as UpcomingView

Same unfiltered context. Replace `transaction.earmarkId` with `transaction.legs.first(where: { $0.earmarkId != nil })?.earmarkId`:

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

All test assertions should use leg-level access instead of the convenience accessor.

**T1** (`TransactionDraftTests.swift:193`): Compare earmark structures across legs:
```swift
#expect(roundTripped!.legs.compactMap(\.earmarkId) == original.legs.compactMap(\.earmarkId))
```

**T2–T5** (`TransactionStoreTests.swift:890–1039`): onMutate earmark assertions. These test single-leg transactions, so `legs.first?.earmarkId` is correct:
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

### Step 1: TransactionRowView (P1, P2)

Extract `applicableEarmarkId: UUID?` helper using viewing account context. Replace `earmarkName` and `displayPayee` to use it.

### Step 2: UpcomingView (P3, P4)

Replace `transaction.earmarkId` with `transaction.legs.first(where: { $0.earmarkId != nil })?.earmarkId` in both the metadata row and `displayPayee`.

### Step 3: UpcomingTransactionsCard (P5)

Same pattern as Step 2 — replace `transaction.earmarkId` in `displayPayee`.

### Step 4: TransactionDraft.init(from:)

Replace `primaryLeg?.earmarkId` with `transaction.legs.first(where: { $0.earmarkId != nil })?.earmarkId`.

### Step 5: Test Updates (T1–T10)

Update all assertions to use leg-level access as described above.

### Step 6: Delete the Accessor

Remove from `Domain/Models/Transaction.swift`:
```swift
var earmarkId: UUID? { legs.first?.earmarkId }
```

### Step 7: Update BUGS.md

Remove the `earmarkId → legs.first?.earmarkId` line from the convenience accessor bug entry.

## Risk Assessment

**Low risk.** The accessor is a trivial computed property. Every production replacement either:
- Finds the earmark from applicable legs (views) — correct for both simple and complex transactions
- Finds the first leg with an earmark (draft init) — sufficient since only the source leg carries an earmark
- Uses `sourceLeg?.earmarkId` (DTOs, already handled by #11) — correct for the source-oriented server API

The only visible behavior change is that when viewing a transfer from the destination account, the earmark will no longer show in TransactionRowView (since the destination leg has no earmark). This is the correct behavior — the earmark belongs to the source account's leg.
