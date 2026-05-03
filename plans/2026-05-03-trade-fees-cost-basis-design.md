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
   prescriptive on the alternative (value-weighted).
3. **`In` / `Out` transfers — out of scope.** Transfers produce a single
   `.income` or `.expense` leg (not `.trade`) and never enter the classifier.
   Adding fee folding for them would require a different pipeline and risks
   producing surprising cost-basis events from data the user thinks of as
   transfers. Open a follow-up issue if this is ever requested.
4. **Sign handling — preserve, don't `abs()`.** Fee-leg quantities are
   conventionally negative (paid out). The classifier negates the *sum* of
   converted fee quantities to obtain a positive cost contribution. A
   positive `.expense` quantity (a refund attached to a trade) would
   correctly *reduce* the cost contribution. Not a tested case (YAGNI), but
   the math stays right rather than asymmetrically discarding sign.

## Algorithm

`TradeEventClassifier.classify(legs:on:hostCurrency:conversionService:)`
adds the following work after the existing `tradeLegs.count == 2` and
zero-quantity guards, before constructing buy/sell events:

```
1. feeLegs = legs.filter { $0.type == .expense }
2. For each fee leg, convert quantity to hostCurrency on `date` via
   conversionService. Sum into totalFeeHost.
3. feeContribution = -totalFeeHost
   // Negation: typical fee-leg quantity is negative (cost paid out);
   // negating turns it into a positive cost contribution. A positive
   // .expense leg (refund) yields a negative contribution → reduces
   // cost. Sign-preserving on purpose.
4. feePerEvent = feeContribution / Decimal(capitalIndices.count)
   // capitalIndices.count is 1 for fiat-paired trades, 2 for non-fiat
   // swaps. Per Decision 2.
5. For each capital event, after computing the existing perUnit:
     feePerUnit = feePerEvent / leg.quantity.magnitude
     Buy:  costPerUnit = perUnit + feePerUnit
     Sell: proceedsPerUnit = perUnit - feePerUnit
```

The `leg.quantity.magnitude` is the absolute value of the *capital* leg
quantity. The capital leg's sign is what classifies the event as Buy
(positive) or Sell (negative); the per-unit fee is always per-share, so
absolute value is correct here. This is consistent with the existing code
that does `abs(pairValue / leg.quantity)` on line 73.

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
> converted to `hostCurrency` on the trade date, summed, and split evenly
> across the capital events. Buy events have the per-unit fee added to
> `costPerUnit`; Sell events have it subtracted from `proceedsPerUnit`.
> Transfers (`In` / `Out`) do not enter the classifier and are unaffected.

## Tests

All in `MoolahTests/Shared/TradeEventClassifierTests.swift`. Existing
no-fee tests (`buy`, `sell`, `swap`, `nonTradeLegsIgnored`,
`zeroQuantityTradeLeg`, `fewerThanTwo`) act as the **(c) regression
suite** — none of them have a `.expense` leg, so their expectations are
unchanged.

The existing `feeIgnored` test gets repurposed (renamed and expectation
flipped) since the behaviour it asserted no longer matches policy.

| Acceptance | Test name | Fixture | Expectation |
|---|---|---|---|
| (a) AUD fee on AUD-host trade | `buyFoldsAUDFee` | Buy 100 BHP for −4 000 AUD, fee −10 AUD | `costPerUnit == 40.10` |
| (b) FX fee on AUD-host trade | `buyFoldsFXFee` | Buy 100 BHP for −4 000 AUD, fee −5 USD; rate USD→AUD = 1.5 | `costPerUnit == 40.075` |
| (c) no-fee regression | existing tests | unchanged | unchanged |
| (d) multiple fee legs | `buyFoldsMultipleFees` | Buy 100 BHP for −4 000 AUD; fees −10 AUD and −3 AUD | `costPerUnit == 40.13` |

Plus three additional tests called out by the design (not in the issue's
acceptance grid, but required for behavioural coverage):

| Test name | Fixture | Expectation |
|---|---|---|
| `sellReducesProceedsByFee` | Sell 50 BHP for +2 500 AUD, fee −10 AUD | `proceedsPerUnit == 49.80` |
| `swapSplitsFeeEvenlyAcrossEvents` | −2 ETH ↔ +0.1 BTC priced via host-currency conversion (rates ETH=3 000, BTC=60 000); fee −50 AUD | BTC `costPerUnit == 60_250` (60 000 + 25 / 0.1); ETH `proceedsPerUnit == 2_987.5` (3 000 − 25 / 2) |
| `feeInHostCurrencyIsNotConverted` | Buy 100 BHP for −4 000 AUD, fee −10 AUD; conversion service has no rate entry | `costPerUnit == 40.10` (proves the host-currency short-circuit in `FixedConversionService` is exercised) |

The existing `feeIgnored` test name and body are removed — replaced by
`buyFoldsAUDFee` above (same fixture, new expectation).

## Edge cases

- **Zero `.trade` quantity.** Already short-circuits at line 51 before any
  fee work runs. No divide-by-zero possible from fee folding.
- **No `.expense` legs.** `feeLegs` is empty → `feeContribution = 0`
  → `feePerUnit = 0` → existing per-unit values pass through unchanged.
  Verified by the `(c)` regression suite.
- **`.expense` leg with `instrument == hostCurrency`.** `FixedConversionService`
  (and the production `FullConversionService` / `FiatConversionService`)
  return `quantity` unchanged when `from.id == to.id`. No FX call wasted,
  no rate lookup needed.
- **`.expense` leg in a foreign currency the rate service can't price.**
  Errors propagate from `conversionService.convert(...)` exactly as the
  existing code already does for trade-leg conversion. No new error path.

## Out of scope

- Re-parsing or back-filling existing imported transactions. The classifier
  is pure; cost basis recomputes from the existing leg shapes the next time
  it runs.
- Changing `CapitalGainsCalculator`, `PositionsHistoryBuilder`, or
  `InvestmentStore+PositionsInput`. They consume per-unit values
  structurally.
- Folding fees into `In` / `Out` transfers (Decision 3).
- Apportioning fees by leg value rather than evenly (Decision 2).
