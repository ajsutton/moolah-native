# Forecast Currency Conversion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert foreign-currency scheduled transactions to the profile instrument before they enter the forecast accumulator so the app does not crash when building the forecast graph for a multi-currency profile.

**Architecture:** `CloudKitAnalysisRepository.generateForecast` currently calls the synchronous `applyTransaction` which does `InstrumentAmount += leg.amount`. `InstrumentAmount.+` has a `precondition` that crashes if the two amounts have different instruments. Scheduled transactions whose legs use a non-profile instrument (now possible because the per-account currency picker has shipped) therefore crash the forecast. Fix: pre-convert each extrapolated scheduled-transaction instance's legs to the profile instrument before accumulation, using the current exchange rate (`Date()`). Scheduled transaction dates are in the future, and the Frankfurter API cannot return future rates — today's rate is the reasonable "best estimate." Existing synchronous accumulator logic stays unchanged; `generateForecast` becomes `async throws` and threads a `conversionService`.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, in-memory SwiftData via `TestBackend`.

---

## Background for the Implementer

- `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift` has **two** call paths that build daily balances:
  - Instance method `fetchDailyBalances(after:forecastUntil:)` at line 133 — used directly by contract tests and any caller that only wants balances.
  - Static `computeDailyBalances(...)` at line 509 — used by `loadAll()` for concurrent compute.
  Both call the same `Self.generateForecast(...)` helper at line 1044. Both must be updated consistently.
- `InstrumentAmount.+` and `+=` live in [Domain/Models/InstrumentAmount.swift:56](Domain/Models/InstrumentAmount.swift:56). They crash on mismatched instruments (not just wrong math).
- `generateForecast` today accumulates `balance`, `investments`, `perEarmarkAmounts` (all pinned to the profile `instrument`) by calling `applyTransaction` in a loop. It does **not** take a `conversionService`.
- `TransactionLeg.amount` is computed from `quantity` + `instrument` — see [Domain/Models/TransactionLeg.swift:28](Domain/Models/TransactionLeg.swift:28). `Transaction.legs` is a `var` — see [Domain/Models/Transaction.swift:75](Domain/Models/Transaction.swift:75) — so we can replace legs on an extrapolated instance.
- `InstrumentConversionService.convert(_:from:to:on:)` is the protocol conversion API. `FiatConversionService` throws if either instrument is non-fiat; the live app currently only supports fiat conversion for forecast. We preserve that behaviour — if conversion throws, `fetchDailyBalances` / `computeDailyBalances` throw, which propagates to the analysis store (same behaviour as `computeExpenseBreakdown` today).
- Tests use `FixedConversionService` ([MoolahTests/Support/FixedConversionService.swift](MoolahTests/Support/FixedConversionService.swift)) which ignores the `date` parameter. `CloudKitAnalysisTestBackend` in [MoolahTests/Domain/AnalysisRepositoryContractTests.swift:2113](MoolahTests/Domain/AnalysisRepositoryContractTests.swift:2113) accepts an optional `conversionService`.
- Build/test runner: **always** use `just` (see CLAUDE.md). Capture output to `.agent-tmp/`. Pre-commit: **zero compiler warnings** in user code (`SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`).

## File Structure

| File | Responsibility |
|------|---------------|
| `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift` | Modify `generateForecast` to accept `conversionService` and pre-convert legs; update both call sites. |
| `MoolahTests/Domain/AnalysisRepositoryContractTests.swift` | New multi-currency forecast test. |

No new files. No protocol changes — `generateForecast` is `private static`.

---

## Task 1: Add failing test for multi-currency forecast

**Files:**
- Modify: `MoolahTests/Domain/AnalysisRepositoryContractTests.swift` — add new test at end of "Multi-Currency Conversion Tests" section (near the existing tests at line 1890, 1937, 1980).

- [ ] **Step 1: Write the failing test**

Add this test inside the test struct, adjacent to the existing multi-currency tests (i.e. before the `// MARK: - loadAll Tests` section you find nearby, following the pattern of the three existing `...convertsForeignCurrency` tests):

```swift
@Test("forecast converts foreign-currency scheduled transactions to profile currency")
func forecastConvertsForeignCurrencyScheduled() async throws {
  // USD -> AUD at 1.5x rate. FixedConversionService ignores the conversion date,
  // so "current rate" is irrelevant to test outcome — the test just verifies we
  // don't crash and that the converted amount lands in the forecast balance.
  let conversion = FixedConversionService(rates: ["USD": Decimal(string: "1.5")!])
  let backend = CloudKitAnalysisTestBackend(conversionService: conversion)

  let audAccount = Account(
    id: UUID(), name: "AUD Account", type: .bank, instrument: .defaultTestInstrument)
  _ = try await backend.accounts.create(audAccount)

  let calendar = Calendar(identifier: .gregorian)
  let today = calendar.startOfDay(for: Date())
  let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
  let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
  let nextWeek = calendar.date(byAdding: .day, value: 7, to: today)!
  let usd = Instrument.fiat(code: "USD")

  // Opening AUD balance so forecast has a starting value.
  _ = try await backend.transactions.create(
    Transaction(
      date: yesterday,
      payee: "Opening",
      legs: [
        TransactionLeg(
          accountId: audAccount.id, instrument: .defaultTestInstrument,
          quantity: 1000, type: .openingBalance)
      ]))

  // Scheduled USD expense -100 USD (one-off, future-dated).
  // Expected: pre-converted to -150 AUD before entering the forecast accumulator.
  _ = try await backend.transactions.create(
    Transaction(
      id: UUID(),
      date: tomorrow,
      payee: "US Subscription",
      recurPeriod: .once,
      legs: [
        TransactionLeg(
          accountId: audAccount.id, instrument: usd,
          quantity: -100, type: .expense)
      ]))

  // Fetch balances with forecast enabled.
  let balances = try await backend.analysis.fetchDailyBalances(
    after: nil, forecastUntil: nextWeek)

  // There must be a forecast entry for tomorrow.
  let forecastEntry = balances.first { $0.date == tomorrow && $0.isForecast }
  #expect(forecastEntry != nil, "expected a forecast entry for tomorrow")

  // Starting balance was 1000 AUD; forecast leg is -100 USD * 1.5 = -150 AUD.
  // Running balance after the scheduled expense = 850 AUD.
  #expect(forecastEntry?.balance.quantity == 850)
  #expect(forecastEntry?.balance.instrument == .defaultTestInstrument)
}
```

- [ ] **Step 2: Run the test and confirm it fails (crash or wrong value)**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/forecast-test-fail.txt
grep -B2 -A8 'forecastConvertsForeignCurrencyScheduled' .agent-tmp/forecast-test-fail.txt
```

Expected outcome: either a precondition failure ("Cannot add amounts with different instruments: AUD + USD") during the forecast accumulator, or a test assertion failure. Either confirms the bug. Do NOT commit yet.

---

## Task 2: Add static helper that pre-converts a transaction's legs

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift` — add helper near `convertedAmount` (line 488-504).

- [ ] **Step 1: Add the helper method**

Insert immediately after `convertedAmount` (after line 504):

```swift
  /// Return a copy of the transaction with every leg's quantity/instrument rewritten
  /// into the profile instrument. Used before feeding scheduled-transaction instances
  /// into the forecast accumulator so the synchronous `applyTransaction` can assume
  /// all legs share the profile instrument.
  ///
  /// - Parameter date: date passed to the conversion service. For forecast use, this
  ///   is `Date()` — the current rate — because scheduled transactions have future
  ///   dates and no exchange-rate source has future rates. Same-instrument legs are
  ///   returned untouched.
  private static func convertLegsToProfileInstrument(
    _ txn: Transaction,
    to instrument: Instrument,
    on date: Date,
    conversionService: any InstrumentConversionService
  ) async throws -> Transaction {
    guard txn.legs.contains(where: { $0.instrument.id != instrument.id }) else {
      return txn
    }
    var convertedLegs: [TransactionLeg] = []
    convertedLegs.reserveCapacity(txn.legs.count)
    for leg in txn.legs {
      if leg.instrument.id == instrument.id {
        convertedLegs.append(leg)
        continue
      }
      let convertedQty = try await conversionService.convert(
        leg.quantity, from: leg.instrument, to: instrument, on: date)
      convertedLegs.append(
        TransactionLeg(
          accountId: leg.accountId,
          instrument: instrument,
          quantity: convertedQty,
          type: leg.type,
          categoryId: leg.categoryId,
          earmarkId: leg.earmarkId
        ))
    }
    var result = txn
    result.legs = convertedLegs
    return result
  }
```

- [ ] **Step 2: Build to verify it compiles (but is unused so far)**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-helper.txt
grep -iE 'error:|warning:' .agent-tmp/build-helper.txt
```

Expected: a warning that `convertLegsToProfileInstrument` is unused (or no warning, depending on Swift's private-method handling). If a real error appears, fix it before proceeding. No commit yet.

---

## Task 3: Change `generateForecast` signature and wire conversion through

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift:1044-1094` — change `generateForecast` to `async throws`, thread `conversionService`, pre-convert each instance before accumulation.

- [ ] **Step 1: Replace the `generateForecast` implementation**

Replace the existing signature and body (lines 1044-1094) with:

```swift
  private static func generateForecast(
    scheduled: [Transaction],
    startDate: Date,
    endDate: Date,
    startingBalance: InstrumentAmount,
    startingPerEarmarkAmounts: [UUID: InstrumentAmount],
    startingInvestments: InstrumentAmount,
    investmentAccountIds: Set<UUID>,
    conversionService: any InstrumentConversionService
  ) async throws -> [DailyBalance] {
    // Extrapolate instances up to endDate
    var instances: [Transaction] = []
    for scheduledTxn in scheduled {
      instances.append(contentsOf: extrapolateScheduledTransaction(scheduledTxn, until: endDate))
    }

    // Sort by date and apply to running balances
    instances.sort { $0.date < $1.date }
    var balance = startingBalance
    var perEarmarkAmounts = startingPerEarmarkAmounts
    var investments = startingInvestments
    let instrument = startingBalance.instrument

    // Scheduled transactions live in the future; exchange-rate sources can't return
    // future rates. Use today's rate as the best available estimate for forecast
    // conversion. Captured once so every instance uses the same snapshot.
    let conversionDate = Date()

    var forecastBalances: [Date: DailyBalance] = [:]
    for instance in instances {
      let converted = try await convertLegsToProfileInstrument(
        instance, to: instrument, on: conversionDate,
        conversionService: conversionService)

      applyTransaction(
        converted,
        to: &balance,
        investments: &investments,
        perEarmarkAmounts: &perEarmarkAmounts,
        instrument: instrument,
        investmentAccountIds: investmentAccountIds,
        investmentTransfersOnly: true
      )

      let dayKey = Calendar.current.startOfDay(for: instance.date)
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
    }

    return forecastBalances.values.sorted { $0.date < $1.date }
  }
```

- [ ] **Step 2: Update the call site inside `fetchDailyBalances`** (line ~236)

Replace the existing call at lines 236-244:

```swift
      scheduledBalances = Self.generateForecast(
        scheduled: scheduledTransactions,
        startDate: lastDate,
        endDate: forecastUntil,
        startingBalance: currentBalance,
        startingPerEarmarkAmounts: perEarmarkAmounts,
        startingInvestments: currentInvestments,
        investmentAccountIds: investmentAccountIds
      )
```

with:

```swift
      scheduledBalances = try await Self.generateForecast(
        scheduled: scheduledTransactions,
        startDate: lastDate,
        endDate: forecastUntil,
        startingBalance: currentBalance,
        startingPerEarmarkAmounts: perEarmarkAmounts,
        startingInvestments: currentInvestments,
        investmentAccountIds: investmentAccountIds,
        conversionService: conversionService
      )
```

(The enclosing `fetchDailyBalances` method is already `async throws`, so no signature change is needed here. `self.conversionService` is already a stored property of the repository — see line 7 of the file.)

- [ ] **Step 3: Update the call site inside `computeDailyBalances`** (line ~616)

Replace the existing call at lines 616-624:

```swift
      forecastBalances = generateForecast(
        scheduled: scheduled,
        startDate: lastDate,
        endDate: forecastUntil,
        startingBalance: currentBalance,
        startingPerEarmarkAmounts: perEarmarkAmounts,
        startingInvestments: currentInvestments,
        investmentAccountIds: investmentAccountIds
      )
```

with:

```swift
      forecastBalances = try await generateForecast(
        scheduled: scheduled,
        startDate: lastDate,
        endDate: forecastUntil,
        startingBalance: currentBalance,
        startingPerEarmarkAmounts: perEarmarkAmounts,
        startingInvestments: currentInvestments,
        investmentAccountIds: investmentAccountIds,
        conversionService: conversionService
      )
```

(The enclosing `computeDailyBalances` is already `async throws` and already has `conversionService` in scope — see line 517.)

- [ ] **Step 4: Build and confirm zero warnings/errors**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-forecast.txt
grep -iE 'error:|warning:' .agent-tmp/build-forecast.txt
```

Expected: no errors, no warnings. Fix any that appear before proceeding.

---

## Task 4: Run the failing test and confirm it now passes

**Files:** None modified in this task — verification only.

- [ ] **Step 1: Run the full test suite**

```bash
just test 2>&1 | tee .agent-tmp/forecast-test-pass.txt
grep -iE 'failed|error:' .agent-tmp/forecast-test-pass.txt
grep -A2 'forecastConvertsForeignCurrencyScheduled' .agent-tmp/forecast-test-pass.txt
```

Expected: the new test passes. All existing tests still pass. No failures, no errors.

- [ ] **Step 2: Clean up temp files**

```bash
rm .agent-tmp/forecast-test-fail.txt .agent-tmp/build-helper.txt .agent-tmp/build-forecast.txt .agent-tmp/forecast-test-pass.txt
```

---

## Task 5: Add a same-currency regression test

A single happy-path multi-currency test is enough to prove conversion, but we also want protection against accidentally running the conversion helper when it isn't needed (e.g. future refactors that change the `guard` short-circuit).

**Files:**
- Modify: `MoolahTests/Domain/AnalysisRepositoryContractTests.swift` — add one more test next to the previous one.

- [ ] **Step 1: Write the test**

Add immediately after `forecastConvertsForeignCurrencyScheduled`:

```swift
@Test("forecast leaves profile-currency scheduled transactions unchanged")
func forecastLeavesProfileCurrencyUnchanged() async throws {
  // Rate dict intentionally empty — if the code path tried to convert AUD legs
  // it would take the 1:1 fallback, but the intent is that same-currency legs
  // skip the conversion call entirely.
  let conversion = FixedConversionService(rates: [:])
  let backend = CloudKitAnalysisTestBackend(conversionService: conversion)

  let account = Account(
    id: UUID(), name: "AUD Account", type: .bank, instrument: .defaultTestInstrument)
  _ = try await backend.accounts.create(account)

  let calendar = Calendar(identifier: .gregorian)
  let today = calendar.startOfDay(for: Date())
  let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
  let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
  let nextWeek = calendar.date(byAdding: .day, value: 7, to: today)!

  _ = try await backend.transactions.create(
    Transaction(
      date: yesterday,
      payee: "Opening",
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: .defaultTestInstrument,
          quantity: 500, type: .openingBalance)
      ]))

  _ = try await backend.transactions.create(
    Transaction(
      id: UUID(),
      date: tomorrow,
      payee: "Rent",
      recurPeriod: .once,
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: .defaultTestInstrument,
          quantity: -200, type: .expense)
      ]))

  let balances = try await backend.analysis.fetchDailyBalances(
    after: nil, forecastUntil: nextWeek)

  let forecastEntry = balances.first { $0.date == tomorrow && $0.isForecast }
  #expect(forecastEntry != nil)
  #expect(forecastEntry?.balance.quantity == 300)
}
```

- [ ] **Step 2: Run and confirm it passes**

```bash
just test 2>&1 | tee .agent-tmp/forecast-same-currency.txt
grep -iE 'failed|error:' .agent-tmp/forecast-same-currency.txt
rm .agent-tmp/forecast-same-currency.txt
```

Expected: both new tests pass.

---

## Task 6: Commit

- [ ] **Step 1: Review the diff**

```bash
git status
git diff Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift
git diff MoolahTests/Domain/AnalysisRepositoryContractTests.swift
```

- [ ] **Step 2: Commit the two files together**

```bash
git add Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift \
  MoolahTests/Domain/AnalysisRepositoryContractTests.swift
git commit -m "$(cat <<'EOF'
fix: convert foreign-currency scheduled transactions in forecast

The forecast accumulator calls InstrumentAmount.+= which crashes on
mismatched instruments. Scheduled transactions denominated in a
non-profile instrument therefore crashed the forecast graph once
per-account currencies shipped. Pre-convert each extrapolated
scheduled-transaction instance's legs to the profile instrument using
the current exchange rate (scheduled dates are in the future and no
rate source has future rates) before feeding them through the
synchronous applyTransaction accumulator.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: Confirm the commit landed**

```bash
git log -1 --stat
```

---

## Out of Scope / Related Gaps

These are real issues but **not part of this plan** — keep the change small and targeted. Track separately:

1. **Actuals path has the same crash.** `fetchDailyBalances` and `computeDailyBalances` call `applyTransaction` on real (non-forecast) transactions first, *before* `applyMultiInstrumentConversion` overwrites the daily-balance dictionary. That first pass does `balance += leg.amount` and crashes when `leg.instrument != profileInstrument`. It cannot be fixed by reusing this plan's "current rate" approach — actuals should use `txn.date` rates. Needs its own plan.
2. **Forecast conversion uses one `Date()` snapshot per `generateForecast` call.** If rates change during a long-running fetch it's a minor inconsistency. Accept for now.
3. **`FiatConversionService` throws on non-fiat instruments.** A scheduled transaction whose leg is in a stock or crypto instrument will throw from the forecast. Current behaviour pre-change was crash; new behaviour is a thrown error that propagates to the analysis store. That's strictly better; no special handling added here.
