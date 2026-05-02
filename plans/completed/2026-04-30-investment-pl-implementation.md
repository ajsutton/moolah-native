# Investment Account Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface lifetime profit/loss, annualised return, and per-position cost-basis numbers for investment accounts, in line with `plans/2026-04-29-investment-pl-design.md`.

**Architecture:** Three pure-math pieces (`CashFlow`, `IRRSolver`, `AccountPerformanceCalculator`) feed an `AccountPerformance` value type that `InvestmentStore` publishes. A new `AccountPerformanceTiles` view replaces both `PositionsHeader` (when a performance is supplied) and the legacy `InvestmentSummaryView`. The Gain column on the positions table additionally renders a `+x.x%` cost-basis percentage. No schema, repository, or CKSyncEngine changes — every figure derives from data already on disk via `TransactionRepository.fetchAll(filter:)`, `InvestmentRepository`, and `InstrumentConversionService`.

**Tech Stack:** Swift 6, SwiftUI, GRDB (existing repository surface — no new SQL), Swift Testing (`import Testing`, `@Test`, `@Suite`, `#expect`), `xcodegen` (auto-picks up new files under `Domain/`, `Shared/`, `Features/`).

**Reference design:** `plans/2026-04-29-investment-pl-design.md` (single source of truth — §1 architecture, §2 cash-flow extraction rule, §3 calculation engines, §4 UI, §5 wiring, §6 testing strategy, §"Known limitations").

---

## Setup — worktree and branch

`main` is protected. Per `CLAUDE.md` § Git Workflow, all work happens in a git worktree on a feature branch.

- [ ] **Step 1: Create the worktree off `main`**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add \
    --no-track \
    .worktrees/investment-pl \
    -b feat/investment-pl \
    origin/main
```

`--no-track` is required (CLAUDE.md § "Stacked-PR worktrees"): without it, the new local branch silently tracks `origin/main`, and a later `git push -u origin feat/investment-pl` would resolve to whichever branch happens to be upstream-tracked.

- [ ] **Step 2: Verify the worktree was created and the branch is detached from any upstream**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-pl status
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-pl rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>&1 || true
```

Expected:
- `status` reports clean tree on `feat/investment-pl`.
- The upstream-rev-parse line either errors (`fatal: no upstream configured for branch 'feat/investment-pl'`) or prints nothing — anything resembling `origin/main` means `--no-track` was missed; redo Step 1.

All subsequent commands assume the working directory is the worktree:
`/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-pl`.

---

# Slice 1 — IRR primitives

Lands two pure-math files with their tests. No callers; nothing user-visible. Compiles and ships independently.

## Task 1: `CashFlow` value type

**Files:**
- Create: `Domain/Models/CashFlow.swift`
- Test: covered by `IRRSolverTests` (Task 2) and `AccountPerformanceCalculatorTests` (Task 5) — `CashFlow` itself has no behaviour to unit-test in isolation beyond `Hashable` synthesis.

- [ ] **Step 1: Create the model**

```swift
// Domain/Models/CashFlow.swift
import Foundation

/// One date-stamped, signed contribution into (or withdrawal out of) an
/// investment account, expressed in the profile's reporting currency.
///
/// **Sign convention:** positive = capital flowing *into* the account from
/// outside (deposits, opening balance), negative = capital flowing *out* to
/// outside (withdrawals). Per CLAUDE.md the sign is semantically meaningful;
/// callers must never `abs()` the amount.
///
/// Inclusion rules for which transaction legs become `CashFlow`s live with
/// the calculator (see §2 of `plans/2026-04-29-investment-pl-design.md`).
struct CashFlow: Sendable, Hashable {
  let date: Date
  let amount: Decimal
}
```

- [ ] **Step 2: Verify it compiles**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -E 'error:|warning:' .agent-tmp/build.txt | grep -v '#Preview' || echo "clean"
```

Expected: `clean`.

- [ ] **Step 3: Format and commit**

```bash
just format
git -C . add Domain/Models/CashFlow.swift
git -C . commit -m "$(cat <<'EOF'
feat(investments): add CashFlow value type

Foundation for AccountPerformanceCalculator. One date-stamped signed
amount in profile currency; inclusion rules live with the calculator.
See plans/2026-04-29-investment-pl-design.md §2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `IRRSolver` skeleton + canonical convergence test

**Files:**
- Create: `Shared/IRRSolver.swift`
- Test: `MoolahTests/Shared/IRRSolverTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Shared/IRRSolverTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("IRRSolver")
struct IRRSolverTests {
  /// Single $1,000 deposit one year ago, terminal value $1,100 →
  /// effective annual return ≈ 10%.
  @Test("single deposit grown 10 percent over a year converges on 10 percent")
  func singleDepositTenPercent() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let end = start.addingTimeInterval(365 * 86_400)
    let result = IRRSolver.annualisedReturn(
      flows: [CashFlow(date: start, amount: 1_000)],
      terminalValue: 1_100,
      terminalDate: end
    )
    let value = try! #require(result)
    let asDouble = (value as NSDecimalNumber).doubleValue
    #expect(abs(asDouble - 0.10) < 0.001, "expected ~0.10 (10% p.a.), got \(asDouble)")
  }
}
```

- [ ] **Step 2: Run the test and verify it fails for the right reason**

```bash
mkdir -p .agent-tmp
just test-mac IRRSolverTests 2>&1 | tee .agent-tmp/test-output.txt
grep -B2 -A4 'error:\|FAIL' .agent-tmp/test-output.txt
```

Expected: compile error — `cannot find 'IRRSolver' in scope`.

- [ ] **Step 3: Add the minimal `IRRSolver` enum that makes it pass**

```swift
// Shared/IRRSolver.swift
import Foundation

/// Computes the effective annual rate for a stream of contributions and a
/// terminal value, using Newton–Raphson seeded by Modified Dietz with a
/// bisection fallback for pathological multi-root cases.
///
/// Day-precise: contribution exponents are `−tᵢ / 365` where `tᵢ` is days
/// from the first flow. Replaces the legacy 30-day-month / monthly-rate-as-
/// percent approximations in `InvestmentStore.annualizedReturnRate`.
///
/// **Returns `nil` when:**
/// - `flows` is empty,
/// - the span between the first flow and `terminalDate` is < 1 day
///   (cannot annualise meaningfully),
/// - Newton–Raphson fails to converge in 50 iterations *and* bisection
///   fallback over `[−0.99, 10.0]` also fails.
///
/// Internally evaluates `(1 + r)^(−t/365)` in `Double` (Decimal has no
/// fractional `pow`) and returns the converged rate as `Decimal` at the
/// boundary so callers can mix it with money-typed math without lossy
/// further conversions.
enum IRRSolver {
  static func annualisedReturn(
    flows: [CashFlow],
    terminalValue: Decimal,
    terminalDate: Date
  ) -> Decimal? {
    guard let first = flows.first else { return nil }
    let totalDays = terminalDate.timeIntervalSince(first.date) / 86_400
    guard totalDays >= 1 else { return nil }

    let v = (terminalValue as NSDecimalNumber).doubleValue
    let cashflows: [(t: Double, c: Double)] = flows.map { flow in
      let days = flow.date.timeIntervalSince(first.date) / 86_400
      return (t: days, c: (flow.amount as NSDecimalNumber).doubleValue)
    }

    let seed = modifiedDietzAnnualised(cashflows: cashflows, v: v, totalDays: totalDays)
    if let r = newtonRaphson(seed: seed, cashflows: cashflows, v: v, totalDays: totalDays) {
      return Decimal(r)
    }
    if let r = bisection(cashflows: cashflows, v: v, totalDays: totalDays) {
      return Decimal(r)
    }
    return nil
  }

  /// `(V − ΣCᵢ) / Σ(wᵢ · Cᵢ)` annualised to `(1 + MD)^(365/T) − 1`.
  /// Returns 0 if the weighted-capital denominator is zero (degenerate input).
  private static func modifiedDietzAnnualised(
    cashflows: [(t: Double, c: Double)],
    v: Double,
    totalDays: Double
  ) -> Double {
    var sumC = 0.0
    var sumWeightedC = 0.0
    for f in cashflows {
      sumC += f.c
      let weight = (totalDays - f.t) / totalDays
      sumWeightedC += weight * f.c
    }
    guard sumWeightedC != 0 else { return 0 }
    let md = (v - sumC) / sumWeightedC
    return pow(1 + md, 365 / totalDays) - 1
  }

  /// `f(r) = Σ Cᵢ · (1+r)^(−tᵢ/365) − V · (1+r)^(−T/365)`. Stops when
  /// `|f| < 1e-9` or 50 iterations elapsed. Returns `nil` on divergence.
  private static func newtonRaphson(
    seed: Double,
    cashflows: [(t: Double, c: Double)],
    v: Double,
    totalDays: Double
  ) -> Double? {
    var r = seed
    for _ in 0..<50 {
      let one_r = 1 + r
      guard one_r > 0 else { return nil }
      var f = 0.0
      var fPrime = 0.0
      for cf in cashflows {
        let exp = -cf.t / 365
        let p = pow(one_r, exp)
        f += cf.c * p
        fPrime += cf.c * exp * p / one_r
      }
      let expV = -totalDays / 365
      let pV = pow(one_r, expV)
      f -= v * pV
      fPrime -= v * expV * pV / one_r

      if abs(f) < 1e-9 { return r }
      guard fPrime != 0 else { return nil }
      r -= f / fPrime
    }
    return nil
  }

  /// Sign-change search over `[−0.99, 10.0]`, ~30 iterations. Last-resort
  /// fallback for multi-root patterns that throw NR off.
  private static func bisection(
    cashflows: [(t: Double, c: Double)],
    v: Double,
    totalDays: Double
  ) -> Double? {
    func f(_ r: Double) -> Double {
      let one_r = 1 + r
      guard one_r > 0 else { return .nan }
      var sum = 0.0
      for cf in cashflows {
        sum += cf.c * pow(one_r, -cf.t / 365)
      }
      return sum - v * pow(one_r, -totalDays / 365)
    }
    var lo = -0.99
    var hi = 10.0
    var fLo = f(lo)
    var fHi = f(hi)
    if fLo.isNaN || fHi.isNaN { return nil }
    if fLo * fHi > 0 { return nil }
    for _ in 0..<60 {
      let mid = (lo + hi) / 2
      let fMid = f(mid)
      if fMid.isNaN { return nil }
      if abs(fMid) < 1e-9 { return mid }
      if fLo * fMid < 0 {
        hi = mid
        fHi = fMid
      } else {
        lo = mid
        fLo = fMid
      }
    }
    return (lo + hi) / 2
  }
}
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
just test-mac IRRSolverTests 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'Test Suite|passed|failed' .agent-tmp/test-output.txt | tail -5
```

Expected: `IRRSolverTests` passes (1 test).

- [ ] **Step 5: Format and commit**

```bash
just format
git -C . add Shared/IRRSolver.swift MoolahTests/Shared/IRRSolverTests.swift
git -C . commit -m "$(cat <<'EOF'
feat(investments): add IRRSolver with Modified Dietz + Newton-Raphson

Day-precise effective annual rate solver. Replaces the legacy
30-day-month / monthly-rate-as-percent approximations.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `IRRSolver` edge-case tests

Locks in the §3 behaviour table for the solver: zero return, negative return, < 1 day span, empty flows, multi-flow seed/converge cross-check.

**Files:**
- Modify: `MoolahTests/Shared/IRRSolverTests.swift`

- [ ] **Step 1: Add the failing tests**

Append to the existing `IRRSolverTests` suite (place inside the `struct IRRSolverTests { ... }` block after `singleDepositTenPercent`):

```swift
  /// Deposit $1,000, value unchanged a year later → 0% p.a.
  @Test("zero growth returns approximately zero")
  func zeroGrowth() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let end = start.addingTimeInterval(365 * 86_400)
    let result = IRRSolver.annualisedReturn(
      flows: [CashFlow(date: start, amount: 1_000)],
      terminalValue: 1_000,
      terminalDate: end
    )
    let value = try! #require(result)
    let asDouble = (value as NSDecimalNumber).doubleValue
    #expect(abs(asDouble) < 0.001, "expected ~0, got \(asDouble)")
  }

  /// $100 deposit, $90 a year later → ≈ −10% p.a.
  @Test("negative return converges below zero")
  func negativeReturn() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let end = start.addingTimeInterval(365 * 86_400)
    let result = IRRSolver.annualisedReturn(
      flows: [CashFlow(date: start, amount: 100)],
      terminalValue: 90,
      terminalDate: end
    )
    let value = try! #require(result)
    let asDouble = (value as NSDecimalNumber).doubleValue
    #expect(asDouble < 0, "expected negative rate, got \(asDouble)")
    #expect(abs(asDouble - (-0.10)) < 0.001, "expected ~-0.10, got \(asDouble)")
  }

  /// Two equal deposits 6 months apart, terminal value 10% above contributions
  /// → IRR > 10% (deposits weren't all in for the full year).
  @Test("multiple deposits converges higher than naive ROI")
  func multiDeposit() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let mid = start.addingTimeInterval(182 * 86_400)
    let end = start.addingTimeInterval(365 * 86_400)
    let result = IRRSolver.annualisedReturn(
      flows: [
        CashFlow(date: start, amount: 500),
        CashFlow(date: mid, amount: 500),
      ],
      terminalValue: 1_100,
      terminalDate: end
    )
    let value = try! #require(result)
    let asDouble = (value as NSDecimalNumber).doubleValue
    #expect(asDouble > 0.10, "expected IRR > 10% for half-year-old half of capital, got \(asDouble)")
    #expect(asDouble < 0.20, "expected IRR < 20%, got \(asDouble)")
  }

  @Test("empty flows returns nil")
  func emptyFlows() {
    #expect(IRRSolver.annualisedReturn(flows: [], terminalValue: 100, terminalDate: Date()) == nil)
  }

  @Test("span under one day returns nil")
  func subDaySpan() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let end = start.addingTimeInterval(60 * 60)  // one hour
    let result = IRRSolver.annualisedReturn(
      flows: [CashFlow(date: start, amount: 1_000)],
      terminalValue: 1_010,
      terminalDate: end
    )
    #expect(result == nil)
  }
```

- [ ] **Step 2: Run them**

```bash
just test-mac IRRSolverTests 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'Test Suite|passed|failed' .agent-tmp/test-output.txt | tail -10
```

Expected: 6 tests pass (the original plus 5 new). If `subDaySpan` fails because the < 1 day guard is missing, fix `IRRSolver.annualisedReturn` (Task 2 already includes the guard — the test should pass first try).

- [ ] **Step 3: Format and commit**

```bash
just format
git -C . add MoolahTests/Shared/IRRSolverTests.swift
git -C . commit -m "$(cat <<'EOF'
test(investments): add IRRSolver edge-case coverage

Zero / negative / multi-deposit / empty / sub-day span. Locks in the
§3 behaviour table from plans/2026-04-29-investment-pl-design.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

# Slice 2 — `AccountPerformance` model + calculator

Adds the value type and the two calculator entry points (`compute` for position-tracked accounts, `computeLegacy` for manual-valuation accounts). Pure functions; still no caller, still nothing user-visible.

## Task 4: `AccountPerformance` value type

**Files:**
- Create: `Domain/Models/AccountPerformance.swift`

- [ ] **Step 1: Create the model**

```swift
// Domain/Models/AccountPerformance.swift
import Foundation

/// Account-level performance numbers in the profile currency.
///
/// All monetary fields are independently optional: per Rule 11 in
/// `guides/INSTRUMENT_CONVERSION_GUIDE.md` a single conversion failure
/// marks the affected aggregate unavailable rather than showing a partial
/// sum. Per CLAUDE.md the sign of `profitLoss` is preserved — callers
/// must never `abs()` it.
///
/// `firstFlowDate` powers the "since Mar 2023" subtitle on the annualised-
/// return tile.
struct AccountPerformance: Sendable, Hashable {
  let instrument: Instrument
  let currentValue: InstrumentAmount?
  let totalContributions: InstrumentAmount?
  let profitLoss: InstrumentAmount?
  /// Modified Dietz period return (not annualised). `nil` when the
  /// weighted-capital denominator is zero or any input is unavailable.
  let profitLossPercent: Decimal?
  /// Effective annual rate from `IRRSolver`. `nil` for spans < 1 day,
  /// pathological multi-root cases, or when inputs are unavailable.
  let annualisedReturn: Decimal?
  let firstFlowDate: Date?
}

extension AccountPerformance {
  /// All-`nil` performance for the given instrument. Used when conversion
  /// fails or no data is available — keeps the row count stable while
  /// reporting unavailability per Rule 11.
  static func unavailable(in instrument: Instrument) -> AccountPerformance {
    AccountPerformance(
      instrument: instrument,
      currentValue: nil,
      totalContributions: nil,
      profitLoss: nil,
      profitLossPercent: nil,
      annualisedReturn: nil,
      firstFlowDate: nil
    )
  }
}
```

- [ ] **Step 2: Verify it builds**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -E 'error:|warning:' .agent-tmp/build.txt | grep -v '#Preview' || echo "clean"
```

Expected: `clean`.

- [ ] **Step 3: Format and commit**

```bash
just format
git -C . add Domain/Models/AccountPerformance.swift
git -C . commit -m "$(cat <<'EOF'
feat(investments): add AccountPerformance value type

Account-level lifetime numbers: currentValue, totalContributions,
profitLoss / %, annualisedReturn, firstFlowDate. Each field independently
optional per Rule 11.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `AccountPerformanceCalculator.compute` — opening-balance smoke

Lands the calculator type with the simplest §2-rule case: opening balance only, no other transactions. Subsequent tasks add §2-rule edge cases and the legacy path.

**Files:**
- Create: `Shared/AccountPerformanceCalculator.swift`
- Test: `MoolahTests/Shared/AccountPerformanceCalculatorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Shared/AccountPerformanceCalculatorTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("AccountPerformanceCalculator.compute")
struct AccountPerformanceCalculatorTests {
  let aud = Instrument.AUD

  /// Account opened with $10,000 a year ago, current value $11,000 →
  /// contributions $10,000, P/L $1,000, p.a. ≈ 10%.
  @Test("opening balance only with growth surfaces P/L and annualised return")
  func openingBalanceOnly() async throws {
    let accountId = UUID()
    let aYearAgo = Date().addingTimeInterval(-365 * 86_400)
    let openingTxn = Transaction(
      date: aYearAgo,
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 10_000, type: .openingBalance)
      ]
    )
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 11_000,
        unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 11_000, instrument: aud))
    ]

    let perf = try await AccountPerformanceCalculator.compute(
      accountId: accountId,
      transactions: [openingTxn],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FixedConversionService()
    )

    #expect(perf.currentValue == InstrumentAmount(quantity: 11_000, instrument: aud))
    #expect(perf.totalContributions == InstrumentAmount(quantity: 10_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 1_000, instrument: aud))
    let pl = try #require(perf.profitLossPercent)
    #expect(abs((pl as NSDecimalNumber).doubleValue - 0.10) < 0.001)
    let pa = try #require(perf.annualisedReturn)
    #expect(abs((pa as NSDecimalNumber).doubleValue - 0.10) < 0.005)
    #expect(perf.firstFlowDate == aYearAgo)
  }
}
```

- [ ] **Step 2: Run it and verify it fails for the right reason**

```bash
just test-mac AccountPerformanceCalculatorTests 2>&1 | tee .agent-tmp/test-output.txt
grep -B2 -A4 'error:\|FAIL' .agent-tmp/test-output.txt
```

Expected: compile error — `cannot find 'AccountPerformanceCalculator' in scope`.

- [ ] **Step 3: Create the calculator**

```swift
// Shared/AccountPerformanceCalculator.swift
import Foundation
import OSLog

/// Pure orchestrator that turns transactions + valued positions into an
/// `AccountPerformance`. See §2-§3 of
/// `plans/2026-04-29-investment-pl-design.md`.
///
/// Two entry points:
/// - `compute(...)` for position-tracked accounts (uses the §2 boundary-
///   crossing rule to extract `CashFlow`s; throws on conversion failure).
/// - `computeLegacy(...)` for manual-valuation accounts (cash flows =
///   consecutive `dailyBalance` deltas; synchronous, no conversion).
///
/// Both share `IRRSolver` and the same Modified Dietz formula for
/// `profitLossPercent`.
enum AccountPerformanceCalculator {
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "AccountPerformanceCalculator")

  // MARK: - Position-tracked

  static func compute(
    accountId: UUID,
    transactions: [Transaction],
    valuedPositions: [ValuedPosition],
    profileCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> AccountPerformance {
    let flows = try await extractFlows(
      from: transactions,
      accountId: accountId,
      profileCurrency: profileCurrency,
      conversionService: conversionService)

    let currentValue = aggregatedValue(of: valuedPositions, in: profileCurrency)

    return assemble(
      flows: flows,
      currentValue: currentValue,
      profileCurrency: profileCurrency,
      now: Date())
  }

  /// §2 cash-flow extraction. A leg L in `accountId` produces one `CashFlow`
  /// iff (a) `L.type == .openingBalance`, OR (b) the transaction crosses an
  /// account boundary (some other leg references an account that is not
  /// `accountId` and not nil).
  private static func extractFlows(
    from transactions: [Transaction],
    accountId: UUID,
    profileCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> [CashFlow] {
    var flows: [CashFlow] = []
    let sorted = transactions.sorted { $0.date < $1.date }
    for txn in sorted {
      let otherAccountIds = Set(txn.legs.compactMap(\.accountId)).subtracting([accountId])
      let crossesBoundary = !otherAccountIds.isEmpty
      for leg in txn.legs where leg.accountId == accountId {
        guard leg.type == .openingBalance || crossesBoundary else { continue }
        let amountInProfileCurrency: Decimal
        if leg.instrument == profileCurrency {
          amountInProfileCurrency = leg.quantity
        } else {
          amountInProfileCurrency = try await conversionService.convert(
            leg.quantity, from: leg.instrument, to: profileCurrency, on: txn.date)
        }
        flows.append(CashFlow(date: txn.date, amount: amountInProfileCurrency))
      }
    }
    return flows
  }

  /// Sum of valued positions in `profileCurrency`, or `nil` if any row's
  /// `value` is missing — Rule 11 forbids partial sums.
  private static func aggregatedValue(
    of valued: [ValuedPosition], in profileCurrency: Instrument
  ) -> InstrumentAmount? {
    var total = InstrumentAmount.zero(instrument: profileCurrency)
    for row in valued {
      guard let value = row.value else { return nil }
      total += value
    }
    return total
  }

  /// Builds the `AccountPerformance`. Centralised so the legacy path
  /// reuses the same formulae.
  private static func assemble(
    flows: [CashFlow],
    currentValue: InstrumentAmount?,
    profileCurrency: Instrument,
    now: Date
  ) -> AccountPerformance {
    guard let currentValue else {
      return .unavailable(in: profileCurrency)
    }
    guard let firstFlow = flows.first else {
      return AccountPerformance(
        instrument: profileCurrency,
        currentValue: currentValue,
        totalContributions: .zero(instrument: profileCurrency),
        profitLoss: .zero(instrument: profileCurrency),
        profitLossPercent: nil,
        annualisedReturn: nil,
        firstFlowDate: nil)
    }

    let totalContrib = flows.reduce(Decimal(0)) { $0 + $1.amount }
    let v = (currentValue.quantity as NSDecimalNumber).doubleValue
    let totalDays = max(now.timeIntervalSince(firstFlow.date) / 86_400, 0)

    let pl = currentValue.quantity - totalContrib
    let plPercent = modifiedDietzPercent(flows: flows, v: v, totalDays: totalDays)
    let pa = IRRSolver.annualisedReturn(
      flows: flows, terminalValue: currentValue.quantity, terminalDate: now)

    return AccountPerformance(
      instrument: profileCurrency,
      currentValue: currentValue,
      totalContributions: InstrumentAmount(quantity: totalContrib, instrument: profileCurrency),
      profitLoss: InstrumentAmount(quantity: pl, instrument: profileCurrency),
      profitLossPercent: plPercent,
      annualisedReturn: pa,
      firstFlowDate: firstFlow.date)
  }

  /// `(V − ΣCᵢ) / Σ(wᵢ · Cᵢ)`. Same formula `IRRSolver` uses internally as
  /// its Newton–Raphson seed; we expose it directly here.
  /// Returns `nil` for spans < 1 day or zero weighted-capital.
  private static func modifiedDietzPercent(
    flows: [CashFlow], v: Double, totalDays: Double
  ) -> Decimal? {
    guard totalDays >= 1 else { return nil }
    let first = flows[0].date
    var sumC = 0.0
    var sumWeightedC = 0.0
    for f in flows {
      let t = f.date.timeIntervalSince(first) / 86_400
      let weight = (totalDays - t) / totalDays
      let c = (f.amount as NSDecimalNumber).doubleValue
      sumC += c
      sumWeightedC += weight * c
    }
    guard sumWeightedC != 0 else { return nil }
    return Decimal((v - sumC) / sumWeightedC)
  }
}
```

- [ ] **Step 4: Run the test**

```bash
just test-mac AccountPerformanceCalculatorTests 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'Test Suite|passed|failed' .agent-tmp/test-output.txt | tail -5
```

Expected: 1 test passes.

- [ ] **Step 5: Format and commit**

```bash
just format
git -C . add Shared/AccountPerformanceCalculator.swift \
    MoolahTests/Shared/AccountPerformanceCalculatorTests.swift
git -C . commit -m "$(cat <<'EOF'
feat(investments): add AccountPerformanceCalculator.compute

Position-tracked entry point. Implements §2 boundary-crossing cash-flow
extraction and §3 assembly. Opening-balance-only smoke test.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `compute` — §2 rule edge cases + conversion failure

Locks in the §2 inclusion rule's full coverage matrix from §6 of the design.

**Files:**
- Modify: `MoolahTests/Shared/AccountPerformanceCalculatorTests.swift`

- [ ] **Step 1: Add the failing tests**

Append to the existing suite (inside `struct AccountPerformanceCalculatorTests { ... }`):

```swift
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  /// A two-leg trade in the same account → no boundary crossed → no flow,
  /// even though the legs change quantity. P/L still falls out of V_now vs
  /// total contributions (which here is zero — there are no flows).
  @Test("intra-account trade does not produce a cash flow")
  func intraAccountTradeNoFlow() async throws {
    let accountId = UUID()
    let aYearAgo = Date().addingTimeInterval(-365 * 86_400)
    let trade = Transaction(
      date: aYearAgo,
      legs: [
        TransactionLeg(accountId: accountId, instrument: bhp, quantity: 100, type: .trade),
        TransactionLeg(accountId: accountId, instrument: aud, quantity: -4_000, type: .trade),
      ]
    )
    let valued = [
      ValuedPosition(
        instrument: bhp, quantity: 100, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 5_000, instrument: aud))
    ]
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: accountId,
      transactions: [trade],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FixedConversionService()
    )
    #expect(perf.totalContributions == InstrumentAmount(quantity: 0, instrument: aud))
    #expect(perf.firstFlowDate == nil)
    // V_now = 5000, contributions = 0 → P/L = 5000 (the "free value" case).
    #expect(perf.profitLoss == InstrumentAmount(quantity: 5_000, instrument: aud))
  }

  /// A `.transfer` leg pair across two accounts → boundary crossed → flow
  /// emitted on each side.
  @Test("cross-account transfer produces a cash flow")
  func crossAccountTransferFlow() async throws {
    let investmentAccount = UUID()
    let cashAccount = UUID()
    let aYearAgo = Date().addingTimeInterval(-365 * 86_400)
    let transfer = Transaction(
      date: aYearAgo,
      legs: [
        TransactionLeg(
          accountId: cashAccount, instrument: aud, quantity: -1_000, type: .transfer),
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: 1_000, type: .transfer),
      ]
    )
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 1_100, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 1_100, instrument: aud))
    ]
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: investmentAccount,
      transactions: [transfer],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FixedConversionService()
    )
    #expect(perf.totalContributions == InstrumentAmount(quantity: 1_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 100, instrument: aud))
    #expect(perf.firstFlowDate == aYearAgo)
  }

  /// A standalone `.income` leg (e.g. dividend paid in cash) is single-
  /// account, no boundary → no flow. The cash sits in the account, lifting
  /// V_now and so showing up in P/L as a gain.
  @Test("standalone income leg does not produce a cash flow")
  func dividendNoFlow() async throws {
    let accountId = UUID()
    let aYearAgo = Date().addingTimeInterval(-365 * 86_400)
    let dividend = Transaction(
      date: aYearAgo,
      legs: [
        TransactionLeg(accountId: accountId, instrument: aud, quantity: 50, type: .income)
      ]
    )
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 50, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 50, instrument: aud))
    ]
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: accountId,
      transactions: [dividend],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FixedConversionService()
    )
    #expect(perf.totalContributions == InstrumentAmount(quantity: 0, instrument: aud))
    #expect(perf.firstFlowDate == nil)
  }

  /// Conversion-failure path: the calculator throws so the caller can mark
  /// the whole performance unavailable. Per Rule 11, no partial sums.
  @Test("conversion failure on a flow propagates as a throw")
  func conversionFailureOnFlowThrows() async throws {
    let accountId = UUID()
    let cashAccount = UUID()
    let usd = Instrument.USD
    let txn = Transaction(
      date: Date().addingTimeInterval(-365 * 86_400),
      legs: [
        TransactionLeg(accountId: cashAccount, instrument: usd, quantity: -100, type: .transfer),
        TransactionLeg(accountId: accountId, instrument: usd, quantity: 100, type: .transfer),
      ]
    )
    let conversion = FailingConversionService(failingInstrumentIds: [usd.id])
    let valued = [
      ValuedPosition(
        instrument: usd, quantity: 100, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 150, instrument: aud))
    ]
    await #expect(throws: FailingConversionError.self) {
      _ = try await AccountPerformanceCalculator.compute(
        accountId: accountId,
        transactions: [txn],
        valuedPositions: valued,
        profileCurrency: aud,
        conversionService: conversion)
    }
  }

  /// V_now unavailable (any position's `value` is `nil`) → calculator
  /// returns `.unavailable`. No throw — partial currentValue is just nil.
  @Test("missing position value yields unavailable performance")
  func unavailableValueYieldsUnavailablePerformance() async throws {
    let accountId = UUID()
    let opening = Transaction(
      date: Date().addingTimeInterval(-365 * 86_400),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 1_000, type: .openingBalance)
      ]
    )
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 1_000, unitPrice: nil, costBasis: nil, value: nil)
    ]
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: accountId,
      transactions: [opening],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FixedConversionService()
    )
    #expect(perf.currentValue == nil)
    #expect(perf.profitLoss == nil)
    #expect(perf.annualisedReturn == nil)
  }
```

- [ ] **Step 2: Run the new tests**

```bash
just test-mac AccountPerformanceCalculatorTests 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'Test Suite|passed|failed' .agent-tmp/test-output.txt | tail -10
```

Expected: 6 tests pass total in this suite. If any §2-rule test fails, fix `extractFlows` in `Shared/AccountPerformanceCalculator.swift` — the inclusion rule logic from Task 5 should already be complete; failures here usually indicate a typo in the boundary-crossing predicate.

- [ ] **Step 3: Format and commit**

```bash
just format
git -C . add MoolahTests/Shared/AccountPerformanceCalculatorTests.swift
git -C . commit -m "$(cat <<'EOF'
test(investments): cover §2 rule edge cases for AccountPerformance.compute

Intra-account trade, cross-account transfer, standalone dividend,
conversion-failure throw, missing-position-value unavailable path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `AccountPerformanceCalculator.computeLegacy`

Manual-valuation accounts (no positions, only `InvestmentValue` snapshots and
account-daily-balance series). Cash flows = consecutive `dailyBalance` deltas.

**Files:**
- Modify: `Shared/AccountPerformanceCalculator.swift`
- Test: `MoolahTests/Shared/AccountPerformanceCalculatorLegacyTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Shared/AccountPerformanceCalculatorLegacyTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("AccountPerformanceCalculator.computeLegacy")
struct AccountPerformanceCalculatorLegacyTests {
  let aud = Instrument.AUD

  /// $10,000 invested a year ago, latest valuation $11,000 → contributions
  /// $10,000, P/L $1,000, p.a. ≈ 10%.
  @Test("single contribution legacy account converges on 10 percent")
  func singleContribution() {
    let aYearAgo = Date().addingTimeInterval(-365 * 86_400)
    let now = Date()
    let dailyBalances = [
      AccountDailyBalance(
        date: aYearAgo,
        balance: InstrumentAmount(quantity: 10_000, instrument: aud))
    ]
    let values = [
      InvestmentValue(
        date: now,
        value: InstrumentAmount(quantity: 11_000, instrument: aud))
    ]
    let perf = AccountPerformanceCalculator.computeLegacy(
      dailyBalances: dailyBalances, values: values, instrument: aud, now: now)

    #expect(perf.currentValue == InstrumentAmount(quantity: 11_000, instrument: aud))
    #expect(perf.totalContributions == InstrumentAmount(quantity: 10_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 1_000, instrument: aud))
    let pa = try! #require(perf.annualisedReturn)
    let asDouble = (pa as NSDecimalNumber).doubleValue
    #expect(abs(asDouble - 0.10) < 0.005)
  }

  /// Empty values array → unavailable performance.
  @Test("empty values yields unavailable performance")
  func emptyValuesUnavailable() {
    let perf = AccountPerformanceCalculator.computeLegacy(
      dailyBalances: [], values: [], instrument: aud, now: Date())
    #expect(perf.currentValue == nil)
    #expect(perf.profitLoss == nil)
    #expect(perf.annualisedReturn == nil)
  }
}
```

- [ ] **Step 2: Run it**

```bash
just test-mac AccountPerformanceCalculatorLegacyTests 2>&1 | tee .agent-tmp/test-output.txt
grep -B2 -A4 'error:\|FAIL' .agent-tmp/test-output.txt
```

Expected: compile error — `'computeLegacy' is not a member of 'AccountPerformanceCalculator'`.

- [ ] **Step 3: Add `computeLegacy` to the calculator**

Append to `Shared/AccountPerformanceCalculator.swift` inside the `enum AccountPerformanceCalculator { ... }` block (after `compute` and before the private helpers):

```swift
  // MARK: - Legacy manual-valuation

  /// Manual-valuation accounts. Cash flows = consecutive `dailyBalance`
  /// deltas. Terminal value = latest `InvestmentValue`. Synchronous —
  /// legacy accounts are mono-instrument by construction so no conversion
  /// is needed.
  ///
  /// `now` is injected so tests can pin the reference date deterministically;
  /// production callers pass `Date()`.
  static func computeLegacy(
    dailyBalances: [AccountDailyBalance],
    values: [InvestmentValue],
    instrument: Instrument,
    now: Date = Date()
  ) -> AccountPerformance {
    guard let latest = values.max(by: { $0.date < $1.date }) else {
      return .unavailable(in: instrument)
    }

    let sortedBalances = dailyBalances.sorted { $0.date < $1.date }
    var flows: [CashFlow] = []
    var prior = Decimal(0)
    for entry in sortedBalances {
      let delta = entry.balance.quantity - prior
      if delta != 0 {
        flows.append(CashFlow(date: entry.date, amount: delta))
      }
      prior = entry.balance.quantity
    }

    return assemble(
      flows: flows,
      currentValue: latest.value,
      profileCurrency: instrument,
      now: now)
  }
```

- [ ] **Step 4: Run the tests**

```bash
just test-mac AccountPerformanceCalculatorLegacyTests 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'Test Suite|passed|failed' .agent-tmp/test-output.txt | tail -5
```

Expected: 2 tests pass.

- [ ] **Step 5: Format and commit**

```bash
just format
git -C . add Shared/AccountPerformanceCalculator.swift \
    MoolahTests/Shared/AccountPerformanceCalculatorLegacyTests.swift
git -C . commit -m "$(cat <<'EOF'
feat(investments): add AccountPerformanceCalculator.computeLegacy

Manual-valuation entry point: cash flows from dailyBalance deltas,
terminal value from latest InvestmentValue. Synchronous (legacy
accounts are mono-instrument). Shares the assemble() / IRRSolver path
with compute() so day-precise compounding applies to both.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

# Slice 3 — `InvestmentStore` wiring

`accountPerformance` becomes a published property; refresh runs at the same points where positions / values change. The legacy `annualizedReturnRate` (and `InvestmentSummaryView`) stay in place for now — Slice 5 removes them.

## Task 8: Add `accountPerformance` published state and populate from `loadAllData`

**Files:**
- Modify: `Features/Investments/InvestmentStore.swift`

- [ ] **Step 1: Write the failing test**

Append to `MoolahTests/Features/InvestmentStoreTests.swift` inside the existing `struct InvestmentStoreTests { ... }` block:

```swift
  @Test("loadAllData populates accountPerformance for a position-tracked account")
  func loadAllDataPositionTrackedPerformance() async throws {
    let aud = Instrument.AUD
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService)

    let account = Account(name: "Brokerage", type: .investment, instrument: aud)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 10_000, instrument: aud))

    await store.loadAllData(accountId: account.id, profileCurrency: aud)

    let perf = try #require(store.accountPerformance)
    #expect(perf.instrument == aud)
    #expect(perf.totalContributions == InstrumentAmount(quantity: 10_000, instrument: aud))
    _ = bhp  // silences unused-variable warning if reused later
  }

  @Test("loadAllData populates accountPerformance for a legacy-valuation account")
  func loadAllDataLegacyPerformance() async throws {
    let accountId = UUID()
    let aud = Instrument.AUD
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      investmentValues: [
        accountId: [
          InvestmentValue(
            date: Date().addingTimeInterval(-365 * 86_400),
            value: InstrumentAmount(quantity: 10_000, instrument: aud)),
          InvestmentValue(
            date: Date(),
            value: InstrumentAmount(quantity: 11_000, instrument: aud)),
        ]
      ],
      in: database
    )
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService)

    await store.loadAllData(accountId: accountId, profileCurrency: aud)

    let perf = try #require(store.accountPerformance)
    #expect(perf.currentValue == InstrumentAmount(quantity: 11_000, instrument: aud))
  }
```

- [ ] **Step 2: Run them**

```bash
just test-mac InvestmentStoreTests 2>&1 | tee .agent-tmp/test-output.txt
grep -B2 -A4 'error:\|FAIL' .agent-tmp/test-output.txt
```

Expected: compile error — `value of type 'InvestmentStore' has no member 'accountPerformance'`.

- [ ] **Step 3: Add the property and populate from `loadAllData`**

Edit `Features/Investments/InvestmentStore.swift`:

1. Inside `final class InvestmentStore`, just below the existing
   `private(set) var totalPortfolioValue: Decimal?` line, add:

```swift
  /// Lifetime account-level performance numbers in profile currency.
  /// `nil` until `loadAllData(...)` runs, or when conversion failure
  /// during cash-flow extraction marks it unavailable per Rule 11.
  private(set) var accountPerformance: AccountPerformance?
```

2. Replace the body of `loadAllData(accountId:profileCurrency:)` with:

```swift
  func loadAllData(accountId: UUID, profileCurrency: Instrument) async {
    loadedHostCurrency = profileCurrency
    await loadValues(accountId: accountId)
    if hasLegacyValuations {
      await loadDailyBalances(accountId: accountId, hostCurrency: profileCurrency)
      accountPerformance = AccountPerformanceCalculator.computeLegacy(
        dailyBalances: dailyBalances,
        values: values,
        instrument: profileCurrency)
    } else {
      await loadPositions(accountId: accountId)
      await valuatePositions(profileCurrency: profileCurrency, on: Date())
      await refreshPositionTrackedPerformance(
        accountId: accountId, profileCurrency: profileCurrency)
    }
  }

  /// Recompute the position-tracked `accountPerformance`. Reused from
  /// `loadAllData` and `reloadPositionsIfNeeded`. Sets `accountPerformance`
  /// to `nil` and surfaces the error on conversion failure per Rule 11.
  private func refreshPositionTrackedPerformance(
    accountId: UUID, profileCurrency: Instrument
  ) async {
    guard let transactionRepository else {
      accountPerformance = nil
      return
    }
    do {
      let txns = try await fetchAllTransactions(repository: transactionRepository)
      accountPerformance = try await AccountPerformanceCalculator.compute(
        accountId: accountId,
        transactions: txns,
        valuedPositions: valuedPositions,
        profileCurrency: profileCurrency,
        conversionService: conversionService)
    } catch is CancellationError {
      return
    } catch {
      logger.warning(
        "AccountPerformance unavailable: \(error.localizedDescription, privacy: .public)")
      accountPerformance = nil
      self.error = error
    }
  }
```

- [ ] **Step 4: Run the tests**

```bash
just test-mac InvestmentStoreTests 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'Test Suite|passed|failed' .agent-tmp/test-output.txt | tail -10
```

Expected: every existing `InvestmentStoreTests` test passes plus the two new ones.

- [ ] **Step 5: Format and commit**

```bash
just format
git -C . add Features/Investments/InvestmentStore.swift \
    MoolahTests/Features/InvestmentStoreTests.swift
git -C . commit -m "$(cat <<'EOF'
feat(investments): publish accountPerformance from InvestmentStore

loadAllData() now populates accountPerformance via
AccountPerformanceCalculator on both the legacy and position-tracked
branches. New private helper refreshPositionTrackedPerformance() is
the single point of truth for the position-tracked path; reused by
reloadPositionsIfNeeded in Task 9.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Refresh `accountPerformance` on mutations

`reloadPositionsIfNeeded` (after a trade) and `setValue` / `removeValue` (legacy path) must keep `accountPerformance` in sync.

**Files:**
- Modify: `Features/Investments/InvestmentStore.swift`
- Modify: `MoolahTests/Features/InvestmentStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `InvestmentStoreTests`:

```swift
  @Test("setValue refreshes accountPerformance on the legacy path")
  func setValueRefreshesPerformance() async throws {
    let accountId = UUID()
    let aud = Instrument.AUD
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      investmentValues: [
        accountId: [
          InvestmentValue(
            date: Date().addingTimeInterval(-365 * 86_400),
            value: InstrumentAmount(quantity: 10_000, instrument: aud))
        ]
      ],
      in: database
    )
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService)
    await store.loadAllData(accountId: accountId, profileCurrency: aud)

    await store.setValue(
      accountId: accountId,
      date: Date(),
      value: InstrumentAmount(quantity: 12_000, instrument: aud))

    let perf = try #require(store.accountPerformance)
    #expect(perf.currentValue == InstrumentAmount(quantity: 12_000, instrument: aud))
  }

  @Test("reloadPositionsIfNeeded refreshes accountPerformance after a trade")
  func reloadPositionsRefreshesPerformance() async throws {
    let aud = Instrument.AUD
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService)
    let account = Account(name: "Brokerage", type: .investment, instrument: aud)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 5_000, instrument: aud))
    await store.loadAllData(accountId: account.id, profileCurrency: aud)

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(accountId: account.id, instrument: bhp, quantity: 10, type: .trade),
          TransactionLeg(accountId: account.id, instrument: aud, quantity: -1_000, type: .trade),
        ]
      )
    )
    await store.reloadPositionsIfNeeded(accountId: account.id, profileCurrency: aud)

    let perf = try #require(store.accountPerformance)
    // Contributions shouldn't change (no boundary-crossing leg in the new trade).
    #expect(perf.totalContributions == InstrumentAmount(quantity: 5_000, instrument: aud))
  }
```

- [ ] **Step 2: Run and verify the tests fail**

```bash
just test-mac InvestmentStoreTests 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'failed' .agent-tmp/test-output.txt | head
```

Expected: both new tests fail because `setValue`/`reloadPositionsIfNeeded` don't update `accountPerformance` yet (the existing tests that just exercise `loadAllData` keep passing).

- [ ] **Step 3: Wire the refreshes**

Edit `Features/Investments/InvestmentStore.swift`:

1. Replace `reloadPositionsIfNeeded(accountId:profileCurrency:)` with:

```swift
  func reloadPositionsIfNeeded(accountId: UUID, profileCurrency: Instrument) async {
    guard !hasLegacyValuations else { return }
    await loadPositions(accountId: accountId)
    await valuatePositions(profileCurrency: profileCurrency, on: Date())
    await refreshPositionTrackedPerformance(
      accountId: accountId, profileCurrency: profileCurrency)
  }
```

2. Replace `setValue(accountId:date:value:)` with:

```swift
  func setValue(accountId: UUID, date: Date, value: InstrumentAmount) async {
    error = nil
    do {
      try await repository.setValue(accountId: accountId, date: date, value: value)
      let newValue = InvestmentValue(date: date, value: value)
      values.removeAll { $0.date.isSameDay(as: date) }
      values.append(newValue)
      values.sort()
      onInvestmentValueChanged?(accountId, values.first?.value)
      refreshLegacyPerformance(instrument: value.instrument)
    } catch {
      logger.error("Failed to set investment value: \(error.localizedDescription)")
      self.error = error
    }
  }
```

3. Replace `removeValue(accountId:date:)` with:

```swift
  func removeValue(accountId: UUID, date: Date) async {
    error = nil
    do {
      try await repository.removeValue(accountId: accountId, date: date)
      values.removeAll { $0.date.isSameDay(as: date) }
      onInvestmentValueChanged?(accountId, values.first?.value)
      let instrument = values.first?.value.instrument ?? loadedHostCurrency ?? .AUD
      refreshLegacyPerformance(instrument: instrument)
    } catch {
      logger.error("Failed to remove investment value: \(error.localizedDescription)")
      self.error = error
    }
  }
```

4. Add the legacy refresh helper, immediately below `refreshPositionTrackedPerformance(...)`:

```swift
  /// Recompute `accountPerformance` from the in-memory `values` and
  /// `dailyBalances` arrays, after a setValue / removeValue mutation.
  /// Synchronous: the legacy path doesn't need conversion.
  private func refreshLegacyPerformance(instrument: Instrument) {
    accountPerformance = AccountPerformanceCalculator.computeLegacy(
      dailyBalances: dailyBalances,
      values: values,
      instrument: instrument)
  }
```

- [ ] **Step 4: Run the tests**

```bash
just test-mac InvestmentStoreTests 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'Test Suite|passed|failed' .agent-tmp/test-output.txt | tail -10
```

Expected: every test passes (new + existing).

- [ ] **Step 5: Format and commit**

```bash
just format
git -C . add Features/Investments/InvestmentStore.swift \
    MoolahTests/Features/InvestmentStoreTests.swift
git -C . commit -m "$(cat <<'EOF'
feat(investments): refresh accountPerformance on mutations

reloadPositionsIfNeeded (post-trade), setValue, and removeValue all
now refresh the published accountPerformance.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

# Slice 4 — Per-position cost-basis %

Independent of the tile strip; renders directly in the `Gain` column / row caption next to the existing dollar gain.

## Task 10: `ValuedPosition.gainLossPercent`

**Files:**
- Modify: `Domain/Models/ValuedPosition.swift`
- Test: `MoolahTests/Domain/ValuedPositionTests.swift` (create if not present; otherwise extend)

- [ ] **Step 1: Confirm test file location**

```bash
ls /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-pl/MoolahTests/Domain/ValuedPosition*.swift 2>&1 || \
  echo "no existing file — will create"
```

If a file exists, append to it. If not, create
`MoolahTests/Domain/ValuedPositionTests.swift`.

- [ ] **Step 2: Write the failing test**

```swift
// MoolahTests/Domain/ValuedPositionTests.swift  (create if absent)
import Foundation
import Testing

@testable import Moolah

@Suite("ValuedPosition.gainLossPercent")
struct ValuedPositionGainLossPercentTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  @Test("positive gain renders as positive percent")
  func positiveGain() {
    let row = ValuedPosition(
      instrument: bhp, quantity: 100,
      unitPrice: nil,
      costBasis: InstrumentAmount(quantity: 1_000, instrument: aud),
      value: InstrumentAmount(quantity: 1_100, instrument: aud))
    let pct = try! #require(row.gainLossPercent)
    #expect(pct == 10)
  }

  @Test("negative gain renders as negative percent")
  func negativeGain() {
    let row = ValuedPosition(
      instrument: bhp, quantity: 100,
      unitPrice: nil,
      costBasis: InstrumentAmount(quantity: 1_000, instrument: aud),
      value: InstrumentAmount(quantity: 800, instrument: aud))
    let pct = try! #require(row.gainLossPercent)
    #expect(pct == -20)
  }

  @Test("missing cost basis returns nil")
  func missingCostBasisNil() {
    let row = ValuedPosition(
      instrument: bhp, quantity: 100,
      unitPrice: nil, costBasis: nil,
      value: InstrumentAmount(quantity: 1_000, instrument: aud))
    #expect(row.gainLossPercent == nil)
  }

  @Test("zero cost basis returns nil")
  func zeroCostBasisNil() {
    let row = ValuedPosition(
      instrument: bhp, quantity: 100,
      unitPrice: nil,
      costBasis: InstrumentAmount(quantity: 0, instrument: aud),
      value: InstrumentAmount(quantity: 100, instrument: aud))
    #expect(row.gainLossPercent == nil)
  }

  @Test("missing value returns nil")
  func missingValueNil() {
    let row = ValuedPosition(
      instrument: bhp, quantity: 100,
      unitPrice: nil,
      costBasis: InstrumentAmount(quantity: 1_000, instrument: aud),
      value: nil)
    #expect(row.gainLossPercent == nil)
  }
}
```

- [ ] **Step 3: Run it**

```bash
just test-mac ValuedPositionGainLossPercentTests 2>&1 | tee .agent-tmp/test-output.txt
grep -B2 -A4 'error:\|FAIL' .agent-tmp/test-output.txt
```

Expected: compile error — `value of type 'ValuedPosition' has no member 'gainLossPercent'`.

- [ ] **Step 4: Add the property**

Edit `Domain/Models/ValuedPosition.swift`. Append inside the existing
`struct ValuedPosition` body, immediately after the `gainLoss` property:

```swift
  /// Gain as a percentage of cost basis (e.g. `12.5` for +12.5%). `nil`
  /// when `value` is missing, `costBasis` is missing, or `costBasis` is
  /// zero. Per CLAUDE.md the sign is preserved — callers must not `abs()`
  /// the percentage when colouring or sorting.
  var gainLossPercent: Decimal? {
    guard let value, let costBasis, costBasis.quantity != 0 else { return nil }
    return (value.quantity - costBasis.quantity) / costBasis.quantity * 100
  }
```

- [ ] **Step 5: Run the tests**

```bash
just test-mac ValuedPositionGainLossPercentTests 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'Test Suite|passed|failed' .agent-tmp/test-output.txt | tail -5
```

Expected: 5 tests pass.

- [ ] **Step 6: Format and commit**

```bash
just format
git -C . add Domain/Models/ValuedPosition.swift \
    MoolahTests/Domain/ValuedPositionTests.swift
git -C . commit -m "$(cat <<'EOF'
feat(investments): add ValuedPosition.gainLossPercent

Sign-preserved gain/loss percentage (value - cost) / cost. Returns nil
on missing/zero cost basis. Powers the +x.x% appendage in the
PositionsTable Gain column (Task 11) and PositionRow caption (Task 12).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: `PositionsTable.gainCell` renders `$X + Y%`

**Files:**
- Modify: `Shared/Views/Positions/PositionsTable.swift`

- [ ] **Step 1: Open the file and locate `gainCell(_:)`** at lines 89-98 (the function that currently renders only `gain.signedFormatted`).

- [ ] **Step 2: Replace the body with the dollar + percent variant**

Replace:

```swift
  @ViewBuilder
  private func gainCell(_ gain: InstrumentAmount?) -> some View {
    if let gain {
      Text(gain.signedFormatted)
        .monospacedDigit()
        .foregroundStyle(gainColor(gain))
    } else {
      Text("—").foregroundStyle(.tertiary)
    }
  }
```

with:

```swift
  @ViewBuilder
  private func gainCell(_ row: ValuedPosition) -> some View {
    if let gain = row.gainLoss {
      HStack(spacing: 4) {
        Text(gain.signedFormatted)
          .monospacedDigit()
          .foregroundStyle(gainColor(gain))
        if let pct = row.gainLossPercent {
          Text(formattedPercent(pct))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(gainColor(gain))
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(gainAccessibilityLabel(gain: gain, percent: row.gainLossPercent))
    } else {
      Text("—").foregroundStyle(.tertiary)
    }
  }

  /// `+12.3%` / `−4.0%` / `0.0%`. Uses the project's standard one-decimal
  /// place P&L convention (matches `PositionsHeader.plPill`).
  private func formattedPercent(_ pct: Decimal) -> String {
    let sign = pct > 0 ? "+" : ""
    let asDouble = (pct as NSDecimalNumber).doubleValue
    return "\(sign)\(String(format: "%.1f", asDouble))%"
  }

  /// "gain of $1,200, up 12.3 percent" / "loss of $50, down 5.0 percent".
  /// Per UI_GUIDE.md every gain renders an explicit accessibility label
  /// so VoiceOver doesn't read "+12%" as ambiguous.
  private func gainAccessibilityLabel(
    gain: InstrumentAmount, percent: Decimal?
  ) -> String {
    let pctText = percent.map {
      let abs = ($0 < 0 ? -$0 : $0) as NSDecimalNumber
      let formatted = String(format: "%.1f", abs.doubleValue)
      return $0 < 0 ? ", down \(formatted) percent" : ", up \(formatted) percent"
    } ?? ""
    if gain.isNegative {
      return "loss of \((-gain).formatted)\(pctText)"
    }
    if gain.isZero {
      return "no change"
    }
    return "gain of \(gain.formatted)\(pctText)"
  }
```

- [ ] **Step 3: Update the `Gain` column declaration to pass the row**

In the same file, the `wideLayout` body still references the old call site:

```swift
      TableColumn("Gain", value: \.gainQuantity) { row in
        gainCell(row.gainLoss)
      }
```

Change it to:

```swift
      TableColumn("Gain", value: \.gainQuantity) { row in
        gainCell(row)
      }
```

- [ ] **Step 4: Verify the table compiles and the existing previews still render**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -E 'error:|warning:' .agent-tmp/build.txt | grep -v '#Preview' || echo "clean"
```

Expected: `clean`. The two `#Preview`s at the bottom of the file (`mixed wide`, `conversion failure`) drive the preview canvas in Slice 5 Task 13 — no behavioural test runs against them at this point.

- [ ] **Step 5: Format and commit**

```bash
just format
git -C . add Shared/Views/Positions/PositionsTable.swift
git -C . commit -m "$(cat <<'EOF'
feat(investments): show cost-basis % in PositionsTable Gain column

Wide-layout Gain cell now renders signed dollar gain plus +x.x% on its
right (caption-sized). Cells with no cost basis fall back to '—' as
before. Accessibility label reads 'gain of $1,200, up 12.3 percent'.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: `PositionRow.trailingColumn` renders `$X +Y%`

**Files:**
- Modify: `Shared/Views/Positions/PositionRow.swift`

- [ ] **Step 1: Open the file and locate `trailingColumn`** at lines 44-61.

- [ ] **Step 2: Replace the body**

Replace:

```swift
  private var trailingColumn: some View {
    VStack(alignment: .trailing, spacing: 2) {
      if let value = row.value {
        Text(value.formatted)
          .font(.body)
          .monospacedDigit()
      } else {
        Text("—")
          .foregroundStyle(.tertiary)
      }
      if let gain = row.gainLoss {
        Text(gain.signedFormatted)
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(gainColor(gain))
      }
    }
  }
```

with:

```swift
  private var trailingColumn: some View {
    VStack(alignment: .trailing, spacing: 2) {
      if let value = row.value {
        Text(value.formatted)
          .font(.body)
          .monospacedDigit()
      } else {
        Text("—")
          .foregroundStyle(.tertiary)
      }
      if let gain = row.gainLoss {
        Text(gainCaption(gain: gain, percent: row.gainLossPercent))
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(gainColor(gain))
      }
    }
  }

  /// `"+$1,200 +12.3%"` / `"−$50"` (no percent when cost basis missing).
  private func gainCaption(gain: InstrumentAmount, percent: Decimal?) -> String {
    guard let percent else { return gain.signedFormatted }
    let sign = percent > 0 ? "+" : ""
    let asDouble = (percent as NSDecimalNumber).doubleValue
    return "\(gain.signedFormatted)  \(sign)\(String(format: "%.1f", asDouble))%"
  }
```

- [ ] **Step 3: Update the `accessibilityLabel` to include the percent when present**

Replace the existing `accessibilityLabel` computed property body with:

```swift
  private var accessibilityLabel: String {
    var parts: [String] = [row.instrument.name, row.quantityCaption]
    if let value = row.value {
      parts.append("valued at \(value.formatted)")
    } else {
      parts.append("value unavailable")
    }
    if let gain = row.gainLoss {
      let pctSuffix = row.gainLossPercent.map {
        let abs = ($0 < 0 ? -$0 : $0) as NSDecimalNumber
        return ", " + (gain.isNegative ? "down" : "up")
          + " \(String(format: "%.1f", abs.doubleValue)) percent"
      } ?? ""
      if gain.isNegative {
        parts.append("loss of \((-gain).formatted)\(pctSuffix)")
      } else {
        parts.append("gain of \(gain.formatted)\(pctSuffix)")
      }
    }
    return parts.joined(separator: ", ")
  }
```

- [ ] **Step 4: Verify**

```bash
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -E 'error:|warning:' .agent-tmp/build.txt | grep -v '#Preview' || echo "clean"
```

Expected: `clean`.

- [ ] **Step 5: Format and commit**

```bash
just format
git -C . add Shared/Views/Positions/PositionRow.swift
git -C . commit -m "$(cat <<'EOF'
feat(investments): show cost-basis % in PositionRow caption

Narrow-layout row caption now renders signed dollar gain plus
'+x.x%' / '−x.x%' when a cost basis is present. Accessibility label
appends 'up 12.3 percent' / 'down 5.0 percent' for VoiceOver.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

# Slice 5 — `AccountPerformanceTiles` + cleanup

Replaces both the position-tracked single-row header and the legacy
`InvestmentSummaryView` with a unified three-tile strip; deletes the legacy
view and the binary-search IRR helpers it depended on.

## Task 13: `AccountPerformanceTiles` view

**Files:**
- Create: `Shared/Views/Positions/AccountPerformanceTiles.swift`

- [ ] **Step 1: Create the view**

```swift
// Shared/Views/Positions/AccountPerformanceTiles.swift
import SwiftUI

/// Three-tile horizontal strip rendering the account-level numbers from an
/// `AccountPerformance`: Current Value, Profit / Loss (with %), Annualised
/// Return (with "since Mar 2023" subtitle). Replaces both the position-
/// tracked single-row `PositionsHeader` (when a performance is supplied)
/// and the legacy `InvestmentSummaryView`.
///
/// Per Rule 11 in `guides/INSTRUMENT_CONVERSION_GUIDE.md` every tile shows
/// "—" / "Unavailable" rather than a partial sum when its source field
/// is `nil`.
struct AccountPerformanceTiles: View {
  let title: String
  let performance: AccountPerformance

  var body: some View {
    VStack(spacing: 8) {
      Text(title)
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 0) {
        currentValueTile
        Divider().frame(height: 50)
        profitLossTile
        Divider().frame(height: 50)
        annualisedReturnTile
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 12)
  }

  // MARK: - Tiles

  @ViewBuilder
  private var currentValueTile: some View {
    Tile(label: "Current Value", body: {
      if let value = performance.currentValue {
        Text(value.formatted)
          .font(.title3)
          .monospacedDigit()
      } else {
        Text("Unavailable")
          .font(.title3)
          .foregroundStyle(.secondary)
      }
    }, subtitle: nil, subtitleColor: nil)
  }

  @ViewBuilder
  private var profitLossTile: some View {
    Tile(
      label: "Profit / Loss",
      body: {
        if let pl = performance.profitLoss {
          Text(pl.signedFormatted)
            .font(.title3)
            .monospacedDigit()
            .foregroundStyle(plColor)
        } else {
          Text("—")
            .font(.title3)
            .foregroundStyle(.tertiary)
        }
      },
      subtitle: profitLossPercentText,
      subtitleColor: plColor)
  }

  @ViewBuilder
  private var annualisedReturnTile: some View {
    Tile(
      label: "Annualised Return",
      body: {
        if let pa = performance.annualisedReturn {
          Text(formattedPaPercent(pa))
            .font(.title3)
            .monospacedDigit()
            .foregroundStyle(paColor(pa))
        } else {
          Text("—")
            .font(.title3)
            .foregroundStyle(.tertiary)
            .help(annualisedReturnUnavailableTooltip)
        }
      },
      subtitle: sinceText,
      subtitleColor: .secondary)
  }

  // MARK: - Computed strings

  private var profitLossPercentText: String? {
    guard let pct = performance.profitLossPercent else { return nil }
    let sign = pct > 0 ? "+" : ""
    let asDouble = (pct as NSDecimalNumber).doubleValue * 100
    return "\(sign)\(String(format: "%.1f", asDouble))%"
  }

  private var sinceText: String? {
    guard let date = performance.firstFlowDate else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM yyyy"
    return "since \(formatter.string(from: date))"
  }

  private func formattedPaPercent(_ rate: Decimal) -> String {
    let sign = rate > 0 ? "+" : ""
    let asDouble = (rate as NSDecimalNumber).doubleValue * 100
    return "\(sign)\(String(format: "%.1f", asDouble))% p.a."
  }

  private var plColor: Color {
    guard let pl = performance.profitLoss else { return .secondary }
    if pl.isNegative { return .red }
    if pl.isZero { return .primary }
    return .green
  }

  private func paColor(_ rate: Decimal) -> Color {
    if rate < 0 { return .red }
    if rate == 0 { return .primary }
    return .green
  }

  /// Surfaced via `.help(...)` on the unavailable p.a. tile. Distinguishes
  /// "not enough data" from "conversion broke" so the user knows whether
  /// to wait or retry.
  private var annualisedReturnUnavailableTooltip: String {
    if performance.firstFlowDate == nil {
      return "Not enough activity yet"
    }
    return "Annualised return unavailable — conversion may have failed"
  }
}

private struct Tile<Content: View>: View {
  let label: String
  @ViewBuilder let body: () -> Content
  let subtitle: String?
  let subtitleColor: Color?

  var body: some View {
    VStack(spacing: 4) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      body()
      if let subtitle {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(subtitleColor ?? .secondary)
          .monospacedDigit()
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Previews

#Preview("Gain") {
  AccountPerformanceTiles(
    title: "Brokerage",
    performance: AccountPerformance(
      instrument: .AUD,
      currentValue: InstrumentAmount(quantity: 23_405, instrument: .AUD),
      totalContributions: InstrumentAmount(quantity: 21_605, instrument: .AUD),
      profitLoss: InstrumentAmount(quantity: 1_800, instrument: .AUD),
      profitLossPercent: Decimal(0.083),
      annualisedReturn: Decimal(0.083),
      firstFlowDate: Date().addingTimeInterval(-3 * 365 * 86_400)))
  .frame(width: 720)
  .padding()
}

#Preview("Loss") {
  AccountPerformanceTiles(
    title: "Brokerage",
    performance: AccountPerformance(
      instrument: .AUD,
      currentValue: InstrumentAmount(quantity: 9_500, instrument: .AUD),
      totalContributions: InstrumentAmount(quantity: 10_000, instrument: .AUD),
      profitLoss: InstrumentAmount(quantity: -500, instrument: .AUD),
      profitLossPercent: Decimal(-0.05),
      annualisedReturn: Decimal(-0.05),
      firstFlowDate: Date().addingTimeInterval(-365 * 86_400)))
  .frame(width: 720)
  .padding()
}

#Preview("Unavailable") {
  AccountPerformanceTiles(
    title: "Brokerage",
    performance: .unavailable(in: .AUD))
    .frame(width: 720)
    .padding()
}

#Preview("No flows yet") {
  AccountPerformanceTiles(
    title: "Brokerage",
    performance: AccountPerformance(
      instrument: .AUD,
      currentValue: InstrumentAmount(quantity: 0, instrument: .AUD),
      totalContributions: InstrumentAmount(quantity: 0, instrument: .AUD),
      profitLoss: InstrumentAmount(quantity: 0, instrument: .AUD),
      profitLossPercent: nil,
      annualisedReturn: nil,
      firstFlowDate: nil))
  .frame(width: 720)
  .padding()
}
```

- [ ] **Step 2: Build and confirm previews compile**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -E 'error:|warning:' .agent-tmp/build.txt | grep -v '#Preview' || echo "clean"
```

Expected: `clean`. (`#Preview` macro warnings are allowed per CLAUDE.md.)

- [ ] **Step 3: Render the previews and visually inspect**

Use the IDE's `RenderPreview` to confirm each variant lays out correctly:
1. **Gain** — green +$1,800 / +8.3% / +8.3% p.a. with "since [3-year-ago Mon YYYY]"
2. **Loss** — red −$500 / −5.0% / −5.0% p.a. with "since [year-ago Mon YYYY]"
3. **Unavailable** — three "—"/"Unavailable" placeholders in `.tertiary`
4. **No flows yet** — Current Value $0, P/L $0, p.a. "—" with no subtitles

If layout regresses (vertical dividers cut into adjacent text, subtitle wraps awkwardly), tighten `.frame(maxWidth: .infinity)` or padding values; do not skip this step.

- [ ] **Step 4: Format and commit**

```bash
just format
git -C . add Shared/Views/Positions/AccountPerformanceTiles.swift
git -C . commit -m "$(cat <<'EOF'
feat(investments): add AccountPerformanceTiles view

Three-tile strip rendering Current Value / P&L (with %) / Annualised
Return (with 'since Mar 2023' subtitle) from an AccountPerformance.
Unavailable fields render '—' / 'Unavailable' per Rule 11. Help
tooltip on the p.a. tile distinguishes 'not enough data' vs
'conversion may have failed'.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: `PositionsViewInput.performance` + `PositionsView` header swap

**Files:**
- Modify: `Domain/Models/PositionsViewInput.swift`
- Modify: `Shared/Views/Positions/PositionsView.swift`

- [ ] **Step 1: Add the field**

Edit `Domain/Models/PositionsViewInput.swift`. Inside the
`struct PositionsViewInput` body, between
`let historicalValue: HistoricalValueSeries?` and `var totalValue:`, add:

```swift
  /// Account-level performance numbers for the host. Non-nil triggers the
  /// three-tile `AccountPerformanceTiles` strip in place of the single-row
  /// `PositionsHeader`. Non-investment-account hosts leave this `nil` and
  /// keep the existing header layout.
  let performance: AccountPerformance?
```

Then make all of `PositionsViewInput`'s memberwise init call sites continue
to compile by adding a default to the existing initializer. Since
`PositionsViewInput` doesn't declare an explicit init (it relies on the
synthesised memberwise one), add an extension below the struct:

```swift
extension PositionsViewInput {
  init(
    title: String,
    hostCurrency: Instrument,
    positions: [ValuedPosition],
    historicalValue: HistoricalValueSeries?
  ) {
    self.init(
      title: title,
      hostCurrency: hostCurrency,
      positions: positions,
      historicalValue: historicalValue,
      performance: nil)
  }
}
```

This keeps every existing `PositionsViewInput(title:hostCurrency:positions:historicalValue:)` call site working unchanged (preview previews, `TransactionListView+List.swift`, etc.) while letting `InvestmentStore+PositionsInput.swift` opt in to the new field.

- [ ] **Step 2: Update `PositionsView` to swap on `performance`**

Edit `Shared/Views/Positions/PositionsView.swift`. Replace the body
(currently lines 19-44) with:

```swift
  var body: some View {
    if input.shouldHide {
      EmptyView()
    } else {
      VStack(spacing: 0) {
        if let perf = input.performance {
          AccountPerformanceTiles(title: input.title, performance: perf)
        } else {
          PositionsHeader(input: input)
        }
        if input.showsChart {
          Divider()
          PositionsChart(
            input: input,
            range: $range,
            selectedInstrument: $selection
          )
          .padding(.vertical, 8)
        }
        Divider()
        PositionsTable(input: input, selection: $selection)
      }
      #if os(macOS)
        .onExitCommand { selection = nil }
      #endif
      .onChange(of: input) { _, _ in
        selection = nil
      }
    }
  }
```

- [ ] **Step 3: Add a preview that exercises the tile-strip path**

Append to `Shared/Views/Positions/PositionsView.swift` (after the existing previews):

```swift
#Preview("With performance tiles") {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let aud = Instrument.AUD
  return PositionsView(
    input: PositionsViewInput(
      title: "Brokerage",
      hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 250,
          unitPrice: InstrumentAmount(quantity: 45.30, instrument: aud),
          costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
          value: InstrumentAmount(quantity: 11_325, instrument: aud)),
        ValuedPosition(
          instrument: aud, quantity: 2_480,
          unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 2_480, instrument: aud)),
      ],
      historicalValue: nil,
      performance: AccountPerformance(
        instrument: aud,
        currentValue: InstrumentAmount(quantity: 13_805, instrument: aud),
        totalContributions: InstrumentAmount(quantity: 12_605, instrument: aud),
        profitLoss: InstrumentAmount(quantity: 1_200, instrument: aud),
        profitLossPercent: Decimal(0.0952),
        annualisedReturn: Decimal(0.0833),
        firstFlowDate: Date().addingTimeInterval(-2 * 365 * 86_400))
    ),
    range: .constant(.threeMonths)
  )
  .frame(width: 720, height: 480)
}
```

- [ ] **Step 4: Build and confirm compatible call sites**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -E 'error:|warning:' .agent-tmp/build.txt | grep -v '#Preview' || echo "clean"
```

Expected: `clean`. The four-arg initializer on `PositionsViewInput` keeps
`TransactionListView+List.swift:128`, `InvestmentAccountView.swift:16`, and
all preview call sites in `PositionsView.swift` / `PositionsTable.swift` /
`PositionsHeader.swift` / `PositionsChart.swift` compiling unchanged.

- [ ] **Step 5: Format and commit**

```bash
just format
git -C . add Domain/Models/PositionsViewInput.swift \
    Shared/Views/Positions/PositionsView.swift
git -C . commit -m "$(cat <<'EOF'
feat(investments): swap PositionsView header to AccountPerformanceTiles

PositionsViewInput gains an optional `performance` field. When non-nil,
PositionsView renders the new three-tile strip in place of the existing
single-row header. All non-investment callers (transaction list, etc.)
default to nil via an extension initializer and keep the old header.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: Wire `accountPerformance` into `InvestmentStore.positionsViewInput` and replace `InvestmentSummaryView`

**Files:**
- Modify: `Features/Investments/InvestmentStore+PositionsInput.swift`
- Modify: `Features/Investments/Views/InvestmentAccountView.swift`

- [ ] **Step 1: Pass `performance` from the store**

Edit `Features/Investments/InvestmentStore+PositionsInput.swift`. There are
two `return PositionsViewInput(...)` sites: one in the
`guard let transactionRepository else { ... }` branch (line ~25) and one
at the bottom of the function (line ~61).

Update both to pass `performance: accountPerformance`. The early-return
becomes:

```swift
    guard let transactionRepository else {
      let hostCurrency = loadedHostCurrency ?? .AUD
      return PositionsViewInput(
        title: title, hostCurrency: hostCurrency,
        positions: valuedPositions, historicalValue: nil,
        performance: accountPerformance)
    }
```

The terminal return becomes:

```swift
    return PositionsViewInput(
      title: title,
      hostCurrency: hostCurrency,
      positions: rowsWithCost,
      historicalValue: series,
      performance: accountPerformance)
```

- [ ] **Step 2: Replace `InvestmentSummaryView` in `InvestmentAccountView.legacySummary`**

Edit `Features/Investments/Views/InvestmentAccountView.swift`. Replace the
`legacySummary` computed property body (currently lines 93-103) with:

```swift
  @ViewBuilder private var legacySummary: some View {
    if !investmentStore.values.isEmpty,
      let performance = investmentStore.accountPerformance
    {
      AccountPerformanceTiles(title: account.name, performance: performance)
        .padding(.horizontal)
        .padding(.top)
    }
  }
```

This drops the dependency on `InvestmentSummaryView` (which Task 16 will
delete). The legacy chart-and-valuations layout below remains.

Also delete the now-unused computed properties `investedAmount` and
`latestInvestmentValue` if they have no other references — grep first:

```bash
grep -n "investedAmount\|latestInvestmentValue" \
    Features/Investments/Views/InvestmentAccountView.swift
```

If both only appear in `legacySummary` and their own definitions, delete
both definitions (currently lines 39-46 in `InvestmentAccountView.swift`).
If anything else references them, leave them alone.

- [ ] **Step 3: Build, run all investment store tests**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -E 'error:|warning:' .agent-tmp/build.txt | grep -v '#Preview' || echo "clean"
just test-mac InvestmentStoreTests InvestmentStorePositionsInputTests \
    AccountPerformanceCalculatorTests AccountPerformanceCalculatorLegacyTests \
    IRRSolverTests ValuedPositionGainLossPercentTests \
    2>&1 | tee .agent-tmp/test-output.txt
grep -E 'Test Suite|passed|failed' .agent-tmp/test-output.txt | tail -10
```

Expected: build clean, all named test suites pass.

- [ ] **Step 4: Render the `Position-tracked` preview in `InvestmentAccountView.swift`**

Use `mcp__xcode__RenderPreview` to confirm the tile strip now appears
where the `PositionsHeader` used to render. Look for: `Brokerage` title
above three tiles; Current Value showing the BHP position's converted
value; Profit / Loss in green or red depending on the seed's price.

If the strip doesn't appear, the most likely cause is that the seed only
records a `.income` + `.expense` leg pair (single-account, not boundary-
crossing), so `accountPerformance.firstFlowDate` is `nil`. Check
`store.accountPerformance` is non-nil — `.unavailable(...)` is not the same
as `nil`. The tiles render in either case.

- [ ] **Step 5: Format and commit**

```bash
just format
git -C . add Features/Investments/InvestmentStore+PositionsInput.swift \
    Features/Investments/Views/InvestmentAccountView.swift
git -C . commit -m "$(cat <<'EOF'
feat(investments): wire AccountPerformance into both account layouts

positionsViewInput now passes accountPerformance into PositionsViewInput
so the position-tracked layout shows AccountPerformanceTiles. The legacy
layout's legacySummary is rebuilt to render AccountPerformanceTiles
directly, dropping its dependency on InvestmentSummaryView (deleted in
the next commit).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 16: Delete `InvestmentSummaryView` and the legacy `annualizedReturnRate` helpers

**Files:**
- Delete: `Features/Investments/Views/InvestmentSummaryView.swift`
- Modify: `Features/Investments/InvestmentStore+PositionsInput.swift` (remove lines that became dead with `InvestmentSummaryView`)

- [ ] **Step 1: Confirm no production code references `InvestmentSummaryView` or `annualizedReturnRate`**

```bash
grep -rn "InvestmentSummaryView\|annualizedReturnRate" \
    Features/ Shared/ Domain/ App/ 2>&1
```

Expected: no matches outside `InvestmentSummaryView.swift` itself and the
private helpers in `InvestmentStore+PositionsInput.swift`. If there are
unexpected matches (e.g. a leftover preview elsewhere), edit them to use
`AccountPerformanceTiles` and re-run the grep.

- [ ] **Step 2: Delete the view**

```bash
git -C . rm Features/Investments/Views/InvestmentSummaryView.swift
```

- [ ] **Step 3: Remove the legacy IRR helpers**

In `Features/Investments/InvestmentStore+PositionsInput.swift`, delete
lines 88-203 — the `annualizedReturnRate(currentValue:)` method, the
`BalancePoint` / `RateBracket` / `BracketResult` private types, and the
`futureValue` / `bracketReturnRate` / `binarySearchReturnRate` static
methods. Re-grep to confirm nothing else references them:

```bash
grep -n "annualizedReturnRate\|BalancePoint\|RateBracket\|BracketResult\|bracketReturnRate\|binarySearchReturnRate" \
    Features/Investments/InvestmentStore+PositionsInput.swift
```

Expected: no matches.

If the file's `// swiftlint:disable multiline_arguments` opening comment is
no longer needed (the deleted code was the only multi-argument call site),
leave it — it does no harm, and removing it would be a cosmetic change
unrelated to this slice.

- [ ] **Step 4: Build, run the complete test suite**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -E 'error:|warning:' .agent-tmp/build.txt | grep -v '#Preview' || echo "clean"
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'Test Suite.*passed|Test Suite.*failed|Executed' .agent-tmp/test-output.txt | tail -10
```

Expected: build clean, full suite green on both iOS and macOS.

- [ ] **Step 5: Format and commit**

```bash
just format
git -C . add Features/Investments/InvestmentStore+PositionsInput.swift
git -C . commit -m "$(cat <<'EOF'
refactor(investments): remove InvestmentSummaryView and legacy IRR

InvestmentSummaryView and the binary-search annualizedReturnRate (with
its private helpers BalancePoint / RateBracket / BracketResult /
futureValue / bracketReturnRate / binarySearchReturnRate) are
superseded by AccountPerformanceTiles + IRRSolver. The new path is
day-precise (no 30-day-month approximation) and unified across the
legacy and position-tracked layouts.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 17: Pre-PR review and merge-queue handoff

- [ ] **Step 1: Run the agent reviews**

Per `CLAUDE.md` § Agents:

```text
@code-review            # CODE_GUIDE compliance, naming, thin views, TODO format
@concurrency-review     # MainActor / Sendable / async patterns
@ui-review              # AccountPerformanceTiles, PositionRow, PositionsTable
@instrument-conversion-review  # Rule 11 / conversion-date correctness in calculator
```

Apply every Critical / Important / Minor finding. Per memory `feedback_apply_all_review_findings.md` and `feedback_dont_dismiss_review_findings.md`, do not rationalise findings away — fix or ask before deferring.

- [ ] **Step 2: Final formatting + format-check**

```bash
just format
just format-check
```

`just format-check` must exit zero. Per memory `feedback_swiftlint_fix_not_baseline.md`, if a SwiftLint violation surfaces, fix the underlying code (split a file, shorten a function, rename a variable) — do **not** edit `.swiftlint-baseline.yml`.

- [ ] **Step 3: Push and open the PR**

```bash
git -C . push origin feat/investment-pl:feat/investment-pl
gh pr create \
    --base main \
    --head feat/investment-pl \
    --title "feat(investments): account-level P&L and per-position cost-basis %" \
    --body "$(cat <<'EOF'
## Summary
- Adds account-level lifetime numbers for investment accounts: Current Value, Profit / Loss (with %), Annualised Return (with "since [first-flow date]" subtitle).
- Renders them as a three-tile `AccountPerformanceTiles` strip on both the position-tracked and legacy-valuation account layouts.
- Adds a per-position +x.x% cost-basis percentage next to the existing dollar gain in the Gain column / row caption.
- Replaces the legacy binary-search IRR (30-day-month approximation, monthly-rate-as-percent) with day-precise Newton–Raphson seeded by Modified Dietz, with a bisection fallback for pathological multi-root cases.
- Deletes the now-superseded `InvestmentSummaryView`.

Implements [`plans/2026-04-29-investment-pl-design.md`](plans/2026-04-29-investment-pl-design.md) per [`plans/2026-04-30-investment-pl-implementation.md`](plans/2026-04-30-investment-pl-implementation.md).

## Test plan
- [ ] `just test` (full suite, iOS + macOS)
- [ ] Render `AccountPerformanceTiles` previews — Gain / Loss / Unavailable / No flows yet
- [ ] Render `PositionsView "With performance tiles"` preview
- [ ] Render `InvestmentAccountView "Position-tracked"` and default previews — confirm tile strip renders
- [ ] Manual smoke: open Test Profile → an investment account; tile strip + Gain column / row %s render correctly

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Add the PR to the merge queue**

Per memory `feedback_prs_to_merge_queue.md`, every PR opened goes through the merge-queue skill, never manual merge:

```text
Use the @merge-queue-manager agent (or the merge-queue skill directly) to add the new PR number to the train.
```

Don't push further commits after the PR is queued — per memory `feedback_queued_prs_are_frozen.md`, queued PRs are frozen. If post-queue changes are needed, open a follow-up PR and queue that.

---

# Self-review (run before handing off)

**Spec coverage:** Every section of `plans/2026-04-29-investment-pl-design.md` is mapped:

| Spec section | Implementation task |
| --- | --- |
| §1 Architecture (file roster) | Tasks 1, 2, 4, 5, 13 (creates) + 8, 10, 14, 15 (modifies) + 16 (deletes) |
| §2 Cash flow extraction rule | Task 5 (`extractFlows`) + Task 6 (rule edge cases) |
| §3 IRRSolver | Tasks 2, 3 |
| §3 AccountPerformance | Task 4 |
| §3 AccountPerformanceCalculator.compute | Tasks 5, 6 |
| §3 AccountPerformanceCalculator.computeLegacy | Task 7 |
| §3 Edge-case behaviour table | Covered across IRRSolver + Calculator tests (Tasks 3, 6, 7) |
| §4 AccountPerformanceTiles | Task 13 |
| §4 PositionsView header swap | Task 14 |
| §4 ValuedPosition.gainLossPercent | Task 10 |
| §4 PositionsTable / PositionRow Gain cells | Tasks 11, 12 |
| §5 InvestmentStore wiring (loadAllData / reload / setValue / removeValue) | Tasks 8, 9 |
| §5 Wiring `performance:` into `positionsViewInput` | Task 15 |
| §5 Deletion of `annualizedReturnRate` helpers | Task 16 |
| §5 Deletion of `InvestmentSummaryView` | Task 16 |
| §6 Testing strategy | Tasks 2-3 (IRRSolver), 5-7 (Calculator), 8-9 (Store), 10 (ValuedPosition), 13-15 (UI previews) |

**Known limitations from §"Known limitations" of the spec are inherited as-is** — no follow-up tasks needed in this plan:
1. Salary-as-`.income`-direct-to-investment workaround is documented; no behaviour change.
2. Cost basis excluding fees is gated on issue #558; per-position % under-counts the same way it does today.
3. Single `.trade` leg with no counterpart shows "free value"; documented in `extractFlows` doc-comment.
4. Dividend attribution requires schema work; out of scope.
5. Pathological IRR multi-root cases return the first root; documented in `IRRSolver` doc-comment.
6. Cross-currency rate failure marks the whole performance unavailable per Rule 11; throwing path tested in Task 6.

**Type consistency:** `AccountPerformance` field names (`currentValue`, `totalContributions`, `profitLoss`, `profitLossPercent`, `annualisedReturn`, `firstFlowDate`) are used identically across Tasks 4, 5, 7, 8, 13, 14. `IRRSolver.annualisedReturn(flows:terminalValue:terminalDate:)` signature is the same across Tasks 2, 3, 5, 7. `ValuedPosition.gainLossPercent` is named consistently across Tasks 10, 11, 12.

**Placeholder scan:** No "TBD", "implement later", "add appropriate error handling", or "write tests for the above" patterns. Every code step shows the actual code. Every test step shows at least one canonical test body; broader coverage matrices are inlined directly (Task 3 has 5 inlined edge tests, Task 6 has 5 inlined §2-rule tests) rather than referenced abstractly.
