# Fold `.expense` fee legs into trade cost basis — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `TradeEventClassifier` fold attached `.expense` (fee) legs into per-unit `costPerUnit` (Buy) and `proceedsPerUnit` (Sell), with foreign-currency fees converted to host currency on the trade date and split evenly across capital events.

**Architecture:** Pure-function change to `Shared/TradeEventClassifier.swift`. After the existing trade-leg guards, sum `.expense` legs in host currency (with a same-instrument fast path), negate to get a positive cost contribution, divide evenly across capital events, and adjust each event's per-unit number. Doc-comment rewritten to reflect the new policy.

**Tech Stack:** Swift 6, Swift Testing (`@Test`, `#expect`, `#require`), `InstrumentConversionService`, project test doubles (`FixedConversionService`, `DateBasedFixedConversionService`).

**Spec:** `plans/2026-05-03-trade-fees-cost-basis-design.md`. Read it before starting Task 1.

---

## File Map

- **Modify:** `Shared/TradeEventClassifier.swift` — algorithm extension + doc-comment rewrite. ~25 lines added inside `classify(...)`, ~10 lines of doc-comment replaced.
- **Modify:** `MoolahTests/Shared/TradeEventClassifierTests.swift` — delete one test (`feeIgnored`), add seven new tests.
- **Create:** `MoolahTests/Support/RecordingConversionService.swift` — small test double (single file, ~35 lines) that records every `convert(...)` call so the host-currency fast-path test can assert "no call was made for the AUD fee leg". Lives next to existing test doubles in `MoolahTests/Support/`. Defines a top-level `RecordingConversionServiceCall` struct (kept top-level rather than nested to avoid the SwiftLint `nesting: type_level: 1` warning).

No project.yml change needed — both target dirs (`Shared/` and `MoolahTests/`) are already glob-included. No CloudKit schema change. No public API change to `classify(...)`.

---

## Task 1: Add `RecordingConversionService` test double

**Why:** The `hostCurrencyFeeNeedsNoConversionLookup` test in Task 5 needs to assert that the classifier did **not** call the conversion service for an AUD fee leg on an AUD-host trade. Existing test doubles either short-circuit same-instrument calls inside the service (hiding whether the classifier called them), throw on every call (would also throw on the legitimate pair-leg conversion), or count `convertAmount` only (the classifier uses `convert`). A small per-call recorder is the cleanest fit.

**Files:**
- Create: `MoolahTests/Support/RecordingConversionService.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation
import os

@testable import Moolah

/// One recorded call to `RecordingConversionService.convert(...)`. Top-level
/// (not nested in the service) so the SwiftLint `nesting: type_level` rule
/// stays at 0 — adding a nested type would cross the warn threshold and
/// cannot be appeased without growing the baseline.
struct RecordingConversionServiceCall: Sendable, Equatable {
  let quantity: Decimal
  let fromId: String
  let toId: String
  let date: Date
}

/// Test conversion service that records every `convert(_:from:to:on:)` call
/// so tests can assert which conversions the caller actually performed.
/// Returns `quantity` unchanged (1:1 fallback) on every call — this double
/// is for *call-site* assertions, not rate behaviour.
///
/// Backed by `OSAllocatedUnfairLock` so it is async-safe and `Sendable` and
/// usable from any isolation domain (same lock-around-mutable-state pattern
/// as `FailureLog` in `ThrowingCountingConversionService.swift`).
final class RecordingConversionService: InstrumentConversionService, Sendable {
  private let recorded = OSAllocatedUnfairLock<[RecordingConversionServiceCall]>(
    initialState: [])

  var calls: [RecordingConversionServiceCall] { recorded.withLock { $0 } }

  func convert(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) async throws -> Decimal {
    recorded.withLock {
      $0.append(
        RecordingConversionServiceCall(
          quantity: quantity, fromId: from.id, toId: to.id, date: date))
    }
    return quantity
  }

  func convertAmount(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> InstrumentAmount {
    let value = try await convert(
      amount.quantity, from: amount.instrument, to: instrument, on: date)
    return InstrumentAmount(quantity: value, instrument: instrument)
  }
}
```

- [ ] **Step 2: Build to verify the file compiles**

Run from `.worktrees/fix-issue-558`:

```bash
just build-mac 2>&1 | tee .agent-tmp/build.txt | tail -20
```

Expected: BUILD SUCCEEDED. If it fails, fix the compile errors before proceeding (do not move to Task 2 with a broken build).

Clean up: `rm .agent-tmp/build.txt`

- [ ] **Step 3: Format and commit**

```bash
just format
git -C $(pwd) add MoolahTests/Support/RecordingConversionService.swift
git -C $(pwd) commit -m "$(cat <<'EOF'
test(support): add RecordingConversionService test double

Records every convert(_:from:to:on:) call so call-site assertions
(e.g. "the classifier did not call the conversion service for a
host-currency fee leg") can be expressed directly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Write all seven new tests + delete `feeIgnored`

**Why:** TDD red phase. We add the full failing-test suite up front so the production-code task in Task 3 can be a single coherent change verified against all behavioural cases at once. This is appropriate granularity for a ~25-line algorithm extension where the tests collectively form the spec.

**Files:**
- Modify: `MoolahTests/Shared/TradeEventClassifierTests.swift`

- [ ] **Step 1: Replace the test file body**

Open `MoolahTests/Shared/TradeEventClassifierTests.swift`. Make the following edits:

**(a) Delete the `feeIgnored` test** (lines 69–77 in the current file — the test function plus its preceding `@Test("fee legs are ignored")` attribute and the blank line that follows). Its assertion `costPerUnit == 40` contradicts the new policy (`40.10`); we replace it below with `buyFoldsAUDFee`.

**(b) Add a USD instrument field** above the test functions (right after the `account` field at the top of the suite):

```swift
  let usd = Instrument.USD
```

`Instrument.USD` is a static convenience constant defined at
`Domain/Models/Instrument.swift:92` — it expands to `Instrument.fiat(code: "USD")`.
Used by `buyFoldsFXFee` to provide a foreign-currency fee leg.

Also confirm the existing `date` field in this suite is a past date —
the existing `let date = Date(timeIntervalSince1970: 1_700_000_000)` is
November 2023, which is in the past. This is a precondition for the
`buyFoldsFXFee` test's wrong-date detection to work: the test relies on
`Date()` (today, at test-run time) being strictly *later* than `date +
1 day` so that a buggy implementation passing `Date()` instead of `date`
would pick the 2.0 rate (later entry) and fail the assertion. If the
existing fixture is ever changed to a future date, that test loses its
bite.

**(c) Append the seven new test functions** at the end of the suite (immediately before the closing brace):

```swift
  // MARK: - Fee-folding tests (#558)

  @Test("buy: AUD fee on AUD-host trade folds into per-unit cost")
  func buyFoldsAUDFee() async throws {
    let legs = [tradeLeg(aud, -4_000), tradeLeg(bhp, 100), feeLeg(aud, -10)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:]))
    try #require(result.buys.count == 1)
    #expect(result.buys[0].costPerUnit == Decimal(40) + Decimal(10) / Decimal(100))
    #expect(result.sells.isEmpty)
  }

  @Test("sell: fee reduces per-unit proceeds")
  func sellReducesProceedsByFee() async throws {
    let legs = [tradeLeg(aud, 2_500), tradeLeg(bhp, -50), feeLeg(aud, -10)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:]))
    try #require(result.sells.count == 1)
    #expect(result.sells[0].proceedsPerUnit == Decimal(50) - Decimal(10) / Decimal(50))
    #expect(result.buys.isEmpty)
  }

  @Test("buy: multiple AUD fee legs sum")
  func buyFoldsMultipleFees() async throws {
    let legs = [
      tradeLeg(aud, -4_000), tradeLeg(bhp, 100),
      feeLeg(aud, -10), feeLeg(aud, -3),
    ]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:]))
    try #require(result.buys.count == 1)
    #expect(result.buys[0].costPerUnit == Decimal(40) + Decimal(13) / Decimal(100))
  }

  @Test("buy: fee debit and equal refund credit cancel to zero")
  func feeContributionsCancelToZero() async throws {
    let legs = [
      tradeLeg(aud, -4_000), tradeLeg(bhp, 100),
      feeLeg(aud, -10), feeLeg(aud, 10),
    ]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:]))
    try #require(result.buys.count == 1)
    #expect(result.buys[0].costPerUnit == Decimal(40))
  }

  @Test("buy: FX fee converts at the trade date")
  func buyFoldsFXFee() async throws {
    // Two rate entries straddling the trade date. If the implementation
    // accidentally passes Date() instead of `date`, the lookup picks the
    // 2.0 rate and the assertion below fails — making the wrong-date bug
    // detectable rather than silent.
    let nextDay = date.addingTimeInterval(86_400)
    let service = DateBasedFixedConversionService(rates: [
      date: [usd.id: Decimal(string: "1.5")!],
      nextDay: [usd.id: Decimal(2)],
    ])
    let legs = [tradeLeg(aud, -4_000), tradeLeg(bhp, 100), feeLeg(usd, -5)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud, conversionService: service)
    try #require(result.buys.count == 1)
    // -5 USD * 1.5 = -7.5 AUD; negate → +7.5; / 100 BHP → 0.075 per unit
    #expect(
      result.buys[0].costPerUnit
        == Decimal(40) + Decimal(string: "7.5")! / Decimal(100))
  }

  @Test("swap: fee splits evenly across both capital events")
  func swapSplitsFeeEvenlyAcrossEvents() async throws {
    let service = FixedConversionService(rates: [
      eth.id: Decimal(3_000),
      btc.id: Decimal(60_000),
    ])
    let legs = [tradeLeg(eth, -2), tradeLeg(btc, Decimal(string: "0.1")!), feeLeg(aud, -50)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud, conversionService: service)
    try #require(result.buys.count == 1)
    try #require(result.sells.count == 1)
    // 50 / 2 events = 25 AUD per event.
    #expect(result.buys[0].instrument == btc)
    #expect(
      result.buys[0].costPerUnit
        == Decimal(60_000) + Decimal(25) / Decimal(string: "0.1")!)
    #expect(result.sells[0].instrument == eth)
    #expect(
      result.sells[0].proceedsPerUnit
        == Decimal(3_000) - Decimal(25) / Decimal(2))
  }

  @Test("buy: host-currency fee skips the conversion service")
  func hostCurrencyFeeNeedsNoConversionLookup() async throws {
    // RecordingConversionService records every convert() call without a
    // same-instrument short-circuit. The pair-leg conversion (AUD→AUD,
    // for the BHP capital leg) goes through the service unconditionally
    // — the classifier does not fast-path the *pair* leg today — so the
    // recorder sees that one call. The fee leg (also AUD on AUD-host)
    // MUST be fast-pathed inside the classifier so the recorder sees
    // exactly one call total. If the fast path is missing, the recorder
    // sees two calls and `count == 1` catches it.
    let service = RecordingConversionService()
    let legs = [tradeLeg(aud, -4_000), tradeLeg(bhp, 100), feeLeg(aud, -10)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud, conversionService: service)
    try #require(result.buys.count == 1)
    #expect(result.buys[0].costPerUnit == Decimal(40) + Decimal(10) / Decimal(100))
    // RecordingConversionService returns input unchanged (1:1), so the
    // pair-leg conversion still produces -4 000.
    #expect(service.calls.count == 1)
    #expect(service.calls.first?.quantity == -4_000)
  }
```

- [ ] **Step 2: Run the new tests to verify they fail**

```bash
mkdir -p .agent-tmp
just test-mac TradeEventClassifierTests 2>&1 | tee .agent-tmp/red.txt | tail -40
```

Expected: every one of the seven new tests **fails** (the production code still discards `.expense` legs, so cost/proceeds come out at the no-fee values). The pre-existing tests (`buy`, `sell`, `swap`, `nonTradeLegsIgnored`, `zeroQuantityTradeLeg`, `fewerThanTwo`) still pass — they have no `.expense` leg.

Specifically expect:
- `buyFoldsAUDFee`: actual `costPerUnit == 40`, expected `40.10`. FAIL.
- `sellReducesProceedsByFee`: actual `proceedsPerUnit == 50`, expected `49.80`. FAIL.
- `buyFoldsMultipleFees`: actual 40, expected `40.13`. FAIL.
- `feeContributionsCancelToZero`: actual 40, expected 40. **PASS** (sum-to-zero degenerates to no-fee). That's fine — the test still proves the path doesn't crash, which is half its purpose; Task 3 will keep it green.
- `buyFoldsFXFee`: actual 40, expected `40.075`. FAIL.
- `swapSplitsFeeEvenlyAcrossEvents`: actual BTC 60 000 / ETH 3 000, expected 60 250 / 2 987.5. FAIL.
- `hostCurrencyFeeNeedsNoConversionLookup`: actual cost 40, expected `40.10`. FAIL on the cost assertion. Call-count assertion may PASS today (no fee call is made because fee is ignored entirely) — that's fine, Task 3 must keep that property.

Confirm by `grep -E "buyFolds|sellReduces|swapSplits|feeContrib|hostCurrency" .agent-tmp/red.txt` — function names are stable in xcodebuild output. Six failures expected.

If you see anything other than this pattern, debug before proceeding. Do **not** start Task 3 if a pre-existing test failed (that's a regression already, before any production change).

Clean up: `rm .agent-tmp/red.txt`

- [ ] **Step 3: Format, verify, and commit the failing tests**

```bash
just format
just format-check 2>&1 | tail -10
```

Expected: `format-check` exits 0. If it complains, fix the underlying
code — never edit `.swiftlint-baseline.yml`.

```bash
git -C $(pwd) add MoolahTests/Shared/TradeEventClassifierTests.swift
git -C $(pwd) commit -m "$(cat <<'EOF'
test(trade): add fee-folding tests; delete feeIgnored

TDD red phase for #558 — seven new behavioural tests covering AUD/FX
fees, multi-fee summing, sum-to-zero, sell-side proceeds reduction,
non-fiat swap even-split, and host-currency fast-path enforcement.
Production change in TradeEventClassifier follows next.

The previous feeIgnored test asserted the now-wrong behaviour
(costPerUnit == 40) and is deleted. buyFoldsAUDFee uses the same
fixture with the new expectation (40.10).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Note: this commit deliberately leaves the test suite red. The next task makes it green. This is standard TDD; the next task lands within minutes.

---

## Task 3: Implement fee folding + doc-comment rewrite

**Why:** TDD green phase. One coherent code change that takes all seven new tests from red to green and updates the doc-comment to reflect the new policy.

**Files:**
- Modify: `Shared/TradeEventClassifier.swift`

- [ ] **Step 1: Replace the `classify(...)` body and the doc-comment**

Open `Shared/TradeEventClassifier.swift`. Replace the doc-comment at lines 23–36 and the entire `classify(...)` function with:

```swift
/// Classifies a transaction's `.trade` legs into FIFO buy / sell events.
///
/// Per design §2, the classifier filters by `type == .trade` to identify
/// capital legs. For each one, the per-unit value is derived from the
/// *other* `.trade` leg's value converted to `hostCurrency` on the
/// transaction date.
///
/// Attached `.expense` legs are folded into per-unit cost: each fee leg
/// is converted to `hostCurrency` on the trade date (or summed directly
/// when already in `hostCurrency`), summed, and split *evenly* across
/// the capital events. Even split is deterministic and avoids the extra
/// conversion call value-weighting would require; for the typical
/// two-leg fair-value swap the result is the same to within rounding.
/// Buy events have the per-unit fee added to `costPerUnit`; Sell events
/// have it subtracted from `proceedsPerUnit`. Transfers (`In` / `Out`)
/// do not enter the classifier and are unaffected.
///
/// Only non-fiat legs emit capital events. In a fiat+non-fiat pair the
/// fiat leg is the price carrier; in a non-fiat swap both legs emit events.
/// Zero-quantity `.trade` legs cause the whole classification to return empty
/// (no divide-by-zero, no half-emitted event).
enum TradeEventClassifier {
  static func classify(
    legs: [TransactionLeg],
    on date: Date,
    hostCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> TradeEventClassification {
    let tradeLegs = legs.filter { $0.type == .trade }
    guard tradeLegs.count == 2 else {
      return TradeEventClassification(buys: [], sells: [])
    }

    // If either trade leg has a zero quantity, we cannot compute a per-unit
    // price and there is no meaningful event to emit.
    guard tradeLegs[0].quantity != 0, tradeLegs[1].quantity != 0 else {
      return TradeEventClassification(buys: [], sells: [])
    }

    // Fiat legs act as the price carrier; non-fiat legs are the capital assets.
    // In a non-fiat swap both legs generate capital events; in a fiat-paired
    // trade only the non-fiat leg does.
    let nonFiatIndices = tradeLegs.indices.filter {
      tradeLegs[$0].instrument.kind != .fiatCurrency
    }
    let capitalIndices = nonFiatIndices.isEmpty ? Array(tradeLegs.indices) : nonFiatIndices

    // Sum attached fee legs in hostCurrency. Same-instrument fast path is
    // enforced here at the call site, not delegated to the conversion
    // service — that keeps the host-currency case off the async hop and
    // is directly testable (see hostCurrencyFeeNeedsNoConversionLookup).
    var totalFeeHost: Decimal = 0
    for feeLeg in legs where feeLeg.type == .expense {
      if feeLeg.instrument == hostCurrency {
        totalFeeHost += feeLeg.quantity
      } else {
        totalFeeHost += try await conversionService.convert(
          feeLeg.quantity, from: feeLeg.instrument, to: hostCurrency, on: date)
      }
    }
    // Negate: fee-leg quantity is negative by convention (cost paid out).
    // Negating turns the sum into a positive cost contribution. A positive
    // .expense leg (a refund attached to a trade) becomes a negative
    // contribution, correctly reducing cost. Sign-preserving on purpose;
    // never abs().
    let feeContribution = -totalFeeHost
    // feePerEvent is a per-event total in hostCurrency (NOT yet per-unit).
    // Step further down divides by leg.quantity.magnitude to get per-unit.
    let feePerEvent = feeContribution / Decimal(capitalIndices.count)

    var buys: [TradeBuyEvent] = []
    var sells: [TradeSellEvent] = []
    for index in capitalIndices {
      let leg = tradeLegs[index]
      let pairIndex = index == 0 ? 1 : 0
      let pair = tradeLegs[pairIndex]
      let pairValue = try await conversionService.convert(
        pair.quantity, from: pair.instrument, to: hostCurrency, on: date)
      // pair.quantity has the *opposite* sign by convention (paid vs received),
      // so |pairValue / leg.quantity| is the per-unit cost or proceed. abs()
      // here gives the magnitude of the exchange rate, NOT a monetary amount;
      // the buy-vs-sell sign is carried by `leg.quantity > 0` below.
      let perUnit = abs(pairValue / leg.quantity)
      // The Sell formula uses subtraction so a positive feePerUnit (the
      // normal-fee case) reduces proceeds, and a negative feePerUnit
      // (the refund case from Decision 4) increases them. Buy is the
      // mirror — addition gives cost-up for fees, cost-down for refunds.
      let feePerUnit = feePerEvent / leg.quantity.magnitude
      if leg.quantity > 0 {
        buys.append(
          TradeBuyEvent(
            instrument: leg.instrument,
            quantity: leg.quantity,
            costPerUnit: perUnit + feePerUnit))
      } else {
        sells.append(
          TradeSellEvent(
            instrument: leg.instrument,
            quantity: -leg.quantity,
            proceedsPerUnit: perUnit - feePerUnit))
      }
    }
    return TradeEventClassification(buys: buys, sells: sells)
  }
}
```

Two notes on details:

1. `.magnitude` is available on `Decimal` via `SignedNumeric` conformance — no fallback should be needed. If a future compiler revision changes that, `abs(leg.quantity)` is a drop-in equivalent.

2. The fee-leg loop reads from `legs` (the original parameter), not `tradeLegs` — correct, because `tradeLegs` was filtered down to `.trade` only and would never contain `.expense` legs.

- [ ] **Step 2: Run the test class to verify all green**

```bash
mkdir -p .agent-tmp
just test-mac TradeEventClassifierTests 2>&1 | tee .agent-tmp/green.txt | tail -40
```

Expected: all tests in the suite pass. The seven new tests now succeed; the pre-existing six tests still succeed. No failures.

If any test fails:
- For arithmetic mismatches, recompute by hand using the exact `Decimal` literal forms in the assertion — the test file deliberately avoids `Decimal(40.075)` (which loses precision through `Double`).
- For `hostCurrencyFeeNeedsNoConversionLookup` failing on `service.calls.count == 1`, the host-currency fast path in step 2 of the algorithm is missing or has the comparison wrong (`feeLeg.instrument == hostCurrency` — both sides are `Instrument`, which is `Equatable`; if the test sees 2 calls, the fast path is bypassed).

Clean up: `rm .agent-tmp/green.txt`

- [ ] **Step 3: Run the full mac test suite to check for regressions**

`TradeEventClassifier` is consumed by `CapitalGainsCalculator`, `PositionsHistoryBuilder`, and `InvestmentStore+PositionsInput`. None of their existing tests use `.expense` legs in trade transactions (verified: `grep -rn "feeLeg\|\.expense" MoolahTests/` returns only the new test file we just edited and a handful of unrelated suites). But run the broader suite to be sure:

```bash
mkdir -p .agent-tmp
just test-mac 2>&1 | tee .agent-tmp/full.txt | tail -30
grep -i "failed\|error:" .agent-tmp/full.txt || echo "ALL CLEAN"
```

Expected: ALL CLEAN. If anything broke, investigate before proceeding — a downstream consumer probably has a fixture with an `.expense` leg attached to a trade that we didn't anticipate.

Clean up: `rm .agent-tmp/full.txt`

- [ ] **Step 4: Format and check for warnings**

```bash
just format
just format-check 2>&1 | tail -10
```

Expected: format-check exits 0. No new SwiftLint warnings (baseline must not change). If format-check complains, fix the underlying code — **never** modify `.swiftlint-baseline.yml`.

- [ ] **Step 5: Commit**

```bash
git -C $(pwd) add Shared/TradeEventClassifier.swift
git -C $(pwd) commit -m "$(cat <<'EOF'
feat(trade): fold .expense fee legs into per-unit cost basis

Closes #558. TradeEventClassifier now sums attached .expense legs
(converted to hostCurrency on the trade date, host-currency legs
fast-pathed without a service call), splits the total evenly across
capital events, and adjusts each event's per-unit number — added to
costPerUnit for Buys, subtracted from proceedsPerUnit for Sells.

Sign-preserving: a positive .expense leg (refund attached to a
trade) correctly reduces the cost contribution rather than being
discarded by abs(). Doc-comment rewritten to describe the new policy
and call out why even split (not value-weighted).

Out of scope: In/Out transfers, which never enter the classifier.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final Verification

After Task 3, before proceeding to the code-review loop:

- [ ] **Sanity-check git state**

```bash
git -C $(pwd) status
git -C $(pwd) log --oneline origin/main..HEAD
```

Expected: working tree clean. Three commits ahead of `origin/main`:
1. `test(support): add RecordingConversionService test double`
2. `test(trade): add fee-folding tests; delete feeIgnored`
3. `feat(trade): fold .expense fee legs into per-unit cost basis`

- [ ] **Final test-suite run** (one more time, paranoid)

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/final.txt | tail -20
grep -i "failed\|error:" .agent-tmp/final.txt || echo "FINAL: ALL CLEAN"
rm .agent-tmp/final.txt
```

Expected: FINAL: ALL CLEAN on both `MoolahTests_iOS` and `MoolahTests_macOS`.

If anything failed, do not move on — investigate and fix before the code-review loop.
