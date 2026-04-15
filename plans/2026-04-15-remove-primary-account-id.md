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
| P1 | `TransactionRowView.swift:103` | Finds "other" account for "Transfer to X" label | Simple: show "Transfer to/from X" using viewing account; Complex: show sub-transaction count |
| P2 | `TransactionDetailView.swift:423` | Autofill: finds destination account of prior transfer | Guard `isSimple`, then use `draft.accountId` to find the other leg |
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

### Pattern 2: Display Labels in Views (P1, P2)

These call sites use `primaryAccountId` to find the "other" leg and build a "Transfer to X" label. They assume exactly two legs. Complex transactions (stock trades, currency conversions, multi-leg splits) need a different display path.

**P1 — TransactionRowView.swift:103 (`displayPayee`):**

The current logic: if transfer, find the leg whose account isn't `primaryAccountId`, show "Transfer to [that account]". This breaks for:
- Incoming transfers (shows wrong direction)
- Multi-leg transactions (more than one "other" leg)
- Same-account transactions like currency conversions (both legs have the same account)

Replace with a three-branch approach using `isSimple` (from #10) and the viewing account context:

```swift
if transaction.isSimple, transaction.isTransfer,
  let viewingAccountId,
  let otherLeg = transaction.legs.first(where: { $0.accountId != viewingAccountId })
{
  // Simple transfer: show direction relative to the viewer
  let otherAccountName = accounts.by(id: otherLeg.accountId ?? UUID())?.name ?? "Unknown Account"
  let viewingLeg = transaction.legs.first(where: { $0.accountId == viewingAccountId })
  let isOutgoing = (viewingLeg?.quantity ?? 0) < 0
  let transferLabel = isOutgoing
    ? "Transfer to \(otherAccountName)"
    : "Transfer from \(otherAccountName)"
  // ...
} else if !transaction.isSimple {
  // Complex transaction: show sub-transaction count
  let label = "\(transaction.legs.count) sub-transactions"
  // ...
}
```

For complex transactions the payee (if set) is still shown as the primary label, with the sub-transaction count as supplementary context. If no payee, the sub-transaction count becomes the primary label.

**Dependency on #10:** Requires `isSimple` and the viewing account context from `TransactionWithBalance`.

**P2 — TransactionDetailView.swift:423 (autofill):**

The autofill copies a prior transfer's destination account. This only makes sense for simple transfers — if the matched transaction is complex, autofill should skip the `toAccountId` field rather than guessing.

```swift
if match.isSimple, draft.type == .transfer, draft.toAccountId == nil {
  let matchTransferLeg = match.legs.first(where: { $0.accountId != draft.accountId })
  draft.toAccountId = matchTransferLeg?.accountId
}
```

`draft.accountId` is already available and represents the account the user is editing from. The `isSimple` guard ensures we only autofill when the structure is unambiguous. The real fix — populating the draft with the full leg structure from the source transaction — is tracked in #16.

### Pattern 3: Test Assertions (T1-T9) — Assert by Known Account ID

Tests should assert that a transaction involves a specific account using the account ID the test already knows, never by assuming leg position.

**Sub-pattern A — "Does this transaction involve account X?"** (T2, T5, T7 partial, T8):

Use the existing `accountIds` computed property:

```swift
// Before
#expect(entry.transaction.primaryAccountId == accountId)

// After
#expect(entry.transaction.accountIds.contains(accountId))
```

For T5 (changing from-account on a single-leg expense), the test creates a one-leg transaction and changes its account. Assert the old transaction involved the old account and the new one involves the new account:
```swift
#expect(receivedOld?.accountIds.contains(accountId) == true)
#expect(receivedNew?.accountIds.contains(newAccountId) == true)
```

**Sub-pattern B — "What is the other leg's account?"** (T3, T4, T6, T7 partial):

These tests create simple transfers with known account IDs, then verify the "other" account after mutations. Replace `primaryAccountId` with the test's known `accountId` variable:

```swift
// Before
receivedOld?.legs.first(where: { $0.accountId != receivedOld?.primaryAccountId })?.accountId

// After
receivedOld?.legs.first(where: { $0.accountId != accountId })?.accountId
```

This works because these tests construct simple two-leg transfers where `accountId` is one of the two accounts. The filter finds the other one by exclusion from the known value, not from position.

**Sub-pattern C — Round-trip and structural assertions** (T1, T9):

T1 (`TransactionDraftTests.swift:188`): The round-trip test currently asserts `primaryAccountId` matches. Replace with a structural assertion on the legs:
```swift
// Before
#expect(roundTripped!.primaryAccountId == original.primaryAccountId)

// After
#expect(roundTripped!.legs.map(\.accountId) == original.legs.map(\.accountId))
```

T9 (`RemoteTransactionRepositoryTests.swift:277`): Asserts earmark-only income has no account. The test already asserts `legs[0].accountId == nil` on line 273. The `primaryAccountId == nil` assertion on line 277 is redundant — delete it.

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

Guard `isSimple` before autofilling `toAccountId`. Use `draft.accountId` to find the other leg:
```swift
// Before
let matchTransferLeg =
  match.legs.count > 1
  ? match.legs.first(where: { $0.accountId != match.primaryAccountId }) : nil
draft.toAccountId = matchTransferLeg?.accountId

// After
if match.isSimple, draft.type == .transfer, draft.toAccountId == nil {
  let matchTransferLeg = match.legs.first(where: { $0.accountId != draft.accountId })
  draft.toAccountId = matchTransferLeg?.accountId
}
```

### Step 3: TransactionRowView (P1) — After #10

**File:** `Features/Transactions/Views/TransactionRowView.swift`

Rewrite the `displayPayee` transfer label logic with three branches:
1. **Simple transfer:** Use viewing account context to find the other account, show "Transfer to/from X" based on quantity direction.
2. **Complex transaction:** Show "\(legs.count) sub-transactions" as the label. If payee is set, show payee with sub-transaction count as supplementary; if no payee, sub-transaction count is the primary label.
3. **Non-transfer (unchanged):** Show payee or earmark label as today.

Requires `isSimple` (from #10) and the viewing account context from `TransactionWithBalance`.

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

All steps depend on `isSimple` from #10. Implement after #10 lands, or add `isSimple` locally as a first step.

**Step order:**
1. Steps 1 (DTO) and 2 (autofill) can be done first — they only need `isSimple`.
2. Step 3 (TransactionRowView) needs both `isSimple` and the viewing account context from `TransactionWithBalance` (also from #10).
3. Step 4 (tests) can be done at any point — the test changes are independent of #10.
4. Steps 5 and 6 (delete accessor, update BUGS.md) go last, after all call sites are migrated.

## Risk Assessment

**Low risk.** Every replacement uses either:
- The `isSimple` guard + quantity-sign decomposition (DTO only — safe because `isSimple` guarantees the structure)
- A known account ID from the calling context to find the relevant leg
- `accountIds` set membership to check transaction involvement

The DTO refactor is the largest change: `fromDomain` becomes throwing, callers must handle the error. This is well-constrained — the Remote backend already operates in throwing contexts, and the guard makes the flat-format limitation explicit instead of silently producing wrong output for complex transactions.

The TransactionRowView change also fixes the existing bug where "Transfer to X" for incoming transfers shows the wrong account.
