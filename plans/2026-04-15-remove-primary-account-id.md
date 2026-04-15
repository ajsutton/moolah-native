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

## Guiding Principle

No code should treat `legs.first` as semantically meaningful. Every access must identify the leg it wants by context (e.g., "the leg for this account", "the leg that isn't this account") rather than by position. The domain model must support arbitrary multi-leg transactions (stock trades, currency conversions within one account, complex splits), even though the Remote backend is limited to simple transactions today.

## Call Sites

### Production Code

| # | Location | Current Usage | Replacement Strategy |
|---|----------|---------------|----------------------|
| P1 | `TransactionRowView.swift:103` | Finds "other" account for "Transfer to X" label | Use viewing account context to find the other leg |
| P2 | `TransactionDetailView.swift:423` | Autofill: finds destination account of prior transfer | Use `draft.accountId` (already available) to find the other leg |
| P3 | `TransactionDTO.swift:86` | Maps to `TransactionDTO.accountId` | Guard `isSimple`, then find source leg by negative quantity |
| P4 | `TransactionDTO.swift:142` | Maps to `CreateTransactionDTO.accountId` | Same as P3 |

### Test Code

| # | Location | Current Usage | Replacement Strategy |
|---|----------|---------------|----------------------|
| T1 | `TransactionDraftTests.swift:188` | Round-trip assertion on account | Assert legs round-trip correctly (compare leg arrays or use `accountIds`) |
| T2 | `TransactionStoreTests.swift:49` | Verifies loaded txns belong to filtered account | Use `accountIds.contains(accountId)` |
| T3 | `TransactionStoreTests.swift:648,652` | Transfer "other account" after update | Use `legs.first(where: { $0.accountId != accountId })` with test's known account |
| T4 | `TransactionStoreTests.swift:709,712` | Transfer toAccount change verification | Same as T3 |
| T5 | `TransactionStoreTests.swift:755,756` | From-account change verification | Use `accountIds.contains(accountId)` |
| T6 | `TransactionStoreTests.swift:1035,1039,1091,1095` | Type change (expense↔transfer) verification | Same as T3 |
| T7 | `TransactionStoreTests.swift:1367,1369` | Pay scheduled transfer verification | Use `accountIds.contains(accountId)` and test's known IDs |
| T8 | `TransactionStoreTests.swift:1658,1675` | Create default account verification | Use `accountIds.contains(filterAccountId)` |
| T9 | `RemoteTransactionRepositoryTests.swift:277` | Earmark-only income has nil account | Use `accountIds.isEmpty` |

## Design

### Pattern 1: DTO Mapping (P3, P4) — Guard Simple, Then Decompose

The Remote backend communicates with moolah-server via a flat JSON format: `accountId` (source), `toAccountId` (destination), `amount` (source perspective). This flat format can only represent simple transactions — single-leg (income/expense/opening balance) or symmetric two-leg transfers. It cannot represent stock trades, currency conversions, or multi-leg splits.

Both `fromDomain` methods currently use `let primaryLeg = transaction.legs.first` — a positional assumption. They also depend on the `type`, `categoryId`, `earmarkId`, and `primaryAccountId` convenience accessors, coupling them to multiple items being removed under #9.

Refactor both methods to:

1. **Guard `isSimple`** (from #10) — return a validation error if the transaction can't be represented in the flat format. This makes the limitation explicit rather than silently producing wrong output for complex transactions.
2. **For single-leg transactions:** there's only one leg, so `legs.first` is unambiguous (it's the only leg, not a positional assumption).
3. **For two-leg transfers:** the source leg is the one with negative quantity (outgoing), the destination leg has positive quantity (incoming). This is safe because `isSimple` guarantees exactly two legs whose quantities negate each other.

```swift
static func fromDomain(_ transaction: Transaction) throws -> TransactionDTO {
  guard transaction.isSimple else {
    throw ValidationError.complexTransactionNotSupported
  }

  let dateString = BackendDateFormatter.string(from: transaction.date)

  // After isSimple guard: either 1 leg, or exactly 2 legs with negating quantities.
  let sourceLeg: TransactionLeg?
  let destinationLeg: TransactionLeg?

  if transaction.legs.count == 2 {
    sourceLeg = transaction.legs.first(where: { $0.quantity < 0 })
    destinationLeg = transaction.legs.first(where: { $0.quantity >= 0 })
  } else {
    sourceLeg = transaction.legs.first
    destinationLeg = nil
  }

  let cents = sourceLeg.map { centValue(from: $0.quantity) } ?? 0

  return TransactionDTO(
    id: ServerUUID(transaction.id),
    type: (sourceLeg?.type ?? .expense).rawValue,
    date: dateString,
    accountId: sourceLeg?.accountId.map(ServerUUID.init),
    toAccountId: destinationLeg?.accountId.map(ServerUUID.init),
    amount: cents,
    payee: transaction.payee,
    notes: transaction.notes,
    categoryId: sourceLeg?.categoryId.map(ServerUUID.init),
    earmark: sourceLeg?.earmarkId.map(ServerUUID.init),
    recurPeriod: transaction.recurPeriod?.rawValue,
    recurEvery: transaction.recurEvery
  )
}
```

This also removes the `fromDomain` methods' dependence on the `type`, `categoryId`, `earmarkId`, and `primaryAccountId` convenience accessors — unblocking their removal (#12, #13, #14) independently.

`CreateTransactionDTO.fromDomain` gets the same refactor.

**Signature change:** `fromDomain` becomes `throws`. Callers in the Remote backend already operate in async/throwing contexts, so propagating the error is straightforward. The Remote repository's save/create methods should surface this as a user-visible validation error ("This transaction type is not supported by the remote backend").

### Pattern 2: Finding the "Other" Leg in Views (P1, P2)

The pattern `legs.first(where: { $0.accountId != transaction.primaryAccountId })` finds the transfer destination by excluding the source. This is subtly wrong for incoming transfers where the viewing account IS the destination — it labels them "Transfer to [source]".

**P1 — TransactionRowView.swift:103:**

After #10 lands, TransactionRowView will receive `TransactionWithBalance` which carries the viewing account context. Replace the pattern with:

```swift
// Given viewingAccountId from TransactionWithBalance context
let otherLeg = transaction.legs.first(where: { $0.accountId != viewingAccountId })
```

This finds the "other" account relative to the viewer, not relative to position. The label text should also change from always saying "Transfer to" to saying "Transfer from" when appropriate:

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

The autofill copies a prior transfer's destination account. `draft.accountId` is already available and represents the account the user is editing from:

```swift
let matchTransferLeg =
  match.legs.count > 1
  ? match.legs.first(where: { $0.accountId != draft.accountId }) : nil
draft.toAccountId = matchTransferLeg?.accountId
```

This is a self-contained change with no dependency on #10. It finds the "other" leg relative to the editing account, not relative to position.

### Pattern 3: Test Assertions (T1-T9) — Assert by Role, Not Position

Tests should assert that a transaction **involves** a specific account, or find a leg **by its known account ID**, never by assuming position.

**Sub-pattern A — "Does this transaction involve account X?"** (T2, T5, T7 partial, T8):

Use the existing `accountIds` computed property (already on `Transaction`):

```swift
// Before
#expect(entry.transaction.primaryAccountId == accountId)

// After
#expect(entry.transaction.accountIds.contains(accountId))
```

For T5 (changing from-account), assert that the old transaction involved the old account and the new transaction involves the new account:
```swift
// Before
#expect(receivedOld?.primaryAccountId == accountId)
#expect(receivedNew?.primaryAccountId == newAccountId)

// After
#expect(receivedOld?.accountIds.contains(accountId) == true)
#expect(receivedNew?.accountIds.contains(newAccountId) == true)
```

**Sub-pattern B — "What is the other leg's account?"** (T3, T4, T6, T7 partial):

Replace `primaryAccountId` with the test's known `accountId` variable (already in scope). This finds the other leg by excluding a known account, not by position:

```swift
// Before
receivedOld?.legs.first(where: { $0.accountId != receivedOld?.primaryAccountId })?.accountId

// After
receivedOld?.legs.first(where: { $0.accountId != accountId })?.accountId
```

**Sub-pattern C — Round-trip and structural assertions** (T1, T9):

T1 (`TransactionDraftTests.swift:188`): The round-trip test currently asserts `primaryAccountId` matches. Replace with a structural assertion on the legs themselves:
```swift
// Before
#expect(roundTripped!.primaryAccountId == original.primaryAccountId)

// After
#expect(roundTripped!.legs.map(\.accountId) == original.legs.map(\.accountId))
```

T9 (`RemoteTransactionRepositoryTests.swift:277`): Asserts earmark-only income has no account. The test already asserts `legs[0].accountId == nil` on line 273. The `primaryAccountId == nil` assertion on line 277 is redundant — just delete it. The earlier line-by-line leg assertion is the correct approach.

## Implementation Steps

### Step 1: TransactionDTO Mapping (P3, P4)

**File:** `Backends/Remote/DTOs/TransactionDTO.swift`

1. Add `isSimple` guard (depends on #10 landing first, or add locally).
2. Change both `fromDomain` signatures to `throws`.
3. Refactor leg decomposition: single leg → `sourceLeg = legs.first`; two-leg transfer → source by negative quantity, destination by positive quantity.
4. Replace all convenience accessor usage (`type`, `categoryId`, `earmarkId`, `primaryAccountId`) with reads from `sourceLeg`.
5. Update callers in the Remote backend to handle the thrown error.

### Step 2: TransactionDetailView Autofill (P2)

**File:** `Features/Transactions/Views/TransactionDetailView.swift`

Replace line 423:
```swift
// Before
? match.legs.first(where: { $0.accountId != match.primaryAccountId }) : nil

// After
? match.legs.first(where: { $0.accountId != draft.accountId }) : nil
```

No new parameters needed. `draft.accountId` is the account the user is editing from.

### Step 3: TransactionRowView (P1) — After #10

**File:** `Features/Transactions/Views/TransactionRowView.swift`

After #10 refactors TransactionRowView to accept `TransactionWithBalance`, the viewing account ID will be available. Update the "Transfer to X" label to use the viewing account context instead of `primaryAccountId`. Also improve the label to say "Transfer from X" for incoming transfers.

If implementing before #10 lands, add a `viewingAccountId: UUID?` parameter to TransactionRowView and thread it from parent views.

### Step 4: Test Updates (T1-T9)

**Files:**
- `MoolahTests/Shared/TransactionDraftTests.swift` (line 188) — sub-pattern C
- `MoolahTests/Features/TransactionStoreTests.swift` (lines 49, 648, 652, 709, 712, 755, 756, 1035, 1039, 1091, 1095, 1367, 1369, 1658, 1675) — sub-patterns A and B
- `MoolahTests/Backends/RemoteTransactionRepositoryTests.swift` (line 277) — sub-pattern C (delete redundant assertion)

Each test already has account IDs in scope as local variables. No test needs positional leg access.

### Step 5: Delete the Accessor

**File:** `Domain/Models/Transaction.swift`

Remove line 107:
```swift
var primaryAccountId: UUID? { legs.first?.accountId }
```

### Step 6: Update BUGS.md

Remove the `primaryAccountId → legs.first?.accountId` line from the "Transaction convenience accessors" bug entry. If all other accessors have been removed by this point, remove the entire bug entry.

## Ordering Recommendation

Steps 1, 2, 4, and most test updates can be done **immediately** — they have no dependency on #10.

Step 3 (TransactionRowView) is best done **after #10 lands**, since the row view will already be refactored to receive account context via `TransactionWithBalance`.

If implementing standalone before #10:
1. Add `viewingAccountId: UUID?` parameter to `TransactionRowView`
2. Thread it from `TransactionListView` (the parent that has `filter.accountId`)
3. After #10 lands, the parameter gets replaced by `TransactionWithBalance` context

## Risk Assessment

**Low risk.** Every replacement uses either:
- The `isSimple` guard + quantity-sign decomposition (DTO only — safe because `isSimple` guarantees the structure)
- A known account ID from the calling context to find the relevant leg
- `accountIds` set membership to check transaction involvement

The DTO refactor is the largest change: `fromDomain` becomes throwing, callers must handle the error. This is well-constrained — the Remote backend already operates in throwing contexts, and the guard makes the flat-format limitation explicit instead of silently producing wrong output for complex transactions.

The TransactionRowView change also fixes the existing bug where "Transfer to X" for incoming transfers shows the wrong account.
