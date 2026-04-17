# Instrument Conversion Guide

**Version:** 1.0
**Platform targets:** macOS 26+ (primary), iOS 26+ (secondary)

---

## 1. Architecture Overview

Moolah is multi-instrument by construction: accounts, legs, earmarks, and positions are all expressed in an `Instrument` (fiat currency, stock, or crypto token), and a profile has a single `profileInstrument` that user-facing totals roll up into.

**Key types:**

- `Domain/Models/InstrumentAmount.swift` — `InstrumentAmount { quantity: Decimal, instrument: Instrument }`. All arithmetic (`+`, `-`, `+=`, `-=`) has a `precondition` that the two operands share an instrument and **traps** on mismatch. `Comparable` (`<`) compares raw `quantity` only and does NOT guard instrument equality.
- `Domain/Services/InstrumentConversionService.swift` — the only sanctioned conversion API:
  - `convert(_ quantity: Decimal, from: Instrument, to: Instrument, on: Date) async throws -> Decimal`
  - `convertAmount(_ amount: InstrumentAmount, to: Instrument, on: Date) async throws -> InstrumentAmount`
- `Shared/PositionBook.swift` — the canonical aggregation primitive. Per-instrument positions are kept as raw `Decimal` keyed by `Instrument` and only converted at read time in `dailyBalance(on:…)`.
- Production conversion implementations: `FiatConversionService` (Frankfurter API), `FullConversionService` (fiat + stock + crypto).
- Test doubles: `FixedConversionService` (ignores date), `DateBasedFixedConversionService` (honours date).

**Hard constraint:** Frankfurter does NOT return future exchange rates. For anything at or after today, the "latest available" rate — requested with `Date()` — is the documented best estimate.

**Key Sources:**
- `plans/ROADMAP.md` Phase 6 — multi-currency intent.
- `plans/2026-04-17-forecast-currency-conversion-plan.md` — forecast date rule and the crash this codifies.
- `plans/completed/2026-04-12-multi-instrument-design.md` — foundational design.

---

## 2. Core Principles

1. **Arithmetic crashes; conversion throws.** A mismatched `+`/`-` traps the process. A failed conversion throws and is recoverable. Convert *before* summing across instruments.
2. **Aggregate per-instrument, then convert.** Keep per-instrument positions as raw `Decimal` keyed by `Instrument`. Convert to a target instrument at the edge (read time), never in the middle of accumulation.
3. **The conversion date is a semantic choice.** It must reflect *when the value is denominated*, not when the code runs. Historic = snapshot date; current/future = `Date()`.
4. **Single-instrument fast path.** When a position's instrument equals the target, skip the conversion service entirely and add the raw quantity. Do not route same-instrument data through an async call.

---

## 3. Rules

### Rule 1: Never add `InstrumentAmount`s that may differ in instrument

`InstrumentAmount.+/-/+=/-=` `precondition` both sides share an instrument. A mismatch is a crash, not an error. If inputs can come from different instruments, convert first.

```swift
// WRONG: legs may be in different instruments on a multi-currency profile
let total = transaction.legs
  .map(\.amount)
  .reduce(.zero(instrument: profile.instrument)) { $0 + $1 }  // traps

// CORRECT: pre-convert each leg to the target instrument
var convertedLegs: [InstrumentAmount] = []
for leg in transaction.legs {
  if leg.instrument == profile.instrument {
    convertedLegs.append(leg.amount)
  } else {
    convertedLegs.append(
      try await conversionService.convertAmount(
        leg.amount, to: profile.instrument, on: transaction.date))
  }
}
let total = convertedLegs.reduce(.zero(instrument: profile.instrument)) { $0 + $1 }
```

### Rule 2: Reduce seeds must match every element

`reduce(InstrumentAmount.zero(instrument: X)) { $0 + $1 }` is only correct when *every* element of the sequence is in `X`. Reduce over a collection produced by an explicit conversion step, not over raw domain data.

### Rule 3: `max`, `min`, and `<` across instruments are nonsense

`InstrumentAmount: Comparable` compares raw `quantity`. It does NOT guarantee the instruments match, and it does NOT trap. 10 USD < 1 BHP.AX compares `10 < 1` and returns `false`. Only compare amounts that are provably in the same instrument. Convert first if needed.

### Rule 4: Clamp after conversion, not before

Per-earmark sums are clamped to `>= 0` *after* conversion in `PositionBook.dailyBalance`. Applying `max(…, .zero(instrument: X))` to a running sum whose instrument may disagree with `X` is both a crash risk and semantically wrong.

### Rule 5: Historic data uses the snapshot date

Any read whose semantics are "as of this date" must convert on that date. This includes:

- Daily balances (`fetchDailyBalances`, `computeDailyBalances` historic entries).
- Transaction list display amounts (`Transaction.buildWithBalance` uses `transaction.date`).
- Expense breakdowns and income/expense totals (per-transaction conversion).
- Historical reports, tax summaries, capital-gains calculations, and any chart whose x-axis is time.

```swift
// CORRECT: convert each leg at its transaction's date
let converted = try await conversionService.convertAmount(
  leg.amount, to: targetInstrument, on: transaction.date)
```

### Rule 6: Current-value reads use `Date()`

Reads whose semantics are "what is this worth right now" must convert on today:

- Sidebar totals, net worth, available funds.
- `InvestmentStore.valuatePositions` (current valuation).
- `AccountStore` rollups used by the sidebar and account detail.
- "Current" earmark availability shown to the user.

### Rule 7: Forecast and scheduled use `Date()`, not the future date

Frankfurter has no future rates. Converting on a scheduled transaction's future `date` will either fail or silently return the wrong value. Convert extrapolated scheduled instances on `Date()` before they enter the forecast accumulator.

```swift
// WRONG: future date, no rate exists
let converted = try await conversionService.convertAmount(
  leg.amount, to: profile.instrument, on: scheduledInstance.date)

// CORRECT: today's rate is the documented best estimate
let converted = try await conversionService.convertAmount(
  leg.amount, to: profile.instrument, on: Date())
```

See `plans/2026-04-17-forecast-currency-conversion-plan.md` for the full rationale.

### Rule 8: Single-instrument fast path

If `instrument == target`, skip the conversion service and add the raw quantity directly. This keeps single-currency profiles off the network/cache path.

```swift
for (instrument, quantity) in positions {
  if instrument == target {
    total += quantity                                          // fast path
  } else {
    total += try await service.convert(quantity, from: instrument, to: target, on: date)
  }
}
```

### Rule 9: Use the semantic observation date, not wall-clock metadata

Use `transaction.date`, `dailyBalance.date`, `snapshot.date`, or the explicit parameter the function advertises. Do NOT use `createdAt` / `updatedAt` / record metadata timestamps — those reflect *when the user wrote the data*, not *what the data is denominated on*.

### Rule 10: Keep `startOfDay` consistent

The date used to key a balance and the date supplied to the conversion service must both be normalized the same way (usually `Calendar(identifier: .gregorian).startOfDay(for:)`). Mismatches can cross timezone boundaries and return yesterday's rate for today's value.

### Rule 11: Degrade gracefully; never silently exclude failed conversions

Conversion can fail in production — no network, no cached fallback, unsupported pair, missing provider mapping. The system must degrade as gracefully as it can, but it **must never present an incorrect number as if it were correct**.

**Allowed degradations:**
- Mark the affected total as *unavailable* (e.g. show "—", a retry affordance, or an explicit error state) for whatever scope is compromised.
- Show the convertible portion alongside an explicit indicator of what could not be converted — e.g. "A$1,234 + 2 positions unavailable". The user must be able to see that the number is partial.
- Render the unconverted `InstrumentAmount` in its native instrument and annotate it, so at least the raw value is visible.
- Keep independently-convertible sections (other accounts, other earmarks, other report rows) rendering normally — a single failing position should not blank the whole view.
- Log the failure (`os.Logger`) and surface a user-visible message so the problem is discoverable and retryable.

**Not allowed:**
- Silently summing only the convertible positions and displaying the result as a complete total.
- Replacing a failed conversion with `0` (or `.zero(instrument:)`) and folding it into the sum.
- `try?`-swallowing a conversion error, producing no log, no error state, and no user indication.
- Aborting the whole aggregation on the first failure when the remaining positions are still independently computable (the pattern behind the "sidebar spinner forever" class of bug).
- Caching/persisting a partial or fallback total as the authoritative value for the next launch, so the user never sees the real number even after the network recovers.

**Structural guidance:** Catch conversion errors inside the per-position (or per-entity) loop, not around the whole aggregation. Accumulate a list of "failed" identifiers alongside the running total so the view can render both the convertible sum and an explicit indicator. If the total is meaningless without the failed positions (e.g. net worth when a major account can't be valued), mark the total as unavailable rather than presenting a misleading partial.

---

## 4. Canonical Patterns

### Per-instrument accumulation, then convert at read time

`PositionBook` keeps `[UUID: [Instrument: Decimal]]` and converts in `dailyBalance(...)`. New aggregation code should adopt the same shape rather than accumulating `InstrumentAmount` across mixed instruments.

### Pre-convert into a typed carrier

`ConvertedTransactionLeg { leg: TransactionLeg, convertedAmount: InstrumentAmount }` — the type itself carries the guarantee that `convertedAmount.instrument` equals the target. Reducing over `[ConvertedTransactionLeg]` is safe by construction.

### Conversion-service seam

Every call site that needs a rate goes through `InstrumentConversionService`. This keeps the date decision and the fiat/stock/crypto dispatch in one place. Do not call `ExchangeRateService`, `CryptoPriceService`, or `StockPriceService` directly from a feature-level store or view.

### Single-instrument fast path

See Rule 8. Applies to both `convert(_:from:to:on:)` and `convertAmount(_:to:on:)`.

---

## 5. Anti-Patterns

| Anti-Pattern | Why It's Bad | Do This Instead |
|--------------|--------------|-----------------|
| Summing `TransactionLeg.amount` directly across legs | Legs are per-instrument; multi-currency profiles crash | Convert each leg, then sum (Rule 1) |
| `reduce(.zero(instrument: X)) { $0 + $1 }` over raw domain data | Seed instrument doesn't match elements in multi-currency data | Reduce over a pre-converted collection (Rule 2) |
| `max(a, b)` / `a < b` on `InstrumentAmount`s of unknown instrument | Compares raw quantity silently; 10 USD < 1 BHP.AX is false | Convert to a common instrument first (Rule 3) |
| Clamping `max(sum, .zero(instrument: X))` before conversion | Traps when `sum.instrument != X` | Clamp after conversion (Rule 4) |
| Historic reports calling `.convert(..., on: Date())` | Report values drift from the authoritative historic rate | Pass the snapshot/transaction date (Rule 5) |
| Sidebar/net-worth calling `.convert(..., on: someHistoricDate)` | Shows a stale rate as "now" | Pass `Date()` (Rule 6) |
| Forecast converting on the scheduled future date | Frankfurter has no future rates; throws or returns wrong value | Convert on `Date()` (Rule 7) |
| Routing same-instrument data through the conversion service | Unnecessary async hop and network/cache traffic | Fast-path when `instrument == target` (Rule 8) |
| Using `createdAt` / `updatedAt` as conversion date | Metadata timestamp is not the semantic observation date | Use `transaction.date` / `dailyBalance.date` (Rule 9) |
| Keying balances and converting rates with un-normalized `Date` | Timezone drift — "today's rate" for yesterday's balance | Normalize both with `startOfDay` (Rule 10) |
| Test coverage only via `FixedConversionService` (date-ignoring) | Cannot detect wrong-date regressions | Use `DateBasedFixedConversionService` for date-sensitive tests |
| Constructing `InstrumentAmount(quantity:, instrument:)` with an implicit running-total instrument | Assumption breaks when inputs differ | Keep positions as `[Instrument: Decimal]` until convert time |
| Calling `ExchangeRateService` / `CryptoPriceService` / `StockPriceService` directly from a store or view | Bypasses the `InstrumentConversionService` seam and the fast path | Always go through `InstrumentConversionService` |
| Summing only the convertible positions and displaying as a complete total | Shows an incorrect number with no indication it's partial | Degrade per Rule 11: partial + indicator, or mark total unavailable |
| Replacing a failed conversion with `0` / `.zero(instrument:)` in the running sum | Same problem — a wrong total rendered as authoritative | Exclude *and* surface; never silently substitute zero (Rule 11) |
| Wrapping the whole aggregation in one `do { ... } catch { total = nil }` | One bad position blanks the entire view, e.g. sidebar spinner forever | Catch per-position inside the loop; keep the rest rendering (Rule 11) |
| `try?` on a conversion without logging or surfacing an error | Silent failure, invisible in production | Log via `os.Logger` and set a user-visible error/indicator (Rule 11) |

---

## 6. Review Checklist

### For every change that touches monetary aggregation

- [ ] Every `InstrumentAmount.+/-/+=/-=` operates on operands provably in the same instrument.
- [ ] Every `reduce(.zero(instrument: X))` reduces over a collection whose elements are provably in `X` (ideally a freshly pre-converted array).
- [ ] Every `max` / `min` / `<` on `InstrumentAmount`s compares values provably in the same instrument.
- [ ] Clamps, ceilings, and floors are applied *after* conversion to a known target instrument.
- [ ] Single-instrument fast path is present where the accumulated data could be same-instrument in a common user setup.

### For every change that touches conversion dates

- [ ] Historic reads (daily balances before today, transaction lists, expense/income breakdowns, tax summaries) convert on the snapshot/transaction date.
- [ ] Current-value reads (sidebar, net worth, available funds, investment valuations, account detail) convert on `Date()`.
- [ ] Forecast/scheduled paths convert on `Date()`, never on a scheduled transaction's future date.
- [ ] Date is the semantic observation date (`transaction.date`, `dailyBalance.date`), not wall-clock metadata (`createdAt`, `updatedAt`).
- [ ] Date used to key a bucket matches the date handed to the conversion service (same `startOfDay` normalization).

### For every new conversion call site

- [ ] Goes through `InstrumentConversionService`, not a lower-level price/rate service.
- [ ] Single-instrument fast path present.
- [ ] Test coverage uses `DateBasedFixedConversionService` if date correctness matters.
- [ ] Failure path — a throwing conversion — is surfaced to the user or logged, not `try?`-swallowed.

### For every aggregation that can partially fail

- [ ] Conversion errors are caught *inside* the per-position / per-entity loop, not around the whole aggregation.
- [ ] Independently-convertible positions still render when one position fails.
- [ ] Partial totals are displayed with an explicit indicator (e.g. "+ N unavailable"), or the total is marked unavailable — never silently summed as if complete.
- [ ] Failed conversions are never substituted with `0` in the running sum.
- [ ] Failures are logged via `os.Logger` and surfaced to the user, with a path to retry once the network / rate source recovers.
- [ ] Partial / fallback totals are not cached as authoritative values that would hide recovery.

---

## Version History

- **1.0** (2026-04-17): Initial guide. Consolidates instrument-safe-arithmetic and conversion-date rules previously spread across `plans/ROADMAP.md`, `plans/2026-04-17-forecast-currency-conversion-plan.md`, and the `PositionBook` / `InstrumentAmount` source files. Adds Rule 11 (graceful degradation without silently excluding failed conversions) to codify the "sidebar blanks forever" class of bug and preclude silent partial totals.
