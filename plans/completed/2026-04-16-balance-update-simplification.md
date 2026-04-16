# Balance Update Simplification Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the "Current Total reverts" and "Earmark balance doesn't update" bugs by centralising balance delta calculation, moving converted totals into stores, and thinning the sidebar view.

**Architecture:** A new `BalanceDeltaCalculator` computes per-instrument position deltas for accounts and earmarks in a single pass over transaction legs. Stores own their converted totals (async conversion results) instead of the view. The sidebar becomes a thin renderer of store state. Earmarks gain multi-instrument position tracking (like accounts already have) to prevent instrument-mixing crashes.

**Tech Stack:** Swift, SwiftUI, `@Observable`, Swift Testing (`@Test`/`@Suite`), XCTest (benchmarks)

---

## File Structure

**New files:**
- `Shared/BalanceDeltaCalculator.swift` — Pure struct, computes position deltas from transaction changes
- `MoolahTests/Shared/BalanceDeltaCalculatorTests.swift` — Comprehensive tests
- `MoolahBenchmarks/BalanceDeltaBenchmarks.swift` — Performance benchmarks

**Modified files:**
- `Domain/Models/Position.swift` — Remove `accountId` (owner is the containing entity)
- `Domain/Models/Earmark.swift` — Add `positions`, `savedPositions`, `spentPositions`; shared `adjustingPositions` logic
- `Domain/Models/Account.swift` — Replace `adjustingBalance` with shared `adjustingPositions`
- `Features/Accounts/AccountStore.swift` — `applyDelta`, own converted totals, remove `applyTransactionDelta`
- `Features/Earmarks/EarmarkStore.swift` — `applyDelta`, gain conversion service, own converted totals, remove `applyTransactionDelta`
- `Features/Transactions/TransactionStore.swift` — Direct store refs replace `onMutate` callback, use `BalanceDeltaCalculator`
- `App/ProfileSession.swift` — Remove `onMutate` wiring, pass stores to `TransactionStore`
- `Features/Navigation/SidebarView.swift` — Remove `@State` totals, `.task(id:)`, async methods
- `Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift` — Compute positions from legs, type-based saved/spent
- `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift` — Adapt to Position without accountId
- `MoolahTests/Features/AccountStoreTests.swift` — Update delta tests
- `MoolahTests/Features/EarmarkStoreTests.swift` — Update delta tests
- `MoolahTests/Features/TransactionStoreTests.swift` — Update onMutate tests to direct store wiring
- `MoolahTests/Domain/PositionTests.swift` — Update for accountId removal
- `MoolahTests/Support/TestBackend.swift` — Update earmark seeding for positions

---

### Task 1: Remove `accountId` from Position

Position is always stored inside an Account or Earmark, so the owner ID is redundant. Removing it allows Position to be reused for earmarks without semantic confusion.

**Files:**
- Modify: `Domain/Models/Position.swift`
- Modify: `MoolahTests/Domain/PositionTests.swift`
- Modify: `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift` (Position construction)

- [ ] **Step 1: Update Position tests to remove accountId**

In `MoolahTests/Domain/PositionTests.swift`, update all tests to remove `accountId` from Position construction and assertions. The `compute` method changes signature to take an `entityId` parameter (for filtering legs) but doesn't store it on the result.

```swift
@Test func initStoresProperties() {
  let pos = Position(instrument: aud, quantity: Decimal(string: "1500.00")!)
  #expect(pos.instrument == aud)
  #expect(pos.quantity == Decimal(string: "1500.00")!)
}

@Test func amount() {
  let pos = Position(instrument: aud, quantity: Decimal(string: "1500.00")!)
  #expect(pos.amount.quantity == Decimal(string: "1500.00")!)
  #expect(pos.amount.instrument == aud)
}

@Test func computeGroupsByInstrument() {
  let legs = [
    TransactionLeg(accountId: accountId, instrument: aud, quantity: Decimal(string: "100.00")!, type: .income),
    TransactionLeg(accountId: accountId, instrument: usd, quantity: Decimal(string: "50.00")!, type: .income),
    TransactionLeg(accountId: accountId, instrument: aud, quantity: Decimal(string: "25.00")!, type: .expense),
  ]
  let positions = Position.computeForAccount(accountId, from: legs)
  #expect(positions.count == 2)
  // sorted by instrument.id — AUD before USD
  #expect(positions[0].instrument == aud)
  #expect(positions[0].quantity == Decimal(string: "125.00")!)
  #expect(positions[1].instrument == usd)
  #expect(positions[1].quantity == Decimal(string: "50.00")!)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-position.txt`
Expected: FAIL — Position initialiser still requires accountId

- [ ] **Step 3: Update Position struct**

In `Domain/Models/Position.swift`:

```swift
/// A computed position for a specific instrument within an entity (account or earmark).
/// Derived from leg aggregation — not persisted.
struct Position: Hashable, Sendable {
  let instrument: Instrument
  let quantity: Decimal

  /// The quantity as an InstrumentAmount.
  var amount: InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: instrument)
  }

  /// Compute positions for a given account from a flat list of legs.
  /// Groups by instrument, sums quantities, excludes zero-quantity results.
  static func computeForAccount(_ accountId: UUID, from legs: [TransactionLeg]) -> [Position] {
    var totals: [Instrument: Decimal] = [:]
    for leg in legs where leg.accountId == accountId {
      totals[leg.instrument, default: 0] += leg.quantity
    }
    return totals.compactMap { instrument, quantity in
      guard quantity != 0 else { return nil }
      return Position(instrument: instrument, quantity: quantity)
    }.sorted { $0.instrument.id < $1.instrument.id }
  }

  /// Compute positions for a given earmark from a flat list of legs.
  /// Groups by instrument, sums quantities, excludes zero-quantity results.
  static func computeForEarmark(_ earmarkId: UUID, from legs: [TransactionLeg]) -> [Position] {
    var totals: [Instrument: Decimal] = [:]
    for leg in legs where leg.earmarkId == earmarkId {
      totals[leg.instrument, default: 0] += leg.quantity
    }
    return totals.compactMap { instrument, quantity in
      guard quantity != 0 else { return nil }
      return Position(instrument: instrument, quantity: quantity)
    }.sorted { $0.instrument.id < $1.instrument.id }
  }
}
```

- [ ] **Step 4: Fix all compilation errors from accountId removal**

Search for `Position(accountId:` and `position.accountId` across the codebase and update:

- `CloudKitAccountRepository.swift` `computePositions(from:context:)` — remove accountId from Position construction
- Any views referencing `position.accountId` — trace through containing account instead
- `Position.compute(for:from:)` calls — rename to `Position.computeForAccount(_:from:)`

- [ ] **Step 5: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-position.txt`
Expected: ALL PASS

- [ ] **Step 6: Clean up temp files and commit**

```bash
rm .agent-tmp/test-position.txt
git add Domain/Models/Position.swift MoolahTests/Domain/PositionTests.swift Backends/CloudKit/Repositories/CloudKitAccountRepository.swift
# Also add any other files changed in step 4
git commit -m "refactor: remove accountId from Position, add computeForEarmark"
```

---

### Task 2: BalanceDeltaCalculator

Pure struct that computes all balance deltas in a single pass over transaction legs. No dependencies on stores, repos, or SwiftUI.

**Files:**
- Create: `Shared/BalanceDeltaCalculator.swift`
- Create: `MoolahTests/Shared/BalanceDeltaCalculatorTests.swift`
- Modify: `project.yml` — add new files to targets if needed (run `just generate` after)

- [ ] **Step 1: Write BalanceDeltaCalculator tests**

Create `MoolahTests/Shared/BalanceDeltaCalculatorTests.swift`. These tests cover the full matrix of scenarios:

```swift
import Testing

@testable import Moolah

@Suite("BalanceDeltaCalculator")
struct BalanceDeltaCalculatorTests {
  let accountA = UUID()
  let accountB = UUID()
  let earmarkX = UUID()
  let earmarkY = UUID()
  let aud = Instrument.AUD
  let usd = Instrument.USD

  // MARK: - Account Deltas

  @Test func createExpenseProducesNegativeAccountDelta() {
    let tx = Transaction(
      date: Date(), payee: "Shop",
      legs: [TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense)]
    )
    let delta = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(delta.accountDeltas[accountA]?[aud] == -50)
    #expect(delta.earmarkDeltas.isEmpty)
  }

  @Test func createIncomeProducesPositiveAccountDelta() {
    let tx = Transaction(
      date: Date(), payee: "Salary",
      legs: [TransactionLeg(accountId: accountA, instrument: aud, quantity: 3000, type: .income)]
    )
    let delta = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(delta.accountDeltas[accountA]?[aud] == 3000)
  }

  @Test func deleteReversesAccountDelta() {
    let tx = Transaction(
      date: Date(), payee: "Shop",
      legs: [TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense)]
    )
    let delta = BalanceDeltaCalculator.deltas(old: tx, new: nil)
    #expect(delta.accountDeltas[accountA]?[aud] == 50) // reversed
  }

  @Test func updateAmountProducesDifference() {
    let oldTx = Transaction(
      id: UUID(), date: Date(), payee: "Shop",
      legs: [TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense)]
    )
    let newTx = Transaction(
      id: oldTx.id, date: Date(), payee: "Shop",
      legs: [TransactionLeg(accountId: accountA, instrument: aud, quantity: -80, type: .expense)]
    )
    let delta = BalanceDeltaCalculator.deltas(old: oldTx, new: newTx)
    // Old reversed: +50, new applied: -80, net: -30
    #expect(delta.accountDeltas[accountA]?[aud] == -30)
  }

  @Test func updateAccountMovesBalance() {
    let oldTx = Transaction(
      id: UUID(), date: Date(), payee: "Shop",
      legs: [TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense)]
    )
    let newTx = Transaction(
      id: oldTx.id, date: Date(), payee: "Shop",
      legs: [TransactionLeg(accountId: accountB, instrument: aud, quantity: -50, type: .expense)]
    )
    let delta = BalanceDeltaCalculator.deltas(old: oldTx, new: newTx)
    #expect(delta.accountDeltas[accountA]?[aud] == 50)   // old account gains back
    #expect(delta.accountDeltas[accountB]?[aud] == -50)  // new account loses
  }

  @Test func transferAffectsBothAccounts() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(accountId: accountA, instrument: aud, quantity: -100, type: .transfer),
        TransactionLeg(accountId: accountB, instrument: aud, quantity: 100, type: .transfer),
      ]
    )
    let delta = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(delta.accountDeltas[accountA]?[aud] == -100)
    #expect(delta.accountDeltas[accountB]?[aud] == 100)
  }

  @Test func multiInstrumentLegsProduceSeparateDeltas() {
    let tx = Transaction(
      date: Date(), payee: "Broker",
      legs: [
        TransactionLeg(accountId: accountA, instrument: aud, quantity: -1000, type: .transfer),
        TransactionLeg(accountId: accountA, instrument: usd, quantity: 650, type: .transfer),
      ]
    )
    let delta = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(delta.accountDeltas[accountA]?[aud] == -1000)
    #expect(delta.accountDeltas[accountA]?[usd] == 650)
  }

  @Test func scheduledTransactionProducesEmptyDelta() {
    let tx = Transaction(
      date: Date(), payee: "Rent", recurPeriod: .month, recurEvery: 1,
      legs: [TransactionLeg(accountId: accountA, instrument: aud, quantity: -1500, type: .expense)]
    )
    let delta = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(delta.accountDeltas.isEmpty)
    #expect(delta.earmarkDeltas.isEmpty)
  }

  @Test func scheduledOldNonScheduledNewAppliesOnlyNew() {
    let oldTx = Transaction(
      id: UUID(), date: Date(), payee: "Rent", recurPeriod: .month, recurEvery: 1,
      legs: [TransactionLeg(accountId: accountA, instrument: aud, quantity: -1500, type: .expense)]
    )
    let newTx = Transaction(
      id: oldTx.id, date: Date(), payee: "Rent",
      legs: [TransactionLeg(accountId: accountA, instrument: aud, quantity: -1500, type: .expense)]
    )
    let delta = BalanceDeltaCalculator.deltas(old: oldTx, new: newTx)
    #expect(delta.accountDeltas[accountA]?[aud] == -1500) // only new applied
  }

  // MARK: - Earmark Deltas

  @Test func earmarkExpenseProducesEarmarkDelta() {
    let tx = Transaction(
      date: Date(), payee: "Shop",
      legs: [TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense, earmarkId: earmarkX)]
    )
    let delta = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    // Account delta
    #expect(delta.accountDeltas[accountA]?[aud] == -50)
    // Earmark delta
    #expect(delta.earmarkDeltas[earmarkX]?[aud] == -50)
    // Earmark spent (expense type)
    #expect(delta.earmarkSpentDeltas[earmarkX]?[aud] == 50) // stored as positive
    #expect(delta.earmarkSavedDeltas.isEmpty)
  }

  @Test func earmarkIncomeProducesSavedDelta() {
    let tx = Transaction(
      date: Date(), payee: "Refund",
      legs: [TransactionLeg(accountId: accountA, instrument: aud, quantity: 100, type: .income, earmarkId: earmarkX)]
    )
    let delta = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(delta.earmarkDeltas[earmarkX]?[aud] == 100)
    #expect(delta.earmarkSavedDeltas[earmarkX]?[aud] == 100)
    #expect(delta.earmarkSpentDeltas.isEmpty)
  }

  @Test func earmarkTransferProducesSpentDelta() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(accountId: accountA, instrument: aud, quantity: -200, type: .transfer, earmarkId: earmarkX),
        TransactionLeg(accountId: accountB, instrument: aud, quantity: 200, type: .transfer),
      ]
    )
    let delta = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(delta.earmarkDeltas[earmarkX]?[aud] == -200)
    #expect(delta.earmarkSpentDeltas[earmarkX]?[aud] == 200)
  }

  @Test func earmarkOpeningBalanceProducesSavedDelta() {
    let tx = Transaction(
      date: Date(),
      legs: [TransactionLeg(accountId: accountA, instrument: aud, quantity: 500, type: .openingBalance, earmarkId: earmarkX)]
    )
    let delta = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(delta.earmarkDeltas[earmarkX]?[aud] == 500)
    #expect(delta.earmarkSavedDeltas[earmarkX]?[aud] == 500)
  }

  @Test func earmarkOnlyTransactionNoAccountDelta() {
    let tx = Transaction(
      date: Date(), payee: "Earmark funds",
      legs: [TransactionLeg(accountId: nil, instrument: aud, quantity: 300, type: .income, earmarkId: earmarkX)]
    )
    let delta = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(delta.accountDeltas.isEmpty)
    #expect(delta.earmarkDeltas[earmarkX]?[aud] == 300)
    #expect(delta.earmarkSavedDeltas[earmarkX]?[aud] == 300)
  }

  @Test func changeEarmarkMovesBalance() {
    let oldTx = Transaction(
      id: UUID(), date: Date(), payee: "Shop",
      legs: [TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense, earmarkId: earmarkX)]
    )
    let newTx = Transaction(
      id: oldTx.id, date: Date(), payee: "Shop",
      legs: [TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense, earmarkId: earmarkY)]
    )
    let delta = BalanceDeltaCalculator.deltas(old: oldTx, new: newTx)
    // Account unchanged (same account, same amount)
    #expect(delta.accountDeltas.isEmpty || delta.accountDeltas[accountA]?[aud] == 0)
    // Earmark X gets balance back
    #expect(delta.earmarkDeltas[earmarkX]?[aud] == 50)
    // Earmark Y gets the expense
    #expect(delta.earmarkDeltas[earmarkY]?[aud] == -50)
  }

  @Test func multiInstrumentEarmark() {
    let tx = Transaction(
      date: Date(), payee: "International",
      legs: [
        TransactionLeg(accountId: accountA, instrument: aud, quantity: -100, type: .expense, earmarkId: earmarkX),
        TransactionLeg(accountId: accountB, instrument: usd, quantity: -50, type: .expense, earmarkId: earmarkX),
      ]
    )
    let delta = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(delta.earmarkDeltas[earmarkX]?[aud] == -100)
    #expect(delta.earmarkDeltas[earmarkX]?[usd] == -50)
    #expect(delta.earmarkSpentDeltas[earmarkX]?[aud] == 100)
    #expect(delta.earmarkSpentDeltas[earmarkX]?[usd] == 50)
  }

  // MARK: - Edge Cases

  @Test func nilOldAndNilNewProducesEmptyDelta() {
    let delta = BalanceDeltaCalculator.deltas(old: nil, new: nil)
    #expect(delta.isEmpty)
  }

  @Test func legWithNoAccountOrEarmarkProducesNoDelta() {
    let tx = Transaction(
      date: Date(),
      legs: [TransactionLeg(accountId: nil, instrument: aud, quantity: 100, type: .income)]
    )
    let delta = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(delta.isEmpty)
  }

  @Test func zeroNetDeltasAreOmitted() {
    let oldTx = Transaction(
      id: UUID(), date: Date(), payee: "Same",
      legs: [TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense)]
    )
    // Same transaction unchanged
    let delta = BalanceDeltaCalculator.deltas(old: oldTx, new: oldTx)
    // Net is zero for accountA/AUD — should be omitted or zero
    let audDelta = delta.accountDeltas[accountA]?[aud] ?? 0
    #expect(audDelta == 0)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-delta.txt`
Expected: FAIL — `BalanceDeltaCalculator` not defined

- [ ] **Step 3: Write BalanceDeltaCalculator implementation**

Create `Shared/BalanceDeltaCalculator.swift`:

```swift
import Foundation

/// Position deltas keyed by entity ID and instrument.
typealias PositionDeltas = [UUID: [Instrument: Decimal]]

/// The result of computing balance deltas from a transaction change.
struct BalanceDelta: Equatable, Sendable {
  /// Per-account, per-instrument quantity changes.
  let accountDeltas: PositionDeltas
  /// Per-earmark, per-instrument quantity changes.
  let earmarkDeltas: PositionDeltas
  /// Per-earmark, per-instrument saved amounts (income + openingBalance legs).
  /// Stored as positive quantities.
  let earmarkSavedDeltas: PositionDeltas
  /// Per-earmark, per-instrument spent amounts (expense + transfer legs).
  /// Stored as positive quantities.
  let earmarkSpentDeltas: PositionDeltas

  static let empty = BalanceDelta(accountDeltas: [:], earmarkDeltas: [:], earmarkSavedDeltas: [:], earmarkSpentDeltas: [:])

  var isEmpty: Bool {
    accountDeltas.isEmpty && earmarkDeltas.isEmpty && earmarkSavedDeltas.isEmpty && earmarkSpentDeltas.isEmpty
  }
}

/// Computes position deltas from a transaction change (create, update, or delete).
///
/// A single pass over old and new transaction legs produces all account and earmark
/// deltas. Scheduled transactions are excluded (they don't affect balances).
enum BalanceDeltaCalculator {
  static func deltas(old: Transaction?, new: Transaction?) -> BalanceDelta {
    var accountDeltas: PositionDeltas = [:]
    var earmarkDeltas: PositionDeltas = [:]
    var earmarkSavedDeltas: PositionDeltas = [:]
    var earmarkSpentDeltas: PositionDeltas = [:]

    // Reverse old legs (skip scheduled transactions)
    if let old, !old.isScheduled {
      for leg in old.legs {
        if let accountId = leg.accountId {
          accountDeltas[accountId, default: [:]][leg.instrument, default: 0] -= leg.quantity
        }
        if let earmarkId = leg.earmarkId {
          earmarkDeltas[earmarkId, default: [:]][leg.instrument, default: 0] -= leg.quantity
          switch leg.type {
          case .income, .openingBalance:
            earmarkSavedDeltas[earmarkId, default: [:]][leg.instrument, default: 0] -= leg.quantity
          case .expense, .transfer:
            earmarkSpentDeltas[earmarkId, default: [:]][leg.instrument, default: 0] += leg.quantity
          }
        }
      }
    }

    // Apply new legs (skip scheduled transactions)
    if let new, !new.isScheduled {
      for leg in new.legs {
        if let accountId = leg.accountId {
          accountDeltas[accountId, default: [:]][leg.instrument, default: 0] += leg.quantity
        }
        if let earmarkId = leg.earmarkId {
          earmarkDeltas[earmarkId, default: [:]][leg.instrument, default: 0] += leg.quantity
          switch leg.type {
          case .income, .openingBalance:
            earmarkSavedDeltas[earmarkId, default: [:]][leg.instrument, default: 0] += leg.quantity
          case .expense, .transfer:
            earmarkSpentDeltas[earmarkId, default: [:]][leg.instrument, default: 0] -= leg.quantity
          }
        }
      }
    }

    // Clean up zero entries
    accountDeltas = accountDeltas.removingZeros()
    earmarkDeltas = earmarkDeltas.removingZeros()
    earmarkSavedDeltas = earmarkSavedDeltas.removingZeros()
    earmarkSpentDeltas = earmarkSpentDeltas.removingZeros()

    return BalanceDelta(
      accountDeltas: accountDeltas,
      earmarkDeltas: earmarkDeltas,
      earmarkSavedDeltas: earmarkSavedDeltas,
      earmarkSpentDeltas: earmarkSpentDeltas
    )
  }
}

private extension PositionDeltas {
  func removingZeros() -> PositionDeltas {
    var result: PositionDeltas = [:]
    for (entityId, instrumentDeltas) in self {
      let nonZero = instrumentDeltas.filter { $0.value != 0 }
      if !nonZero.isEmpty {
        result[entityId] = nonZero
      }
    }
    return result
  }
}
```

- [ ] **Step 4: Add new files to `project.yml` if needed, run `just generate`**

Check whether the `Shared/` and `MoolahTests/Shared/` source groups in `project.yml` use glob patterns (e.g. `Shared/**/*.swift`). If they do, no changes needed. If they list files explicitly, add the new files.

Run: `just generate`

- [ ] **Step 5: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-delta.txt`
Expected: ALL PASS

- [ ] **Step 6: Clean up temp files and commit**

```bash
rm .agent-tmp/test-delta.txt
git add Shared/BalanceDeltaCalculator.swift MoolahTests/Shared/BalanceDeltaCalculatorTests.swift
git commit -m "feat: add BalanceDeltaCalculator with comprehensive tests"
```

---

### Task 3: Shared `adjustingPositions` logic

Both `Accounts` and `Earmarks` collections need to apply position deltas to their entities. Extract a shared function that updates a `[Position]` array from `[Instrument: Decimal]` deltas.

**Files:**
- Modify: `Domain/Models/Position.swift` — add `applying(deltas:)` extension
- Modify: `MoolahTests/Domain/PositionTests.swift` — tests for applying deltas
- Modify: `Domain/Models/Account.swift` — `Accounts.adjustingPositions` replaces `adjustingBalance`
- Modify: `Domain/Models/Earmark.swift` — `Earmarks.adjustingPositions` added

- [ ] **Step 1: Write tests for Position delta application**

Add to `MoolahTests/Domain/PositionTests.swift`:

```swift
@Test func applyDeltasToEmptyPositions() {
  let positions: [Position] = []
  let result = positions.applying(deltas: [aud: Decimal(100)])
  #expect(result.count == 1)
  #expect(result[0].instrument == aud)
  #expect(result[0].quantity == 100)
}

@Test func applyDeltasToExistingPosition() {
  let positions = [Position(instrument: aud, quantity: 500)]
  let result = positions.applying(deltas: [aud: Decimal(-200)])
  #expect(result.count == 1)
  #expect(result[0].quantity == 300)
}

@Test func applyDeltasAddsNewInstrument() {
  let positions = [Position(instrument: aud, quantity: 500)]
  let result = positions.applying(deltas: [usd: Decimal(300)])
  #expect(result.count == 2)
  let audPos = result.first { $0.instrument == aud }
  let usdPos = result.first { $0.instrument == usd }
  #expect(audPos?.quantity == 500)
  #expect(usdPos?.quantity == 300)
}

@Test func applyDeltasRemovesZeroQuantityPosition() {
  let positions = [Position(instrument: aud, quantity: 500)]
  let result = positions.applying(deltas: [aud: Decimal(-500)])
  #expect(result.isEmpty)
}

@Test func applyDeltasSortedByInstrumentId() {
  let positions: [Position] = []
  let result = positions.applying(deltas: [usd: Decimal(100), aud: Decimal(200)])
  #expect(result.count == 2)
  #expect(result[0].instrument == aud) // AUD sorts before USD
  #expect(result[1].instrument == usd)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-position-delta.txt`
Expected: FAIL — `applying(deltas:)` not defined

- [ ] **Step 3: Implement `applying(deltas:)` extension**

Add to `Domain/Models/Position.swift`:

```swift
extension Array where Element == Position {
  /// Returns a new array with the given per-instrument deltas applied.
  /// Positions reaching zero quantity are removed. New instruments are added.
  /// Result is sorted by instrument ID.
  func applying(deltas: [Instrument: Decimal]) -> [Position] {
    var totals: [Instrument: Decimal] = [:]
    for position in self {
      totals[position.instrument, default: 0] += position.quantity
    }
    for (instrument, delta) in deltas {
      totals[instrument, default: 0] += delta
    }
    return totals.compactMap { instrument, quantity in
      guard quantity != 0 else { return nil }
      return Position(instrument: instrument, quantity: quantity)
    }.sorted { $0.instrument.id < $1.instrument.id }
  }
}
```

- [ ] **Step 4: Replace `Accounts.adjustingBalance` with `adjustingPositions`**

In `Domain/Models/Account.swift`, replace the `adjustingBalance` method on `Accounts`:

```swift
/// Returns a new Accounts collection with positions of the given account adjusted by instrument deltas.
/// Also updates the legacy `balance` field to the sum of all position quantities in the primary instrument.
func adjustingPositions(of accountId: UUID, by deltas: [Instrument: Decimal]) -> Accounts {
  guard byId[accountId] != nil else { return self }
  let adjusted = ordered.map { account in
    guard account.id == accountId else { return account }
    var copy = account
    copy.positions = copy.positions.applying(deltas: deltas)
    // Update legacy balance field: sum all position quantities
    // (This is only meaningful for single-instrument accounts; multi-instrument
    // accounts should use positions for display.)
    if let primaryPosition = copy.positions.first(where: { $0.instrument == copy.balance.instrument }) {
      copy.balance = primaryPosition.amount
    } else if copy.positions.isEmpty {
      copy.balance = .zero(instrument: copy.balance.instrument)
    }
    return copy
  }
  return Accounts(from: adjusted)
}
```

Keep the old `adjustingBalance` method temporarily until all callers are migrated (Task 6 will remove it).

- [ ] **Step 5: Add `adjustingPositions` to `Earmarks`**

In `Domain/Models/Earmark.swift`, add to the `Earmarks` collection:

```swift
/// Returns a new Earmarks collection with positions, savedPositions, and spentPositions adjusted.
func adjustingPositions(
  of earmarkId: UUID,
  positionDeltas: [Instrument: Decimal],
  savedDeltas: [Instrument: Decimal],
  spentDeltas: [Instrument: Decimal]
) -> Earmarks {
  guard byId[earmarkId] != nil else { return self }
  let adjusted = ordered.map { earmark in
    guard earmark.id == earmarkId else { return earmark }
    var copy = earmark
    copy.positions = copy.positions.applying(deltas: positionDeltas)
    copy.savedPositions = copy.savedPositions.applying(deltas: savedDeltas)
    copy.spentPositions = copy.spentPositions.applying(deltas: spentDeltas)
    return copy
  }
  return Earmarks(from: adjusted)
}
```

This requires the Earmark model to have `positions`, `savedPositions`, `spentPositions` fields — add them in this step (Task 4 covers the full model change, but the fields are needed now for compilation):

```swift
struct Earmark: ... {
  // ... existing fields ...
  var positions: [Position]
  var savedPositions: [Position]
  var spentPositions: [Position]
  // ... existing: balance, saved, spent remain for backward compat during migration ...
}
```

Update the `Earmark.init` to default these to `[]`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-position-delta.txt`
Expected: ALL PASS

- [ ] **Step 7: Clean up temp files and commit**

```bash
rm .agent-tmp/test-position-delta.txt
git add Domain/Models/Position.swift Domain/Models/Account.swift Domain/Models/Earmark.swift MoolahTests/Domain/PositionTests.swift
git commit -m "feat: add shared adjustingPositions logic for accounts and earmarks"
```

---

### Task 4: Earmark model — positions, savedPositions, spentPositions

Update the Earmark model to track multi-instrument state and update the CloudKit repository to compute positions from legs using transaction type for saved/spent.

**Files:**
- Modify: `Domain/Models/Earmark.swift` — full model update (may be partially done in Task 3)
- Modify: `Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift` — compute positions from legs
- Modify: `MoolahTests/Support/TestBackend.swift` — update earmark seeding
- Modify: `MoolahTests/Features/EarmarkStoreTests.swift` — update assertions for positions

- [ ] **Step 1: Update `CloudKitEarmarkRepository.computeEarmarkTotals` to compute positions**

Rename to `computeEarmarkPositions` and return position arrays instead of single-instrument amounts. Use transaction type (not sign) for saved/spent classification:

```swift
@MainActor
private func computeEarmarkPositions(for earmarkId: UUID) throws -> (
  positions: [Position], savedPositions: [Position], spentPositions: [Position]
) {
  let scheduledDescriptor = FetchDescriptor<TransactionRecord>(
    predicate: #Predicate { $0.recurPeriod != nil }
  )
  let scheduledIds = Set(try context.fetch(scheduledDescriptor).map(\.id))

  let eid = earmarkId
  let descriptor = FetchDescriptor<TransactionLegRecord>(
    predicate: #Predicate { $0.earmarkId == eid }
  )
  let legRecords = try context.fetch(descriptor)

  // Resolve instruments
  let instruments = try fetchInstrumentMap()

  var positionTotals: [Instrument: Decimal] = [:]
  var savedTotals: [Instrument: Decimal] = [:]
  var spentTotals: [Instrument: Decimal] = [:]

  for leg in legRecords {
    guard !scheduledIds.contains(leg.transactionId) else { continue }
    let inst = instruments[leg.instrumentId] ?? Instrument.fiat(code: leg.instrumentId)
    let quantity = InstrumentAmount(storageValue: leg.quantity, instrument: inst).quantity

    positionTotals[inst, default: 0] += quantity

    let type = TransactionType(rawValue: leg.type) ?? .expense
    switch type {
    case .income, .openingBalance:
      savedTotals[inst, default: 0] += quantity
    case .expense, .transfer:
      spentTotals[inst, default: 0] += abs(quantity)
    }
  }

  func toPositions(_ totals: [Instrument: Decimal]) -> [Position] {
    totals.compactMap { inst, qty in
      guard qty != 0 else { return nil }
      return Position(instrument: inst, quantity: qty)
    }.sorted { $0.instrument.id < $1.instrument.id }
  }

  return (toPositions(positionTotals), toPositions(savedTotals), toPositions(spentTotals))
}
```

Update `fetchAll` to use the new method:

```swift
func fetchAll() async throws -> [Earmark] {
  // ...
  return try await MainActor.run {
    let records = try context.fetch(descriptor)
    return try records.map { record in
      let (positions, savedPositions, spentPositions) = try computeEarmarkPositions(for: record.id)
      return record.toDomain(positions: positions, savedPositions: savedPositions, spentPositions: spentPositions)
    }.sorted()
  }
}
```

- [ ] **Step 2: Update `EarmarkRecord.toDomain` to accept positions**

Find the `EarmarkRecord.toDomain` method and update it to accept and pass through position arrays. The old `balance`, `saved`, `spent` parameters are replaced.

- [ ] **Step 3: Update `TestBackend.seedWithTransactions` for positions**

The seeding method in `MoolahTests/Support/TestBackend.swift` creates synthetic transactions to produce desired earmark state. Update it to work with the new position-based model. The earmark's `positions`, `savedPositions`, `spentPositions` arrays should be populated from the seeded transactions.

- [ ] **Step 4: Remove the old `Earmarks.adjustingBalance` method**

In `Domain/Models/Earmark.swift`, remove the old `adjustingBalance(of:by:)` method — it's replaced by `adjustingPositions(of:positionDeltas:savedDeltas:spentDeltas:)` from Task 3.

- [ ] **Step 5: Fix all compilation errors**

Search for `adjustingBalance` references on `Earmarks` and update callers. At this point the main caller is `EarmarkStore.applyTransactionDelta` — leave it compiling for now (Task 7 will replace it).

Also search for `earmark.balance`, `earmark.saved`, `earmark.spent` in views and update. These fields can remain on the model as computed properties that sum positions in a single instrument (for backward compat), or be removed if views are updated to use converted totals from the store.

**Recommended approach:** Keep `balance`, `saved`, `spent` as computed properties:

```swift
/// Legacy single-instrument balance. For multi-instrument earmarks, use positions instead.
var balance: InstrumentAmount {
  if let first = positions.first, positions.count == 1 {
    return first.amount
  }
  return .zero(instrument: positions.first?.instrument ?? .AUD)
}
```

But mark them clearly as legacy — the store's converted totals are the source of truth for display.

- [ ] **Step 6: Run tests**

Run: `just test 2>&1 | tee .agent-tmp/test-earmark-model.txt`
Expected: PASS (some earmark store tests may need adjusting)

- [ ] **Step 7: Clean up temp files and commit**

```bash
rm .agent-tmp/test-earmark-model.txt
git add Domain/Models/Earmark.swift Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift MoolahTests/Support/TestBackend.swift
git commit -m "feat: earmark model gains multi-instrument positions, type-based saved/spent"
```

---

### Task 5: AccountStore — applyDelta and converted totals

Move converted total computation from SidebarView into AccountStore. Replace `applyTransactionDelta` with `applyDelta` that uses the new position-based approach.

**Files:**
- Modify: `Features/Accounts/AccountStore.swift`
- Modify: `MoolahTests/Features/AccountStoreTests.swift`

- [ ] **Step 1: Update AccountStore tests for new delta API and converted totals**

In `MoolahTests/Features/AccountStoreTests.swift`, update the `applyTransactionDelta` tests to use the new `applyDelta` method that takes `PositionDeltas`. Also add tests for converted total properties.

Key test changes:
- Replace `store.applyTransactionDelta(old: nil, new: tx)` with `store.applyDelta(BalanceDeltaCalculator.deltas(old: nil, new: tx).accountDeltas)`
- Add tests that `store.convertedCurrentTotal` updates after `applyDelta`
- Add tests that `store.convertedCurrentTotal` is initially `nil`, populated after `load()`

```swift
@Test func applyDeltaAdjustsAccountBalance() async throws {
  let (backend, container) = try TestBackend.create()
  let store = AccountStore(repository: backend.accounts, conversionService: backend.conversionService)
  try await TestBackend.seed(
    accounts: [Account(id: accountId, name: "Bank", type: .bank, balance: InstrumentAmount(quantity: 1000, instrument: .defaultTestCurrency))],
    in: container
  )
  await store.load()

  let deltas: PositionDeltas = [accountId: [Instrument.defaultTestCurrency: Decimal(-50)]]
  store.applyDelta(deltas)

  #expect(store.accounts.by(id: accountId)?.balance.quantity == 950)
}

@Test func convertedCurrentTotalUpdatesAfterLoad() async throws {
  let (backend, container) = try TestBackend.create()
  let store = AccountStore(repository: backend.accounts, conversionService: backend.conversionService, targetInstrument: .defaultTestCurrency)
  try await TestBackend.seed(
    accounts: [Account(id: accountId, name: "Bank", type: .bank, balance: InstrumentAmount(quantity: 1000, instrument: .defaultTestCurrency))],
    in: container
  )

  #expect(store.convertedCurrentTotal == nil)
  await store.load()
  // Wait for async conversion to complete
  try await Task.sleep(for: .milliseconds(50))
  #expect(store.convertedCurrentTotal != nil)
  #expect(store.convertedCurrentTotal?.quantity == 1000)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-account-store.txt`
Expected: FAIL — `applyDelta` and `convertedCurrentTotal` not defined

- [ ] **Step 3: Implement AccountStore changes**

In `Features/Accounts/AccountStore.swift`:

1. Add `targetInstrument` parameter to init (needed for conversion)
2. Add stored properties for converted totals
3. Add `applyDelta` method
4. Add `recomputeConvertedTotals` method called from `load`, `reloadFromSync`, `applyDelta`, `updateInvestmentValue`
5. Remove old `applyTransactionDelta`

```swift
@Observable
@MainActor
final class AccountStore {
  private(set) var accounts: Accounts = Accounts(from: [])
  private(set) var isLoading = false
  private(set) var error: Error?

  // Converted totals (nil = not yet computed)
  private(set) var convertedCurrentTotal: InstrumentAmount?
  private(set) var convertedInvestmentTotal: InstrumentAmount?
  private(set) var convertedNetWorth: InstrumentAmount?

  private let repository: AccountRepository
  private let conversionService: (any InstrumentConversionService)?
  private let targetInstrument: Instrument
  private let logger = Logger(subsystem: "com.moolah.app", category: "AccountStore")
  private var conversionTask: Task<Void, Never>?

  init(
    repository: AccountRepository,
    conversionService: (any InstrumentConversionService)? = nil,
    targetInstrument: Instrument = .AUD
  ) {
    self.repository = repository
    self.conversionService = conversionService
    self.targetInstrument = targetInstrument
  }

  // ... existing load(), reloadFromSync() methods ...
  // Add recomputeConvertedTotals() call at end of load() and reloadFromSync()

  /// Applies position deltas to account balances.
  func applyDelta(_ accountDeltas: PositionDeltas) {
    var result = accounts
    for (accountId, instrumentDeltas) in accountDeltas {
      result = result.adjustingPositions(of: accountId, by: instrumentDeltas)
    }
    accounts = result
    recomputeConvertedTotals()
  }

  /// Recomputes converted totals asynchronously.
  /// Cancels any in-flight conversion. The previous value remains visible until the new one completes.
  private func recomputeConvertedTotals() {
    conversionTask?.cancel()
    conversionTask = Task {
      do {
        let current = try await convertedTotal(for: currentAccounts, in: targetInstrument)
        guard !Task.isCancelled else { return }
        let investment = try await convertedInvestmentTotal(in: targetInstrument)
        guard !Task.isCancelled else { return }
        convertedCurrentTotal = current
        convertedInvestmentTotal = investment
        convertedNetWorth = current + investment
      } catch {
        guard !Task.isCancelled else { return }
        logger.error("Failed to compute converted totals: \(error.localizedDescription)")
      }
    }
  }

  // ... keep existing convertedTotal(for:in:), convertedCurrentTotal(in:),
  // convertedInvestmentTotal(in:) methods for the internal recomputation ...
}
```

The key difference from the old SidebarView approach: **no nil-then-reload**. The old value stays visible until the new one is ready.

- [ ] **Step 4: Remove old `applyTransactionDelta` method**

Delete the `applyTransactionDelta(old:new:)` method from AccountStore. All callers will be updated in Task 7.

- [ ] **Step 5: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-account-store.txt`
Expected: PASS (some tests may have temp compilation errors until Task 7 removes callers)

If there are callers of the old `applyTransactionDelta` that prevent compilation, temporarily leave it as a deprecated wrapper:

```swift
@available(*, deprecated, message: "Use applyDelta with BalanceDeltaCalculator instead")
func applyTransactionDelta(old: Transaction?, new: Transaction?) {
  let delta = BalanceDeltaCalculator.deltas(old: old, new: new)
  applyDelta(delta.accountDeltas)
}
```

- [ ] **Step 6: Clean up temp files and commit**

```bash
rm .agent-tmp/test-account-store.txt
git add Features/Accounts/AccountStore.swift MoolahTests/Features/AccountStoreTests.swift
git commit -m "feat: AccountStore owns converted totals, applyDelta replaces applyTransactionDelta"
```

---

### Task 6: EarmarkStore — applyDelta and converted totals

Mirror the AccountStore changes for EarmarkStore. Add conversion service, own converted totals, replace `applyTransactionDelta`.

**Files:**
- Modify: `Features/Earmarks/EarmarkStore.swift`
- Modify: `MoolahTests/Features/EarmarkStoreTests.swift`

- [ ] **Step 1: Update EarmarkStore tests for new delta API**

Update tests to use `applyDelta` with position deltas. Add tests for converted total balance.

Key test changes:
- Replace `store.applyTransactionDelta(old: nil, new: tx)` calls
- Instead, compute delta with `BalanceDeltaCalculator.deltas(old: nil, new: tx)` and pass earmark deltas to `store.applyDelta`
- Assert on `store.earmarks.by(id:)?.positions` instead of `?.balance`
- Add tests for `store.convertedTotalBalance`

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-earmark-store.txt`
Expected: FAIL — new API not defined

- [ ] **Step 3: Implement EarmarkStore changes**

In `Features/Earmarks/EarmarkStore.swift`:

1. Add `conversionService` and `targetInstrument` to init
2. Add `convertedTotalBalance: InstrumentAmount?`
3. Add `applyDelta` method accepting earmark, saved, and spent position deltas
4. Add `recomputeConvertedTotals` called from `load`, `reloadFromSync`, `applyDelta`
5. Remove old `applyTransactionDelta`

```swift
@Observable
@MainActor
final class EarmarkStore {
  private(set) var earmarks: Earmarks = Earmarks(from: [])
  private(set) var isLoading = false
  private(set) var error: Error?
  private(set) var convertedTotalBalance: InstrumentAmount?

  private let repository: EarmarkRepository
  private let conversionService: (any InstrumentConversionService)?
  private let targetInstrument: Instrument
  private let logger = Logger(subsystem: "com.moolah.app", category: "EarmarkStore")
  private var conversionTask: Task<Void, Never>?

  // ... budget fields unchanged ...

  init(
    repository: EarmarkRepository,
    conversionService: (any InstrumentConversionService)? = nil,
    targetInstrument: Instrument = .AUD
  ) {
    self.repository = repository
    self.conversionService = conversionService
    self.targetInstrument = targetInstrument
  }

  /// Applies position deltas to earmark balances.
  func applyDelta(
    earmarkDeltas: PositionDeltas,
    savedDeltas: PositionDeltas,
    spentDeltas: PositionDeltas
  ) {
    var result = earmarks
    // Collect all affected earmark IDs
    let allIds = Set(earmarkDeltas.keys).union(savedDeltas.keys).union(spentDeltas.keys)
    for earmarkId in allIds {
      result = result.adjustingPositions(
        of: earmarkId,
        positionDeltas: earmarkDeltas[earmarkId] ?? [:],
        savedDeltas: savedDeltas[earmarkId] ?? [:],
        spentDeltas: spentDeltas[earmarkId] ?? [:]
      )
    }
    earmarks = result
    recomputeConvertedTotals()
  }

  private func recomputeConvertedTotals() {
    conversionTask?.cancel()
    conversionTask = Task {
      do {
        var total = InstrumentAmount.zero(instrument: targetInstrument)
        for earmark in visibleEarmarks {
          for position in earmark.positions {
            guard let conversionService else {
              total += position.amount
              continue
            }
            let converted = try await conversionService.convertAmount(
              position.amount, to: targetInstrument, on: Date())
            guard !Task.isCancelled else { return }
            total += converted
          }
        }
        convertedTotalBalance = total
      } catch {
        guard !Task.isCancelled else { return }
        logger.error("Failed to compute converted earmark totals: \(error.localizedDescription)")
      }
    }
  }

  // ... rest of store unchanged ...
}
```

- [ ] **Step 4: Add `recomputeConvertedTotals()` calls to `load()` and `reloadFromSync()`**

At the end of the `do` block in `load()` (after `earmarks = ...`) and in `reloadFromSync()` (after `earmarks = fresh`), add `recomputeConvertedTotals()`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-earmark-store.txt`
Expected: PASS

- [ ] **Step 6: Clean up temp files and commit**

```bash
rm .agent-tmp/test-earmark-store.txt
git add Features/Earmarks/EarmarkStore.swift MoolahTests/Features/EarmarkStoreTests.swift
git commit -m "feat: EarmarkStore owns converted totals, position-based applyDelta"
```

---

### Task 7: TransactionStore — direct store refs and BalanceDeltaCalculator

Replace the `onMutate` callback with direct store references. TransactionStore computes deltas via `BalanceDeltaCalculator` and applies them directly to AccountStore and EarmarkStore.

**Files:**
- Modify: `Features/Transactions/TransactionStore.swift`
- Modify: `App/ProfileSession.swift`
- Modify: `MoolahTests/Features/TransactionStoreTests.swift`

- [ ] **Step 1: Update TransactionStore tests**

Replace `onMutate` callback tests with tests that verify store state changes after create/update/delete. The TransactionStore now takes AccountStore and EarmarkStore as dependencies.

```swift
@Test func createTransactionUpdatesAccountBalance() async throws {
  let (backend, container) = try TestBackend.create()
  let accountStore = AccountStore(repository: backend.accounts, conversionService: backend.conversionService)
  let earmarkStore = EarmarkStore(repository: backend.earmarks, conversionService: backend.conversionService)
  let store = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .defaultTestCurrency,
    accountStore: accountStore,
    earmarkStore: earmarkStore
  )
  try await TestBackend.seed(
    accounts: [Account(id: accountId, name: "Bank", type: .bank, balance: InstrumentAmount(quantity: 1000, instrument: .defaultTestCurrency))],
    in: container
  )
  await accountStore.load()

  let tx = Transaction(
    date: Date(), payee: "Shop",
    legs: [TransactionLeg(accountId: accountId, instrument: .defaultTestCurrency, quantity: -50, type: .expense)]
  )
  await store.load(filter: TransactionFilter(accountId: accountId))
  _ = await store.create(tx)

  #expect(accountStore.accounts.by(id: accountId)?.balance.quantity == 950)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-txn-store.txt`
Expected: FAIL — TransactionStore init doesn't accept store refs

- [ ] **Step 3: Update TransactionStore implementation**

In `Features/Transactions/TransactionStore.swift`:

1. Replace `onMutate` callback with `accountStore` and `earmarkStore` properties
2. After each mutation (create/update/delete), compute and apply deltas
3. Remove `onMutate` property entirely

```swift
@Observable
@MainActor
final class TransactionStore {
  // ... existing properties ...

  // Replace: var onMutate: (...)? 
  // With:
  private let accountStore: AccountStore?
  private let earmarkStore: EarmarkStore?

  init(
    repository: TransactionRepository,
    conversionService: InstrumentConversionService,
    targetInstrument: Instrument,
    pageSize: Int = 50,
    accountStore: AccountStore? = nil,
    earmarkStore: EarmarkStore? = nil
  ) {
    self.repository = repository
    self.conversionService = conversionService
    self.targetInstrument = targetInstrument
    self.pageSize = pageSize
    self.accountStore = accountStore
    self.earmarkStore = earmarkStore
  }

  /// Applies balance deltas to account and earmark stores after a transaction mutation.
  private func applyBalanceDeltas(old: Transaction?, new: Transaction?) {
    let delta = BalanceDeltaCalculator.deltas(old: old, new: new)
    if !delta.accountDeltas.isEmpty {
      accountStore?.applyDelta(delta.accountDeltas)
    }
    if !delta.earmarkDeltas.isEmpty || !delta.earmarkSavedDeltas.isEmpty || !delta.earmarkSpentDeltas.isEmpty {
      earmarkStore?.applyDelta(
        earmarkDeltas: delta.earmarkDeltas,
        savedDeltas: delta.earmarkSavedDeltas,
        spentDeltas: delta.earmarkSpentDeltas
      )
    }
  }
  // ...
}
```

In `create()`, replace `onMutate?(nil, created)` with `applyBalanceDeltas(old: nil, new: created)`.

In `update()`, replace `onMutate?(old, updated)` with `applyBalanceDeltas(old: old, new: updated)`.

In `delete()`, replace `onMutate?(removed, nil)` with `applyBalanceDeltas(old: removed, new: nil)`.

- [ ] **Step 4: Update ProfileSession to pass stores**

In `App/ProfileSession.swift`:

1. Pass `accountStore` and `earmarkStore` to `TransactionStore` init
2. Remove the `onMutate` callback wiring (lines 126-129)

```swift
// Before:
self.transactionStore = TransactionStore(
  repository: backend.transactions,
  conversionService: backend.conversionService,
  targetInstrument: profile.instrument
)
// ... later ...
self.transactionStore.onMutate = { old, new in
  accountStore.applyTransactionDelta(old: old, new: new)
  earmarkStore.applyTransactionDelta(old: old, new: new)
}

// After:
self.transactionStore = TransactionStore(
  repository: backend.transactions,
  conversionService: backend.conversionService,
  targetInstrument: profile.instrument,
  accountStore: self.accountStore,
  earmarkStore: self.earmarkStore
)
// (no onMutate wiring needed)
```

Also update AccountStore init to pass `targetInstrument: profile.instrument` and EarmarkStore init to pass `conversionService` and `targetInstrument`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-txn-store.txt`
Expected: ALL PASS

- [ ] **Step 6: Remove deprecated applyTransactionDelta methods**

Remove `applyTransactionDelta` from both AccountStore and EarmarkStore if temporary wrappers were added. Remove the old `Accounts.adjustingBalance` method. Remove `onMutate` from TransactionStore entirely.

- [ ] **Step 7: Run tests again to confirm clean removal**

Run: `just test 2>&1 | tee .agent-tmp/test-txn-store.txt`
Expected: ALL PASS — no references to removed methods

- [ ] **Step 8: Clean up temp files and commit**

```bash
rm .agent-tmp/test-txn-store.txt
git add Features/Transactions/TransactionStore.swift App/ProfileSession.swift Features/Accounts/AccountStore.swift Features/Earmarks/EarmarkStore.swift MoolahTests/Features/TransactionStoreTests.swift
git commit -m "refactor: replace onMutate callback with direct store refs and BalanceDeltaCalculator"
```

---

### Task 8: SidebarView — thin rendering

Remove all async total management from SidebarView. The view just reads store properties.

**Files:**
- Modify: `Features/Navigation/SidebarView.swift`

- [ ] **Step 1: Remove `@State` total variables and async methods**

In `Features/Navigation/SidebarView.swift`:

Remove these `@State` properties (lines 21-23):
```swift
@State private var convertedCurrentTotal: InstrumentAmount?
@State private var convertedInvestmentTotal: InstrumentAmount?
@State private var convertedNetWorth: InstrumentAmount?
```

Remove `.task(id: [...])` modifier (lines 191-193).

Remove `loadConvertedTotals()` method (lines 237-251).

Remove `availableFunds` computed property (lines 229-235).

- [ ] **Step 2: Update total display to read from stores**

Replace total display rows:

```swift
// Current Total
totalRow(label: "Current Total", value: accountStore.convertedCurrentTotal)

// Earmarked Total  
totalRow(label: "Earmarked Total", value: earmarkStore.convertedTotalBalance)

// Investment Total
totalRow(label: "Investment Total", value: accountStore.convertedInvestmentTotal)

// Available Funds — simple subtraction, not business logic
if let currentTotal = accountStore.convertedCurrentTotal {
  let earmarked = earmarkStore.visibleEarmarks
    .filter { $0.balance.isPositive }
    .reduce(InstrumentAmount.zero(instrument: currentTotal.instrument)) { $0 + $1.balance }
  LabeledContent("Available Funds") {
    InstrumentAmountView(amount: currentTotal - earmarked)
  }
}

// Net Worth
if let netWorth = accountStore.convertedNetWorth {
  LabeledContent("Net Worth") {
    InstrumentAmountView(amount: netWorth)
  }
}
```

- [ ] **Step 3: Update `totalRow` helper to handle optional amounts**

```swift
private func totalRow(label: String, value: InstrumentAmount?) -> some View {
  LabeledContent(label) {
    if let value {
      InstrumentAmountView(amount: value, colorOverride: .secondary)
    } else {
      ProgressView()
        .controlSize(.small)
    }
  }
  .foregroundStyle(.secondary)
  .font(.callout)
}
```

- [ ] **Step 4: Update Available Funds for multi-instrument earmarks**

The available funds calculation needs to use converted earmark totals, not raw `earmark.balance`:

```swift
if let currentTotal = accountStore.convertedCurrentTotal,
   let earmarkedTotal = earmarkStore.convertedTotalBalance,
   earmarkedTotal.isPositive {
  LabeledContent("Available Funds") {
    InstrumentAmountView(amount: currentTotal - earmarkedTotal)
  }
  .font(.headline)
}
```

- [ ] **Step 5: Build and verify no warnings**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-sidebar.txt`
Expected: PASS with no warnings

Also use Xcode MCP: `mcp__xcode__XcodeListNavigatorIssues` with severity "warning" to check.

- [ ] **Step 6: Run full test suite**

Run: `just test 2>&1 | tee .agent-tmp/test-sidebar.txt`
Expected: ALL PASS

- [ ] **Step 7: Clean up temp files and commit**

```bash
rm .agent-tmp/build-sidebar.txt .agent-tmp/test-sidebar.txt
git add Features/Navigation/SidebarView.swift
git commit -m "refactor: thin SidebarView — remove async total management, read from stores"
```

---

### Task 9: Remove old `availableFunds` from AccountStore

The `availableFunds(earmarks:)` method on AccountStore (line 85-90) is no longer needed — the sidebar computes it from converted totals. Remove it and its tests.

**Files:**
- Modify: `Features/Accounts/AccountStore.swift` — remove method
- Modify: `MoolahTests/Features/AccountStoreTests.swift` — remove tests

- [ ] **Step 1: Search for callers of `availableFunds`**

```bash
grep -rn "availableFunds" --include="*.swift" .
```

If there are callers beyond SidebarView (which was already updated), update them. If none, remove the method.

- [ ] **Step 2: Remove method and tests**

Remove `func availableFunds(earmarks:)` from `AccountStore.swift`.
Remove corresponding tests from `AccountStoreTests.swift`.

- [ ] **Step 3: Run tests**

Run: `just test 2>&1 | tee .agent-tmp/test-cleanup.txt`
Expected: ALL PASS

- [ ] **Step 4: Clean up temp files and commit**

```bash
rm .agent-tmp/test-cleanup.txt
git add Features/Accounts/AccountStore.swift MoolahTests/Features/AccountStoreTests.swift
git commit -m "refactor: remove unused availableFunds from AccountStore"
```

---

### Task 10: Benchmarks

Add performance benchmarks for the new delta calculation and store application paths.

**Files:**
- Create: `MoolahBenchmarks/BalanceDeltaBenchmarks.swift`

Follow the existing benchmark pattern: XCTest, `nonisolated(unsafe)` statics, `BenchmarkFixtures.seed()`.

- [ ] **Step 1: Write benchmarks**

Create `MoolahBenchmarks/BalanceDeltaBenchmarks.swift`:

```swift
import XCTest

@testable import Moolah

final class BalanceDeltaBenchmarks: XCTestCase {
  nonisolated(unsafe) private static var _backend: CloudKitBackend!
  nonisolated(unsafe) private static var _container: ModelContainer!

  override class func setUp() {
    let result = try! TestBackend.create()
    _backend = result.backend
    _container = result.container
    try! awaitSync { @MainActor in
      BenchmarkFixtures.seed(scale: .x1, in: result.container)
    }
  }

  /// Measures BalanceDeltaCalculator.deltas() for a single-leg transaction.
  func testDeltaCalculatorSingleLeg() {
    let accountId = UUID()
    let tx = Transaction(
      date: Date(), payee: "Shop",
      legs: [TransactionLeg(accountId: accountId, instrument: .AUD, quantity: -50, type: .expense)]
    )
    measure {
      for _ in 0..<10_000 {
        _ = BalanceDeltaCalculator.deltas(old: nil, new: tx)
      }
    }
  }

  /// Measures BalanceDeltaCalculator.deltas() for a multi-leg transaction (transfer + earmark).
  func testDeltaCalculatorMultiLeg() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: -1000, type: .transfer, earmarkId: UUID()),
        TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: 1000, type: .transfer),
        TransactionLeg(accountId: UUID(), instrument: .USD, quantity: -500, type: .expense, earmarkId: UUID()),
      ]
    )
    let oldTx = Transaction(
      id: tx.id, date: Date(),
      legs: [
        TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: -800, type: .transfer, earmarkId: UUID()),
        TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: 800, type: .transfer),
      ]
    )
    measure {
      for _ in 0..<10_000 {
        _ = BalanceDeltaCalculator.deltas(old: oldTx, new: tx)
      }
    }
  }

  /// Measures AccountStore.applyDelta with realistic account count.
  func testAccountStoreApplyDelta() {
    awaitSync { @MainActor in
      let store = AccountStore(repository: Self._backend.accounts)
      await store.load()

      let accountId = store.currentAccounts.first!.id
      let deltas: PositionDeltas = [accountId: [.AUD: Decimal(-50)]]

      self.measure {
        for _ in 0..<1_000 {
          store.applyDelta(deltas)
        }
      }
    }
  }

  /// Measures full account reload (the expensive path used by sync).
  func testAccountReloadFromSync() {
    awaitSync { @MainActor in
      let store = AccountStore(repository: Self._backend.accounts)
      await store.load()

      self.measure {
        awaitSync {
          await store.reloadFromSync()
        }
      }
    }
  }
}
```

- [ ] **Step 2: Run benchmarks**

Run: `just benchmark 2>&1 | tee .agent-tmp/benchmark-delta.txt`
Expected: Benchmarks complete. Delta calculator should be sub-millisecond for 10k iterations. Reload should be in the hundreds of ms range.

- [ ] **Step 3: Clean up temp files and commit**

```bash
rm .agent-tmp/benchmark-delta.txt
git add MoolahBenchmarks/BalanceDeltaBenchmarks.swift
git commit -m "perf: add benchmarks for balance delta calculation and store application"
```

---

### Task 11: Final verification and bug removal

Verify both bugs are fixed and remove them from BUGS.md.

**Files:**
- Modify: `BUGS.md`

- [ ] **Step 1: Run the full test suite**

Run: `just test 2>&1 | tee .agent-tmp/test-final.txt`
Expected: ALL PASS

- [ ] **Step 2: Check for compiler warnings**

Use Xcode MCP: `mcp__xcode__XcodeListNavigatorIssues` with severity "warning"
Expected: No warnings in user code (preview warnings OK)

- [ ] **Step 3: Build and launch the app**

Run: `just run-mac`
Test manually:
1. Select an account, edit a transaction amount → verify sidebar Current Total updates and doesn't revert
2. Edit a transaction with an earmark → verify earmark balance updates in sidebar

- [ ] **Step 4: Remove fixed bugs from BUGS.md**

Remove the following entries from `BUGS.md`:
- "Current Total reverts after transaction amount change"
- "Earmark balance doesn't update when transaction amount changes"

- [ ] **Step 5: Clean up temp files and commit**

```bash
rm .agent-tmp/test-final.txt
git add BUGS.md
git commit -m "fix: resolve balance update bugs — centralised delta calculator, store-owned totals"
```
