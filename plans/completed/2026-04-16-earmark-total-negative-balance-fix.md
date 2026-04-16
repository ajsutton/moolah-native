# Fix Earmarked Total Negative Balance Bug

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent negative earmark balances from reducing the Earmarked Total and Available Funds — both in the sidebar (EarmarkStore) and in the DailyBalance/Net Worth graph (CloudKitAnalysisRepository).

**Architecture:** Two independent fixes:
1. **EarmarkStore** (sidebar): Clamp each earmark's contribution to `max(0)` when accumulating `convertedTotalBalance`. Simple — the per-earmark amounts are already computed.
2. **CloudKitAnalysisRepository** (DailyBalance): Change the running `earmarks: InstrumentAmount` accumulator to a per-earmark dictionary `[UUID: InstrumentAmount]`, then compute the clamped sum when building each `DailyBalance`. This touches `applyTransaction`, its callers, and `applyMultiInstrumentConversion`.

**Tech Stack:** Swift, SwiftUI, Swift Testing

---

## Part 1: EarmarkStore (Sidebar)

### Task 1: Add test for negative earmark balance exclusion from sidebar total

**Files:**
- Modify: `MoolahTests/Features/EarmarkStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Add this test in the `// MARK: - convertedTotalBalance` section, after `testConvertedTotalBalanceUpdatesAfterApplyDelta`:

```swift
@Test func testConvertedTotalBalanceExcludesNegativeEarmarks() async throws {
  let positiveId = UUID()
  let negativeId = UUID()
  let accountId = UUID()
  let instrument = Instrument.defaultTestInstrument
  let (backend, container) = try TestBackend.create()
  TestBackend.seed(
    accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container)
  TestBackend.seedWithTransactions(
    earmarks: [
      Earmark(id: positiveId, name: "Holiday Fund", instrument: instrument),
      Earmark(id: negativeId, name: "Investments", instrument: instrument),
    ],
    amounts: [
      positiveId: (saved: 500, spent: 0),
      negativeId: (saved: -18950, spent: 0),
    ],
    accountId: accountId, in: container)
  let store = EarmarkStore(repository: backend.earmarks)

  await store.load()
  try await Task.sleep(for: .milliseconds(50))

  // Individual balances should reflect true values
  #expect(store.convertedBalance(for: positiveId)?.quantity == 500)
  #expect(store.convertedBalance(for: negativeId)?.quantity == -18950)

  // Total should clamp negative earmarks to 0, so total = 500 (not 500 - 18950)
  #expect(store.convertedTotalBalance?.quantity == 500)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt`

Expected: FAIL — `convertedTotalBalance` will be `-18450` instead of `500`.

Verify with: `grep -A5 'testConvertedTotalBalanceExcludesNegativeEarmarks' .agent-tmp/test-output.txt`

- [ ] **Step 3: Commit the failing test**

```bash
git add MoolahTests/Features/EarmarkStoreTests.swift
git commit -m "test: add failing test for negative earmark balance in total"
```

---

### Task 2: Clamp negative earmark contributions in EarmarkStore

**Files:**
- Modify: `Features/Earmarks/EarmarkStore.swift:163-171`

- [ ] **Step 1: Clamp the grand total contribution**

In `recomputeConvertedTotals()`, replace the grand total accumulation block (lines 163-171):

```swift
          // Convert earmark balance to target instrument for grand total
          if let conversionService {
            let convertedToTarget = try await conversionService.convertAmount(
              earmarkBalance, to: targetInstrument, on: Date())
            guard !Task.isCancelled else { return }
            grandTotal += convertedToTarget
          } else {
            grandTotal += earmarkBalance
          }
```

with:

```swift
          // Convert earmark balance to target instrument for grand total.
          // Clamp negative balances to zero so they don't reduce the total.
          let zeroInTarget = InstrumentAmount.zero(instrument: targetInstrument)
          if let conversionService {
            let convertedToTarget = try await conversionService.convertAmount(
              earmarkBalance, to: targetInstrument, on: Date())
            guard !Task.isCancelled else { return }
            grandTotal += max(convertedToTarget, zeroInTarget)
          } else {
            grandTotal += max(earmarkBalance, zeroInTarget)
          }
```

Note: `InstrumentAmount` conforms to `Comparable` via `quantity`, and Swift's `max()` works on `Comparable` — no new helpers needed. The `else` branch works because when there is no `conversionService`, `earmarkBalance` already uses `targetInstrument`.

- [ ] **Step 2: Run tests to verify the fix**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt`

Expected: ALL PASS, including `testConvertedTotalBalanceExcludesNegativeEarmarks`.

Verify with: `grep -i 'failed\|error:' .agent-tmp/test-output.txt`

- [ ] **Step 3: Check for compiler warnings**

Use Xcode MCP: `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"`.

Fix any warnings in modified files before committing.

- [ ] **Step 4: Commit the fix**

```bash
git add Features/Earmarks/EarmarkStore.swift
git commit -m "fix: exclude negative earmark balances from sidebar earmarked total"
```

---

## Part 2: CloudKitAnalysisRepository (DailyBalance)

### Task 3: Add test for negative earmark exclusion in DailyBalance

**Files:**
- Modify: `MoolahTests/Domain/AnalysisRepositoryContractTests.swift`

- [ ] **Step 1: Write the failing test**

Add this test after `earmarkedBalanceFromTransactions` (line ~218):

```swift
@Test("earmarked total in dailyBalances clamps negative earmarks to zero")
func earmarkedTotalClampsNegativeEarmarks() async throws {
  let backend = CloudKitAnalysisTestBackend()
  let account = Account(
    id: UUID(),
    name: "Checking",
    type: .bank,
    balance: InstrumentAmount(quantity: 0, instrument: .defaultTestInstrument)
  )
  _ = try await backend.accounts.create(account)

  let positiveEarmark = Earmark(
    id: UUID(),
    name: "Holiday",
    instrument: .defaultTestInstrument
  )
  _ = try await backend.earmarks.create(positiveEarmark)

  let negativeEarmark = Earmark(
    id: UUID(),
    name: "Investments",
    instrument: .defaultTestInstrument
  )
  _ = try await backend.earmarks.create(negativeEarmark)

  let today = Calendar.current.startOfDay(for: Date())

  // Positive earmark: +500 (5.00)
  _ = try await backend.transactions.create(
    Transaction(
      date: today,
      payee: "Save for Holiday",
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: .defaultTestInstrument,
          quantity: 5, type: .income,
          earmarkId: positiveEarmark.id)
      ]))

  // Negative earmark: -18950 (-189.50)
  _ = try await backend.transactions.create(
    Transaction(
      date: today,
      payee: "Investment Loss",
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: .defaultTestInstrument,
          quantity: -189.50, type: .expense,
          earmarkId: negativeEarmark.id)
      ]))

  // Non-earmarked income: +1000 (10.00)
  _ = try await backend.transactions.create(
    Transaction(
      date: today,
      payee: "Regular Income",
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: .defaultTestInstrument,
          quantity: 10, type: .income)
      ]))

  let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

  let todayBalance = balances.first { Calendar.current.isDate($0.date, inSameDayAs: today) }
  #expect(todayBalance != nil)

  // Total balance = 5.00 - 189.50 + 10.00 = -174.50
  #expect(todayBalance?.balance.quantity == -174.50)
  // Earmarked should clamp negative earmark to 0: max(5, 0) + max(-189.50, 0) = 5.00
  #expect(todayBalance?.earmarked.quantity == 5)
  // Available = balance - earmarked = -174.50 - 5.00 = -179.50
  #expect(todayBalance?.availableFunds.quantity == -179.50)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt`

Expected: FAIL — `earmarked` will be `-184.50` (unclamped sum) instead of `5`.

Verify with: `grep -A5 'earmarkedTotalClampsNegativeEarmarks' .agent-tmp/test-output.txt`

- [ ] **Step 3: Commit the failing test**

```bash
git add MoolahTests/Domain/AnalysisRepositoryContractTests.swift
git commit -m "test: add failing test for negative earmark clamping in DailyBalance"
```

---

### Task 4: Refactor applyTransaction to track per-earmark amounts

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift`

The core change: `applyTransaction` currently accumulates a single `earmarks: inout InstrumentAmount`. We need per-earmark tracking so we can clamp each one independently.

- [ ] **Step 1: Add a helper to compute clamped earmark total**

Add this static method in the `// MARK: - Static Helper Methods` section (after `applyTransaction`, around line 884):

```swift
/// Computes the earmarked total by clamping each earmark's balance to max(0).
/// Negative earmarks (e.g., investments) should not reduce the total.
private static func clampedEarmarkTotal(
  _ perEarmark: [UUID: InstrumentAmount],
  instrument: Instrument
) -> InstrumentAmount {
  var total = InstrumentAmount.zero(instrument: instrument)
  let zero = InstrumentAmount.zero(instrument: instrument)
  for (_, amount) in perEarmark {
    total += max(amount, zero)
  }
  return total
}
```

- [ ] **Step 2: Change applyTransaction signature**

Replace the current `applyTransaction` method (lines 859-884):

```swift
private static func applyTransaction(
  _ txn: Transaction,
  to balance: inout InstrumentAmount,
  investments: inout InstrumentAmount,
  earmarks: inout InstrumentAmount,
  investmentAccountIds: Set<UUID>,
  investmentTransfersOnly: Bool = false
) {
  for leg in txn.legs {
    if let accountId = leg.accountId {
      if investmentAccountIds.contains(accountId) {
        if !investmentTransfersOnly || leg.type == .transfer {
          investments += leg.amount
        }
      } else {
        balance += leg.amount
      }
    }
    if leg.earmarkId != nil {
      earmarks += leg.amount
    }
  }
}
```

with:

```swift
private static func applyTransaction(
  _ txn: Transaction,
  to balance: inout InstrumentAmount,
  investments: inout InstrumentAmount,
  perEarmarkAmounts: inout [UUID: InstrumentAmount],
  instrument: Instrument,
  investmentAccountIds: Set<UUID>,
  investmentTransfersOnly: Bool = false
) {
  let zero = InstrumentAmount.zero(instrument: instrument)
  for leg in txn.legs {
    if let accountId = leg.accountId {
      if investmentAccountIds.contains(accountId) {
        if !investmentTransfersOnly || leg.type == .transfer {
          investments += leg.amount
        }
      } else {
        balance += leg.amount
      }
    }
    if let earmarkId = leg.earmarkId {
      perEarmarkAmounts[earmarkId, default: zero] += leg.amount
    }
  }
}
```

- [ ] **Step 3: Run build to check for compiler errors from callers**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-output.txt`

Expected: Compiler errors in `fetchDailyBalances`, `computeDailyBalances`, and `generateForecast` — the callers still pass the old signature. These are fixed in the next task.

- [ ] **Step 4: Commit the refactored method**

```bash
git add Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift
git commit -m "refactor: change applyTransaction to track per-earmark amounts"
```

---

### Task 5: Update callers of applyTransaction

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift`

Three methods call `applyTransaction`: `fetchDailyBalances` (line 129), `computeDailyBalances` (line 479), and `generateForecast` (line 985). All three follow the same pattern: replace `currentEarmarks: InstrumentAmount` with `perEarmarkAmounts: [UUID: InstrumentAmount]`, and compute clamped total when building `DailyBalance`.

- [ ] **Step 1: Update fetchDailyBalances (lines 129-242)**

Replace `var currentEarmarks: InstrumentAmount = .zero(instrument: instrument)` (line 150) with:

```swift
var perEarmarkAmounts: [UUID: InstrumentAmount] = [:]
```

In both `applyTransaction` call sites (lines 157 and 173), change:

```swift
earmarks: &currentEarmarks,
```

to:

```swift
perEarmarkAmounts: &perEarmarkAmounts,
instrument: instrument,
```

Where `DailyBalance` is constructed (line 190-200), replace `currentEarmarks` usage:

```swift
let currentEarmarks = clampedEarmarkTotal(perEarmarkAmounts, instrument: instrument)
dailyBalances[dayKey] = DailyBalance(
  date: dayKey,
  balance: currentBalance,
  earmarked: currentEarmarks,
  availableFunds: currentBalance - currentEarmarks,
  investments: currentInvestments,
  investmentValue: nil,
  netWorth: currentBalance + currentInvestments,
  bestFit: nil,
  isForecast: false
)
```

Where `startingEarmarks` is passed to `generateForecast` (line 234), change:

```swift
startingEarmarks: currentEarmarks,
```

to:

```swift
startingPerEarmarkAmounts: perEarmarkAmounts,
```

(The `generateForecast` signature is updated in Step 3.)

- [ ] **Step 2: Update computeDailyBalances (lines 479-595)**

Apply the same pattern as `fetchDailyBalances`:

Replace `var currentEarmarks: InstrumentAmount = .zero(instrument: instrument)` (line 503) with:

```swift
var perEarmarkAmounts: [UUID: InstrumentAmount] = [:]
```

In both `applyTransaction` call sites (lines 511 and 530), change:

```swift
earmarks: &currentEarmarks,
```

to:

```swift
perEarmarkAmounts: &perEarmarkAmounts,
instrument: instrument,
```

Where `DailyBalance` is constructed (line 547-557), compute clamped total:

```swift
let currentEarmarks = clampedEarmarkTotal(perEarmarkAmounts, instrument: instrument)
dailyBalances[dayKey] = DailyBalance(
  date: dayKey,
  balance: currentBalance,
  earmarked: currentEarmarks,
  availableFunds: currentBalance - currentEarmarks,
  investments: currentInvestments,
  investmentValue: nil,
  netWorth: currentBalance + currentInvestments,
  bestFit: nil,
  isForecast: false
)
```

Where `startingEarmarks` is passed to `generateForecast` (line 588), change:

```swift
startingEarmarks: currentEarmarks,
```

to:

```swift
startingPerEarmarkAmounts: perEarmarkAmounts,
```

- [ ] **Step 3: Update generateForecast (lines 985-1032)**

Change the method signature from:

```swift
private static func generateForecast(
  scheduled: [Transaction],
  startDate: Date,
  endDate: Date,
  startingBalance: InstrumentAmount,
  startingEarmarks: InstrumentAmount,
  startingInvestments: InstrumentAmount,
  investmentAccountIds: Set<UUID>
) -> [DailyBalance] {
```

to:

```swift
private static func generateForecast(
  scheduled: [Transaction],
  startDate: Date,
  endDate: Date,
  startingBalance: InstrumentAmount,
  startingPerEarmarkAmounts: [UUID: InstrumentAmount],
  startingInvestments: InstrumentAmount,
  investmentAccountIds: Set<UUID>
) -> [DailyBalance] {
```

Inside the method, replace `var earmarks = startingEarmarks` (line 1003) with:

```swift
var perEarmarkAmounts = startingPerEarmarkAmounts
```

Determine the instrument from `startingBalance` (it's always the profile instrument):

```swift
let instrument = startingBalance.instrument
```

In the `applyTransaction` call (lines 1008-1014), change:

```swift
earmarks: &earmarks,
```

to:

```swift
perEarmarkAmounts: &perEarmarkAmounts,
instrument: instrument,
```

Where `DailyBalance` is constructed (lines 1018-1028), compute clamped total:

```swift
let earmarks = clampedEarmarkTotal(perEarmarkAmounts, instrument: instrument)
forecastBalances[dayKey] = DailyBalance(
  date: dayKey,
  balance: balance,
  earmarked: earmarks,
  availableFunds: balance - earmarks,
  investments: investments,
  investmentValue: nil,
  netWorth: balance + investments,
  bestFit: nil,
  isForecast: true
)
```

- [ ] **Step 4: Run build to check compilation**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-output.txt`

Expected: Build succeeds (or fails only in `applyMultiInstrumentConversion` which is fixed in Task 6).

Verify with: `grep -i 'error:' .agent-tmp/build-output.txt`

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift
git commit -m "fix: update DailyBalance callers to use per-earmark clamped totals"
```

---

### Task 6: Update applyMultiInstrumentConversion for per-earmark tracking

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift:753-846`

The multi-instrument conversion path recomputes all balances from scratch using per-instrument position tracking. Currently `earmarkPositions` is `[String: (quantity, instrument)]` (keyed by instrument ID). We need to nest it by earmark ID: `[UUID: [String: (quantity, instrument)]]`.

- [ ] **Step 1: Change earmarkPositions type**

Replace line 775:

```swift
var earmarkPositions: [String: (quantity: Decimal, instrument: Instrument)] = [:]
```

with:

```swift
var earmarkPositions: [UUID: [String: (quantity: Decimal, instrument: Instrument)]] = [:]
```

- [ ] **Step 2: Update earmark position accumulation**

Replace lines 790-792:

```swift
if leg.earmarkId != nil {
  earmarkPositions[key, default: (0, leg.instrument)].quantity += leg.quantity
}
```

with:

```swift
if let earmarkId = leg.earmarkId {
  earmarkPositions[earmarkId, default: [:]][key, default: (0, leg.instrument)].quantity += leg.quantity
}
```

- [ ] **Step 3: Update earmark total conversion**

Replace lines 819-827:

```swift
var earmarkTotal: Decimal = 0
for (_, pos) in earmarkPositions where pos.quantity != 0 {
  if pos.instrument.id == instrument.id {
    earmarkTotal += pos.quantity
  } else {
    earmarkTotal += try await conversionService.convert(
      pos.quantity, from: pos.instrument, to: instrument, on: txn.date)
  }
}
```

with:

```swift
var earmarkTotal: Decimal = 0
for (_, positions) in earmarkPositions {
  var perEarmarkTotal: Decimal = 0
  for (_, pos) in positions where pos.quantity != 0 {
    if pos.instrument.id == instrument.id {
      perEarmarkTotal += pos.quantity
    } else {
      perEarmarkTotal += try await conversionService.convert(
        pos.quantity, from: pos.instrument, to: instrument, on: txn.date)
    }
  }
  earmarkTotal += max(perEarmarkTotal, 0)
}
```

- [ ] **Step 4: Run full test suite**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt`

Expected: ALL PASS, including `earmarkedTotalClampsNegativeEarmarks`.

Verify with: `grep -i 'failed\|error:' .agent-tmp/test-output.txt`

- [ ] **Step 5: Check for compiler warnings**

Use Xcode MCP: `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"`.

Fix any warnings before committing.

- [ ] **Step 6: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift
git commit -m "fix: clamp per-earmark amounts in multi-instrument DailyBalance conversion"
```

---

### Task 7: Update BUGS.md

**Files:**
- Modify: `BUGS.md`

- [ ] **Step 1: Remove the fixed bug entry**

Remove the entire "Earmarked Total includes negative earmark balances" section from BUGS.md. Do not replace it with a new entry — both the sidebar and DailyBalance bugs are now fixed.

- [ ] **Step 2: Commit**

```bash
git add BUGS.md
git commit -m "docs: remove fixed earmark negative balance bug from BUGS.md"
```

- [ ] **Step 3: Clean up temp files**

```bash
rm -f .agent-tmp/test-output.txt .agent-tmp/build-output.txt
```
