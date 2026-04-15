# Remove Transaction.categoryId Convenience Accessor

**Issue:** #13 (Parent: #9)
**Assumes:** #11 (primaryAccountId removal) is complete — `isSimple`, `sourceLeg` DTO pattern, and `TransactionWithBalance` with viewing account context all exist.

## Definition

```swift
var categoryId: UUID? { legs.first?.categoryId }
```

## Problem

`categoryId` returns the first leg's category, hiding that category is a per-leg property. A complex transaction (stock trade with a brokerage fee, multi-leg split) can have different categories on different legs. The accessor silently returns only the first leg's value regardless of which legs are relevant to the viewing context.

## Call Sites

### Production Code

| # | Location | Current Usage | Status |
|---|----------|---------------|--------|
| P1 | `TransactionRowView.swift:91` | Shows category name in metadata row | Needs change |
| P2 | `TransactionDetailView.swift:47` | Prefills `categoryText` in init | Needs change |
| P3 | `TransactionDetailView.swift:410` | Autofill: copies category from prior tx | Needs change |
| P4 | `UpcomingView.swift:212` | Shows category name in upcoming row | Needs change |
| P5 | `TransactionDTO.swift:91` | DTO mapping | Already handled by #11 (`sourceLeg?.categoryId`) |
| P6 | `TransactionDTO.swift:147` | DTO mapping | Already handled by #11 (`sourceLeg?.categoryId`) |

### Test Code

| # | Location | Current Usage |
|---|----------|---------------|
| T1 | `TransactionDraftTests.swift:192` | Round-trip assertion |
| T2 | `TransactionStoreTests.swift:1374` | Pay scheduled tx preserves category |
| T3 | `TransactionRepositoryContractTests.swift:34` | Extracts categoryId for filter setup |
| T4 | `TransactionRepositoryContractTests.swift:45` | Filter result assertion |
| T5 | `TransactionRepositoryContractTests.swift:88` | Combined filter assertion |
| T6 | `TransactionRepositoryContractTests.swift:151` | Transfer preserves category |
| T7 | `TransactionRepositoryContractTests.swift:173` | Fetched transfer preserves category |
| T8 | `RemoteTransactionRepositoryTests.swift:52` | Decoded expense has category |

## Design

### Applicable Legs

Throughout this plan, "applicable legs" means:
- **Account-filtered context** (transaction list, detail view): legs whose `accountId` matches the viewing account.
- **Unfiltered context** (upcoming/scheduled views): all legs.

When multiple applicable legs have different categories, **show all unique categories**.

### TransactionRowView (P1) — Show All Applicable Categories

The current computed property returns a single optional string:

```swift
private var categoryName: String? {
    guard let categoryId = transaction.categoryId else { return nil }
    return categories.by(id: categoryId)?.name
}
```

Replace with a computed property that returns all unique category names from applicable legs:

```swift
private var categoryNames: [String] {
    let applicable = viewingAccountId.map { id in
        transaction.legs.filter { $0.accountId == id }
    } ?? transaction.legs

    let uniqueIds = applicable.compactMap(\.categoryId).uniqued()
    return uniqueIds.compactMap { categories.by(id: $0)?.name }
}
```

(`uniqueIds` preserves order of first appearance via a small `uniqued()` helper, or use `NSOrderedSet`, or `reduce(into:)`.)

In the view body, replace the single-category block:

```swift
// Before
if let categoryName {
    Text("·")
    Label(categoryName, systemImage: "tag")
        .labelStyle(.iconOnly)
        .imageScale(.small)
    Text(categoryName)
}

// After
ForEach(categoryNames, id: \.self) { name in
    Text("·")
    Label(name, systemImage: "tag")
        .labelStyle(.iconOnly)
        .imageScale(.small)
    Text(name)
}
```

Each category gets its own tag icon + name, separated by `·` from the date and from each other. This gracefully handles zero, one, or many categories.

### UpcomingView (P4) — Same Pattern, No Account Filter

Scheduled/upcoming transactions have no viewing account context. Use all legs:

```swift
let categoryIds = transaction.legs.compactMap(\.categoryId).uniqued()
```

Show all unique category names, same layout as TransactionRowView.

### TransactionDetailView Init (P2) — First Applicable Leg

The detail view is read-only for complex transactions (from #10). For the draft's `categoryText`, use the first applicable leg that has a category:

```swift
// Before
if let catId = transaction.categoryId, let cat = categories.by(id: catId) {
    initialDraft.categoryText = categories.path(for: cat)
}

// After
if let catId = transaction.legs.first(where: { $0.categoryId != nil })?.categoryId,
   let cat = categories.by(id: catId) {
    initialDraft.categoryText = categories.path(for: cat)
}
```

For simple transactions this finds the one leg with a category. For complex transactions the detail view is non-editable, so showing the first leg's category as display text is sufficient.

### TransactionDetailView Autofill (P3) — Guard isSimple

Full autofill rework is tracked in #16. For now, guard `isSimple` so we only autofill when the structure is unambiguous:

```swift
// Before
if draft.categoryId == nil, let matchCategoryId = match.categoryId {
    draft.categoryId = matchCategoryId
    ...
}

// After
if draft.categoryId == nil, match.isSimple,
   let matchCategoryId = match.legs.first(where: { $0.categoryId != nil })?.categoryId {
    draft.categoryId = matchCategoryId
    ...
}
```

### TransactionDraft.init(from:) — Per-Leg Access

Line 137 currently reads `categoryId: primaryLeg?.categoryId` where `primaryLeg = legs.first`. Replace with:

```swift
categoryId: transaction.legs.first(where: { $0.categoryId != nil })?.categoryId,
```

This finds the first leg that carries a category regardless of position. (Other fields in this init that still use `primaryLeg` are addressed by their respective issue plans.)

### Test Assertions — Assert on Legs

All test assertions should use leg-level access or `legs.contains(where:)` with the test's known categoryId.

**T1** (`TransactionDraftTests.swift:192`): Compare category structures across legs:
```swift
#expect(roundTripped!.legs.compactMap(\.categoryId) == original.legs.compactMap(\.categoryId))
```

**T2** (`TransactionStoreTests.swift:1374`): Paid tx preserves category:
```swift
#expect(paidTx?.legs.contains(where: { $0.categoryId == categoryId }) == true)
```

**T3** (`TransactionRepositoryContractTests.swift:34`): Extract categoryId for filter setup:
```swift
let groceryCategory = transactions[0].legs.first(where: { $0.categoryId != nil })!.categoryId!
```

**T4** (`TransactionRepositoryContractTests.swift:45`): Filter result has matching category:
```swift
#expect(transaction.legs.contains(where: { categoryIds.contains($0.categoryId ?? UUID()) }))
```

**T5** (`TransactionRepositoryContractTests.swift:88`): Combined filter assertion:
```swift
#expect(transaction.legs.contains(where: { $0.categoryId == groceryCategory }))
```

**T6, T7** (`TransactionRepositoryContractTests.swift:151,173`): Transfer preserves category:
```swift
#expect(result.legs.contains(where: { $0.categoryId == categoryId }))
#expect(fetched.legs.contains(where: { $0.categoryId == categoryId }))
```

**T8** (`RemoteTransactionRepositoryTests.swift:52`): Decoded expense has a category:
```swift
#expect(transactions[0].legs.contains(where: { $0.categoryId != nil }))
```

## Implementation Steps

### Step 1: TransactionRowView (P1)

Replace `categoryName: String?` with `categoryNames: [String]`. Update the view body to iterate. Requires viewing account context from `TransactionWithBalance`.

### Step 2: UpcomingView (P4)

Same pattern as step 1 but using all legs (no account filter).

### Step 3: TransactionDetailView (P2, P3)

- Init: use `legs.first(where: { $0.categoryId != nil })?.categoryId`.
- Autofill: add `isSimple` guard, use same leg-level access.

### Step 4: TransactionDraft.init(from:) 

Replace `primaryLeg?.categoryId` with `transaction.legs.first(where: { $0.categoryId != nil })?.categoryId`.

### Step 5: Test Updates (T1-T8)

Update all assertions to use leg-level access as described above.

### Step 6: Delete the Accessor

Remove from `Domain/Models/Transaction.swift`:
```swift
var categoryId: UUID? { legs.first?.categoryId }
```

### Step 7: Update BUGS.md

Remove the `categoryId → legs.first?.categoryId` line from the convenience accessor bug entry.

## Risk Assessment

**Low risk.** The accessor is a trivial computed property. Every production replacement either:
- Collects categories from applicable legs (views) — correct for both simple and complex transactions
- Finds the first leg with a category (detail view, draft init) — sufficient for read-only complex tx display
- Guards `isSimple` (autofill) — defers complex tx handling to #16

The only visible behavior change is that complex transactions with multiple categories will now show all of them instead of just the first leg's category. This is the correct behavior.
