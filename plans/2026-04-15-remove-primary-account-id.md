# Remove Transaction.primaryAccountId Convenience Accessor

**Issue:** #11 (Parent: #9)

## Definition

```swift
var primaryAccountId: UUID? { legs.first?.accountId }
```

## Problem

`primaryAccountId` assumes the first leg is "special". For transfers, the first leg is always the source, but views filtering by the destination account need the destination leg's account. The accessor hides this asymmetry. Callers use it to identify the "other" leg in a transfer, but for incoming transfers the logic is inverted — "Transfer to X" shows the source account instead of the destination.

## Relationship to primaryAmount Removal (#10)

The `primaryAmount` removal (issue #10) introduces several shared infrastructure changes that this plan depends on:

1. **`TransactionWithBalance` gains account context** — `convertedLegs`, `displayAmount`, and `legs(forAccount:)` are added. The `withRunningBalances` method gains an `accountId: UUID?` parameter.
2. **`Transaction.isSimple`** — a reusable check for whether a transaction has simple structure (single leg or symmetric two-leg transfer).
3. **TransactionRowView receives `TransactionWithBalance`** — the row view will be refactored to use `displayAmount` rather than accessing `transaction.primaryAmount` directly.

This plan should be implemented **after** the `primaryAmount` removal lands, since TransactionRowView will already have the account context available via `TransactionWithBalance`.

If implemented before #10 lands, the TransactionRowView changes would need an explicit `viewingAccountId` parameter added temporarily, which #10 would then supersede.

## Call Sites

### Production Code

| # | Location | Current Usage | Replacement |
|---|----------|---------------|-------------|
| P1 | `TransactionRowView.swift:103` | Finds "other" account for "Transfer to X" label | Use viewing account from `TransactionWithBalance` context |
| P2 | `TransactionDetailView.swift:423` | Autofill: finds destination account of prior transfer | Use `draft.accountId` (already available) |
| P3 | `TransactionDTO.swift:86` | Maps to `TransactionDTO.accountId` | Use `legs.first?.accountId` directly |
| P4 | `TransactionDTO.swift:142` | Maps to `CreateTransactionDTO.accountId` | Use `legs.first?.accountId` directly |

### Test Code

| # | Location | Current Usage | Replacement |
|---|----------|---------------|-------------|
| T1 | `TransactionDraftTests.swift:188` | Round-trip assertion | Use `legs.first?.accountId` |
| T2 | `TransactionStoreTests.swift:49` | Verifies loaded txns belong to filtered account | Use `legs.first?.accountId` or `legs.contains(where:)` |
| T3 | `TransactionStoreTests.swift:648,652` | Transfer "other account" after update | Use `legs.first(where: { $0.accountId != accountId })` with test's known account |
| T4 | `TransactionStoreTests.swift:709,712` | Transfer toAccount change verification | Same as T3 |
| T5 | `TransactionStoreTests.swift:755,756` | From-account change verification | Use `legs.first?.accountId` |
| T6 | `TransactionStoreTests.swift:1035,1039,1091,1095` | Type change (expense↔transfer) verification | Same as T3 |
| T7 | `TransactionStoreTests.swift:1367,1369` | Pay scheduled transfer verification | Use `legs.first?.accountId` and known `accountId` |
| T8 | `TransactionStoreTests.swift:1658,1675` | Create default account verification | Use `legs.first?.accountId` |
| T9 | `RemoteTransactionRepositoryTests.swift:277` | Earmark-only income has nil account | Use `legs.first?.accountId` |

## Design

### Pattern 1: DTO Mapping (P3, P4) — `legs.first?.accountId`

The Remote API uses source-oriented semantics. The server's `accountId` field always refers to the source account, which is always `legs.first`. Replace `primaryAccountId` with `legs.first?.accountId` directly. This is semantically correct because `TransactionDTO.fromDomain` already uses `legs.first` for `primaryLeg` on line 65.

Actually, both `TransactionDTO.fromDomain` and `CreateTransactionDTO.fromDomain` already compute `let primaryLeg = transaction.legs.first` on their first line and derive `transferLeg` relative to it. The `primaryAccountId` references on lines 86 and 142 can be replaced with `primaryLeg?.accountId`:

```swift
// TransactionDTO.fromDomain — line 86
accountId: primaryLeg?.accountId.map(ServerUUID.init),

// CreateTransactionDTO.fromDomain — line 142
accountId: primaryLeg?.accountId.map(ServerUUID.init),
```

This is the cleanest change — it reuses the local variable that's already there and makes the source-leg intent explicit.

### Pattern 2: Finding the "Other" Leg in Views (P1, P2)

The pattern `legs.first(where: { $0.accountId != transaction.primaryAccountId })` finds the transfer destination by excluding the source. This is subtly wrong for incoming transfers where the viewing account IS the destination — it labels them "Transfer to [source]".

**P1 — TransactionRowView.swift:103:**

After #10 lands, TransactionRowView will receive `TransactionWithBalance` which carries the viewing account context. Replace the pattern with:

```swift
// Given viewingAccountId from TransactionWithBalance context
let otherAccountId = transaction.legs.first(where: { $0.accountId != viewingAccountId })?.accountId
```

This correctly shows "Transfer to [destination]" when viewing from source, and "Transfer from [source]" when viewing from destination. The label text should also change from always saying "Transfer to" to saying "Transfer from" when appropriate:

```swift
if transaction.isTransfer,
  let viewingAccountId,
  let otherLeg = transaction.legs.first(where: { $0.accountId != viewingAccountId })
{
  let otherAccountName = accounts.by(id: otherLeg.accountId ?? UUID())?.name ?? "Unknown Account"
  let viewingLeg = transaction.legs.first(where: { $0.accountId == viewingAccountId })
  let isOutgoing = (viewingLeg?.quantity ?? 0) < 0
  let transferLabel = isOutgoing
    ? "Transfer to \(otherAccountName)"
    : "Transfer from \(otherAccountName)"
  // ...
}
```

**Dependency on #10:** If implemented before #10, TransactionRowView would need a new `viewingAccountId: UUID?` parameter threaded from the parent. After #10, this comes from the `TransactionWithBalance` context naturally.

**P2 — TransactionDetailView.swift:423:**

The autofill copies a prior transfer's destination account. `draft.accountId` is already available and represents the viewing/source account:

```swift
let matchTransferLeg =
  match.legs.count > 1
  ? match.legs.first(where: { $0.accountId != draft.accountId }) : nil
draft.toAccountId = matchTransferLeg?.accountId
```

This is a self-contained change with no dependency on #10.

### Pattern 3: Test Assertions (T1-T9) — Direct leg access

All test uses fall into two sub-patterns:

**Sub-pattern A — "What is the first leg's account?"** (T1, T2, T5, T7 partial, T8, T9):
Replace `primaryAccountId` with `legs.first?.accountId`. These tests create transactions with known leg order and are asserting the source leg's account.

**Sub-pattern B — "What is the other leg's account?"** (T3, T4, T6, T7 partial):
Replace `legs.first(where: { $0.accountId != txn?.primaryAccountId })` with `legs.first(where: { $0.accountId != accountId })` using the test's known `accountId` variable (already in scope in every test method).

## Implementation Steps

### Step 1: TransactionDetailView Autofill (P2)

**File:** `Features/Transactions/Views/TransactionDetailView.swift`

Replace line 423:
```swift
// Before
? match.legs.first(where: { $0.accountId != match.primaryAccountId }) : nil

// After
? match.legs.first(where: { $0.accountId != draft.accountId }) : nil
```

No new parameters needed. `draft.accountId` is the account the user is currently editing.

### Step 2: TransactionDTO Mapping (P3, P4)

**File:** `Backends/Remote/DTOs/TransactionDTO.swift`

Both `fromDomain` methods already have `let primaryLeg = transaction.legs.first`. Replace:

```swift
// Line 86 — TransactionDTO.fromDomain
accountId: primaryLeg?.accountId.map(ServerUUID.init),

// Line 142 — CreateTransactionDTO.fromDomain
accountId: primaryLeg?.accountId.map(ServerUUID.init),
```

### Step 3: TransactionRowView (P1) — After #10

**File:** `Features/Transactions/Views/TransactionRowView.swift`

After #10 refactors TransactionRowView to accept `TransactionWithBalance`, the viewing account ID will be available. Update the "Transfer to X" label to use the viewing account context instead of `primaryAccountId`. Also improve the label to say "Transfer from X" for incoming transfers.

If implementing before #10 lands, add a `viewingAccountId: UUID?` parameter to TransactionRowView and thread it from parent views.

### Step 4: Test Updates (T1-T9)

**Files:**
- `MoolahTests/Shared/TransactionDraftTests.swift` (line 188)
- `MoolahTests/Features/TransactionStoreTests.swift` (lines 49, 648, 652, 709, 712, 755, 756, 1035, 1039, 1091, 1095, 1367, 1369, 1658, 1675)
- `MoolahTests/Backends/RemoteTransactionRepositoryTests.swift` (line 277)

Apply sub-pattern A or B as described above. Each test already has the account IDs in scope as local variables.

### Step 5: Delete the Accessor

**File:** `Domain/Models/Transaction.swift`

Remove line 107:
```swift
var primaryAccountId: UUID? { legs.first?.accountId }
```

### Step 6: Update BUGS.md

Remove the `primaryAccountId → legs.first?.accountId` line from the "Transaction convenience accessors" bug entry. If all other accessors have been removed by this point, remove the entire bug entry.

## Ordering Recommendation

Steps 2, 4 (sub-pattern A tests), and the autofill change in step 1 can be done **immediately** — they have no dependency on #10.

Step 3 (TransactionRowView) and step 4 (sub-pattern B tests that verify "other account" in transfer context) are best done **after #10 lands**, since the row view will already be refactored to receive account context.

If implementing standalone before #10:
1. Add `viewingAccountId: UUID?` parameter to `TransactionRowView`
2. Thread it from `TransactionListView` (the parent that has `filter.accountId`)
3. After #10 lands, the parameter gets replaced by `TransactionWithBalance` context

## Risk Assessment

**Low risk.** The accessor is a trivial computed property (`legs.first?.accountId`). Every replacement is a direct substitution of either:
- `legs.first?.accountId` (DTO mapping, simple test assertions)
- Filtering with an already-available account ID (view context, test local variables)

The only behavioral change is in TransactionRowView, where "Transfer to X" for incoming transfers currently shows the wrong account. The fix makes it show the correct account and use "Transfer from" when appropriate. This is a bug fix, not a behavior change.
