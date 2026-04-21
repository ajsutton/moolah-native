# Remove Transaction.type Convenience Accessor

**Issue:** #12 (Parent: #9)
**Assumes:** #11 (primaryAccountId removal) is complete — `isSimple`, `sourceLeg` DTO pattern, and `TransactionWithBalance` with viewing account context all exist.

## Definition

```swift
var type: TransactionType { legs.first?.type ?? .expense }
```

## Problem

`type` returns the first leg's type with a silent `.expense` fallback on empty legs. For simple transactions all legs share the same type, so `legs.first?.type` is always correct. But for complex transactions (e.g. a stock trade with two `.transfer` legs and one `.expense` fee leg), different legs can have different types. The accessor hides this and the `.expense` fallback could mask bugs.

## Call Sites

### Production Code

| # | Location | Current Usage | Status |
|---|----------|---------------|--------|
| P1 | `TransactionRowView.swift:74` | `iconName`: selects icon based on `transaction.type` | Needs change |
| P2 | `TransactionRowView.swift:83` | `iconColor`: selects color based on `transaction.type` | Needs change |
| P3 | `TransactionRowView.swift:23` | Accessibility label: `transaction.type.rawValue.capitalized` | Needs change |
| P4 | `TransactionDetailView.swift:165` | Guards editing: `transaction.type == .openingBalance` | Needs change |
| P5 | `TransactionDTO.swift:84` | DTO mapping | Already handled by #11 (`sourceLeg?.type`) |
| P6 | `TransactionDTO.swift:140` | DTO mapping | Already handled by #11 (`sourceLeg?.type`) |

### Test Code

| # | Location | Current Usage |
|---|----------|---------------|
| T1 | `TransactionDraftTests.swift:186` | Round-trip assertion |
| T2 | `RemoteTransactionRepositoryTests.swift:48` | Decoded expense type |
| T3 | `RemoteTransactionRepositoryTests.swift:55` | Decoded income type |
| T4 | `RemoteTransactionRepositoryTests.swift:60` | Decoded transfer type |
| T5 | `TransactionRepositoryContractTests.swift:143` | Updated transfer type |
| T6 | `TransactionRepositoryContractTests.swift:165` | Fetched transfer type |
| T7 | `TransactionRepositoryContractTests.swift:360` | Destination account filter includes transfer |

## Design

### Simple vs Complex

For icon, color, and accessibility label the logic branches on `isSimple`:

- **Simple** (`isSimple == true`): all legs share one type. Use the existing type-based icons.
- **Complex** (`isSimple == false`): legs have mixed types. Use a new dedicated icon.

### TransactionRowView (P1, P2, P3) — Icon, Color, Accessibility

Replace the switch on `transaction.type` with a branch on `isSimple`:

**iconName (P1):**

```swift
private var iconName: String {
    guard transaction.isSimple, let type = transaction.legs.first?.type else {
        return "arrow.trianglehead.branch"
    }
    switch type {
    case .income: return "arrow.up"
    case .expense: return "arrow.down"
    case .transfer: return "arrow.left.arrow.right"
    case .openingBalance: return "flag.fill"
    }
}
```

**iconColor (P2):**

```swift
private var iconColor: Color {
    guard transaction.isSimple, let type = transaction.legs.first?.type else {
        return .purple
    }
    switch type {
    case .income: return .green
    case .expense: return .red
    case .transfer: return .blue
    case .openingBalance: return .orange
    }
}
```

`.purple` is visually distinct from the existing four transaction-type colors and maintains the same vibrancy. Document `.purple` as the semantic color for complex/multi-leg transactions in `guides/UI_GUIDE.md`.

**accessibility — update `accessibilityDescription` (P3):**

The icon's `.accessibilityLabel` is consumed by `.accessibilityElement(children: .combine)` on the parent `HStack` and is never read by VoiceOver independently. The fix belongs in `accessibilityDescription`, which is the actual VoiceOver label for the row. Remove the per-icon `.accessibilityLabel` and add type information to the combined label using `TransactionType.displayName` (not `.rawValue.capitalized`, which produces "Openingbalance" for `.openingBalance`):

```swift
private var accessibilityDescription: String {
    let dateStr = transaction.date.formatted(date: .abbreviated, time: .omitted)
    let amountStr = displayAmount.formatted
    let balanceStr = balance.formatted
    let typeStr: String
    if transaction.isSimple, let type = transaction.legs.first?.type {
        typeStr = type.displayName
    } else {
        typeStr = "Complex transaction"
    }
    return "\(typeStr), \(displayPayee), \(amountStr), \(dateStr), balance \(balanceStr)"
}
```

### TransactionDetailView (P4) — Opening Balance Guard

The current check prevents editing opening balance transactions:

```swift
if transaction.type == .openingBalance {
    // show non-editable view
}
```

Opening balance transactions are always simple (single leg). Replace with a leg-level check:

```swift
if transaction.legs.contains(where: { $0.type == .openingBalance }) {
    // show non-editable view
}
```

This is more robust — it doesn't assume leg ordering and correctly identifies an opening balance regardless of position.

### Test Assertions — Assert on Legs

All test assertions should use leg-level access.

**T1** (`TransactionDraftTests.swift:186`): Compare type structures across legs:
```swift
#expect(roundTripped!.legs.map(\.type) == original.legs.map(\.type))
```

**T2–T4** (`RemoteTransactionRepositoryTests.swift:48,55,60`): Decoded transactions. These are simple (single-leg or two-leg transfer), so `legs.first?.type` is the direct replacement:
```swift
#expect(transactions[0].legs.first?.type == .expense)
#expect(transactions[1].legs.first?.type == .income)
#expect(transactions[2].legs.first?.type == .transfer)
```

**T5, T6** (`TransactionRepositoryContractTests.swift:143,165`): Transfer type persisted:
```swift
#expect(result.legs.allSatisfy { $0.type == .transfer })
#expect(fetched.legs.allSatisfy { $0.type == .transfer })
```

Using `allSatisfy` is stronger than checking `legs.first` — it verifies all legs in the transfer have the correct type.

**T7** (`TransactionRepositoryContractTests.swift:360`): Destination account filter includes transfer:
```swift
#expect(destPage.transactions[0].legs.allSatisfy { $0.type == .transfer })
```

## Implementation Steps

### Step 1: TransactionRowView (P1, P2, P3)

Branch `iconName` and `iconColor` on `isSimple` — simple transactions use the existing type switch on `legs.first?.type`, complex transactions use `"arrow.trianglehead.branch"` icon with `.purple` color. Document `.purple` as the semantic color for complex transactions in `guides/UI_GUIDE.md`. Remove the per-icon `.accessibilityLabel` and add type information to `accessibilityDescription` using `.displayName`. Add a complex transaction row to the `#Preview` block so the new icon path has visual coverage.

### Step 2: TransactionDetailView (P4)

Replace `transaction.type == .openingBalance` with `transaction.legs.contains(where: { $0.type == .openingBalance })`.

### Step 3: Test Updates (T1–T7)

Update all assertions to use leg-level access as described above.

### Step 4: Delete the Accessor

Remove from `Domain/Models/Transaction.swift`:
```swift
var type: TransactionType { legs.first?.type ?? .expense }
```

### Step 5: Update BUGS.md

Remove the `type → legs.first?.type` line from the convenience accessor bug entry.

### Step 6: UI Review

Run the `ui-review` agent on TransactionRowView and any other modified views. Fix all issues before merging.

## Risk Assessment

**Low risk.** All legs in a simple transaction share the same type, so the replacement logic produces identical results for every currently-possible transaction. The only new behavior is that complex transactions (which don't exist in production yet) will show a distinct icon instead of inheriting the first leg's type. The `.expense` fallback on empty legs is removed — empty legs would show the branching arrow icon in `.purple`, which is a safer failure mode than silently defaulting to expense.
