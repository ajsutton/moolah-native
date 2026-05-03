# Fold `.expense` fee legs into trade cost basis

**Issue:** [#558](https://github.com/ajsutton/moolah-native/issues/558)
**Date:** 2026-05-03
**Status:** approved (design)

## Summary

`TradeEventClassifier` currently emits cost-basis events from `.trade` legs only,
discarding any `.expense` (fee) leg attached to the same transaction
(`Shared/TradeEventClassifier.swift:44`). The CSV importer half of #558 has
shipped — `SelfWealthMovementsParser` already attaches brokerage as a `.expense`
fee leg on the trade transaction
(`Shared/CSVImport/SelfWealthMovementsParser.swift:164-169`) — but that fee
contributes nothing to cost basis today.

This design folds attached `.expense` legs into the per-unit `costPerUnit` for
Buy events and reduces the per-unit `proceedsPerUnit` for Sell events,
mirroring conventional capital-gains-tax treatment (brokerage and stamp duty
are part of the cost base).

## Decisions

1. **`.expense` legs on a trade transaction fold into cost basis.** Yes.
2. **Multi-event apportionment (non-fiat swaps).** Split fees evenly across
   capital events. Fiat-paired trades emit one event → 100 % to that event.
   Non-fiat swaps emit two events → 50 / 50. Predictable, deterministic,
   matches what most retail tax workflows assume; ATO guidance is not
   prescriptive on the alternative (value-weighted). Even-split also avoids
   one extra conversion call per fee leg that value-weighting would require.
3. **`In` / `Out` transfers — out of scope.** Transfers produce a single
   `.income` or `.expense` leg (not `.trade`) and never enter the classifier.
   Adding fee folding for them would require a different pipeline and risks
   producing surprising cost-basis events from data the user thinks of as
   transfers. No follow-up issue is filed; we'll add one if/when a user
   actually asks.
4. **Sign handling — preserve, don't `abs()`.** Fee-leg quantities are
   conventionally negative (paid out). The classifier negates the *sum* of
   converted fee quantities to obtain a positive cost contribution. A
   positive `.expense` quantity (a refund attached to a trade) would
   correctly *reduce* the cost contribution. Not a tested case (YAGNI), but
   the math stays right rather than asymmetrically discarding sign.
5. **Error contract — propagate (no scope creep).** A failed fee-leg FX
   conversion throws from `conversionService.convert(...)`, propagates up
   through `TradeEventClassifier.classify(...)`, and aborts the surrounding
   `CapitalGainsCalculator.computeWithConversion(...)` call. This matches
   the *existing* behaviour for trade-leg conversion failures
   (`Shared/TradeEventClassifier.swift:69-70`); no new error surface area is
   introduced. Per-transaction scoping of failures is a separate concern
   (out of scope here, applies equally to existing trade-leg conversion).

## Algorithm

`TradeEventClassifier.classify(legs:on:hostCurrency:conversionService:)`
adds the following work after the existing `tradeLegs.count == 2` and
zero-quantity guards, before constructing buy/sell events:

```
1. feeLegs = legs.filter { $0.type == .expense }

2. Sum fees in hostCurrency (Decimal, signed):
     totalFeeHost = 0
     for feeLeg in feeLegs:
       if feeLeg.instrument == hostCurrency:
         totalFeeHost += feeLeg.quantity            // fast path, no service call
       else:
         totalFeeHost += try await conversionService.convert(
             feeLeg.quantity, from: feeLeg.instrument, to: hostCurrency, on: date)

3. feeContribution = -totalFeeHost
   // Negation: fee-leg quantity is negative by convention (cost paid out);
   // negating turns it into a positive cost contribution. A positive
   // .expense leg (refund) yields a negative contribution → reduces cost.
   // Sign-preserving on purpose; never abs().

4. feePerEvent = feeContribution / Decimal(capitalIndices.count)
   // feePerEvent is a per-event total in hostCurrency (Decimal monetary
   // amount, NOT yet per-unit). It's the share of feeContribution
   // allocated to one capital event. Step 5 divides it again to get the
   // per-unit number. capitalIndices.count is 1 for fiat-paired trades,
   // 2 for non-fiat swaps. Per Decision 2.

5. For each capital event, after computing the existing perUnit:
     feePerUnit = feePerEvent / leg.quantity.magnitude
     Buy:  costPerUnit     = perUnit + feePerUnit
     Sell: proceedsPerUnit = perUnit - feePerUnit
   // The Sell formula uses subtraction so that a positive feePerUnit
   // (the normal-fee case) reduces proceeds, and a negative feePerUnit
   // (the refund case from Decision 4) increases them. The Buy formula
   // is the natural mirror — addition gives cost-up for fees, cost-down
   // for refunds. Do NOT write `perUnit + feePerUnit` for both branches.
```

The `leg.quantity.magnitude` is the absolute value of the *capital* leg
quantity. The capital leg's sign is what classifies the event as Buy
(positive) or Sell (negative); the per-unit fee is always per-share, so
absolute value is correct here. This is consistent with the existing code
that does `abs(pairValue / leg.quantity)` on line 73.

**Same-instrument fast path (step 2).** Skipping the conversion-service
call when `feeLeg.instrument == hostCurrency` avoids an unnecessary async
hop on the common case (brokerage in host currency on a host-currency
trade) and keeps the fee-leg path off the rate-resolution code entirely.
This is a behaviour the *classifier* enforces; relying on the underlying
service's identity short-circuit is not enough — it leaves the door open
for a future `InstrumentConversionService` implementation without that
optimisation, and it can't be asserted directly in a test.

## API & call-sites

No public-API change. Signature of `classify(...)` is unchanged. Downstream
consumers read `costPerUnit` and `proceedsPerUnit` structurally:

- `Shared/CapitalGainsCalculator.swift:56-72` — passes per-unit values into
  `CostBasisEngine.processBuy` / `processSell` directly.
- `Shared/PositionsHistoryBuilder.swift:225` — same shape.
- `Features/Investments/InvestmentStore+PositionsInput.swift:113` — same
  shape.

All three transparently pick up improved numbers; no edit needed.

## Doc-comment rewrite

The existing classifier doc-comment
(`Shared/TradeEventClassifier.swift:23-36`) reads "Fee legs (`.expense`) are
not part of cost basis in this iteration; that decision moves with the
`SelfWealthMovementsParser` brokerage-attach work tracked in #558." That
sentence and the issue link get replaced with:

> Attached `.expense` legs are folded into per-unit cost: each fee leg is
> converted to `hostCurrency` on the trade date (or summed directly when
> already in `hostCurrency`), summed, and split *evenly* across the
> capital events. Even split is deterministic and avoids the extra
> conversion call value-weighting would require; for the typical
> two-leg fair-value swap the result is the same to within rounding.
> Buy events have the per-unit fee added to `costPerUnit`; Sell events
> have it subtracted from `proceedsPerUnit`. Transfers (`In` / `Out`)
> do not enter the classifier and are unaffected.

## Tests

All in `MoolahTests/Shared/TradeEventClassifierTests.swift`.

**Existing `feeIgnored` test is deleted** (its assertion `costPerUnit == 40`
contradicts the new policy). It is replaced by `buyFoldsAUDFee` below
(same fixture, flipped expectation).

**Existing no-fee tests** (`buy`, `sell`, `swap`, `nonTradeLegsIgnored`,
`zeroQuantityTradeLeg`, `fewerThanTwo`) are untouched — none of them
have a `.expense` leg, so their expectations are unchanged. They serve as
the **(c) no-fee regression suite**.

**Decimal-literal discipline.** All new fixtures and assertions use exact
`Decimal` literal forms — `Decimal(40)`, `Decimal(40) + Decimal(13) /
Decimal(100)`, or `Decimal(string: "40.10")`. **Never** `Decimal(40.10)`
(that's a `Double` literal coerced through `Decimal.init(_: Double)` and
introduces float-rounding error). All expected values in the table below
are reachable exactly under `Decimal` arithmetic; the test author should
write assertions that demonstrate this.

| Acceptance | Test name | Fixture | Expectation |
|---|---|---|---|
| (a) AUD fee on AUD-host trade | `buyFoldsAUDFee` | Buy 100 BHP for −4 000 AUD, fee −10 AUD | `costPerUnit == 40 + 10/100` |
| (b) FX fee on AUD-host trade | `buyFoldsFXFee` | Buy 100 BHP for −4 000 AUD, fee −5 USD; **`DateBasedFixedConversionService`** with USD→AUD = 1.5 effective at trade date and USD→AUD = 2.0 effective at trade date + 1 day | `costPerUnit == 40 + 7.5/100` (i.e. 40.075 — only reachable if implementation passes the trade date) |
| (c) no-fee regression | existing tests | unchanged | unchanged |
| (d) multiple fee legs | `buyFoldsMultipleFees` | Buy 100 BHP for −4 000 AUD; fees −10 AUD and −3 AUD | `costPerUnit == 40 + 13/100` |

Plus four additional behavioural tests:

| Test name | Fixture | Expectation |
|---|---|---|
| `sellReducesProceedsByFee` | Sell 50 BHP for +2 500 AUD, fee −10 AUD | `proceedsPerUnit == 50 - 10/50` (i.e. 49.80) |
| `swapSplitsFeeEvenlyAcrossEvents` | −2 ETH ↔ +0.1 BTC priced via host-currency conversion (`FixedConversionService`, rates ETH=3 000, BTC=60 000); fee −50 AUD | BTC `costPerUnit == 60_000 + 25/Decimal(string: "0.1")` (i.e. 60_250); ETH `proceedsPerUnit == 3_000 - Decimal(25)/2` (i.e. 2_987.5) |
| `feeContributionsCancelToZero` | Buy 100 BHP for −4 000 AUD; fees −10 AUD and +10 AUD (a fee debit fully offset by a refund credit) | `costPerUnit == 40` (proves the sum-to-zero path produces the same result as the empty-fee-list path) |
| `hostCurrencyFeeNeedsNoConversionLookup` | Buy 100 BHP for −4 000 AUD, fee −10 AUD; conversion service is a `RecordingConversionService` test double that fails (or records a call) on every `convert(...)` invocation | `costPerUnit == 40.10` AND no call was made to `convert` for the AUD fee leg (proves the classifier's fast path, not the production service's identity short-circuit) |

`RecordingConversionService` is a small, local test double introduced for
this test — three fields max (`calls: [(from, to, on)]`, optional
`shouldFail: Bool`, returns `quantity` unchanged on hit since this test
doesn't exercise non-host-currency conversions). Lives next to
`FixedConversionService` in `MoolahTests/Support/`. If the existing
`FixedConversionService` is trivially extensible to record calls, prefer
extending it over a new type — implementer's call.

## Edge cases

- **Zero `.trade` quantity.** Already short-circuits at line 51 before any
  fee work runs. No divide-by-zero possible from fee folding.
- **No `.expense` legs.** `feeLegs` is empty → `feeContribution = 0`
  → `feePerUnit = 0` → existing per-unit values pass through unchanged.
  Verified by the (c) regression suite.
- **`.expense` legs that sum to zero.** Different code path from the
  empty-list case (the loop runs, conversions may happen, signs cancel
  in the sum). Verified by `feeContributionsCancelToZero`.
- **`.expense` leg with `instrument == hostCurrency`.** Skipped at the
  classifier level via the explicit fast path in Algorithm step 2. No
  conversion-service call. Verified by `hostCurrencyFeeNeedsNoConversionLookup`.
- **`.expense` leg in a foreign currency the rate service can't price.**
  Errors propagate from `conversionService.convert(...)` per Decision 5.
  No new error path beyond what trade-leg conversion already does today.

## Out of scope

- Re-parsing or back-filling existing imported transactions. The classifier
  is pure; cost basis recomputes from the existing leg shapes the next time
  it runs.
- Changing `CapitalGainsCalculator`, `PositionsHistoryBuilder`, or
  `InvestmentStore+PositionsInput`. They consume per-unit values
  structurally.
- Folding fees into `In` / `Out` transfers (Decision 3).
- Apportioning fees by leg value rather than evenly (Decision 2).
- Per-transaction scoping of conversion errors in `CapitalGainsCalculator`
  (Decision 5). Applies equally to existing trade-leg conversion; would be
  its own refactor.
