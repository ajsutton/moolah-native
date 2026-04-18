# Analysis Views Currency Conversion — Design

**Date:** 2026-04-16

## Goal

Convert foreign-currency transaction legs to the profile currency in the expense breakdown and income/expense analysis computations, so totals are meaningful when accounts use different currencies.

## Context

- The net worth graph (`computeDailyBalances`) already handles multi-currency via `applyMultiInstrumentConversion`, which converts positions using date-appropriate exchange rates.
- The expense breakdown (`computeExpenseBreakdown`) and income/expense table (`computeIncomeAndExpense`) sum `leg.amount` directly without conversion. If a leg is in USD and the profile is AUD, the USD amount is added as-is, producing incorrect totals.
- `CloudKitAnalysisRepository` already has a `conversionService: any InstrumentConversionService` — it just isn't used in these two methods.
- `conversionService.convert(quantity, from:, to:, on:)` takes a date parameter, so we can convert at the transaction date's exchange rate.

## Design

### `computeExpenseBreakdown`

Currently sums `leg.amount` directly:
```swift
let current = breakdown[month]![categoryId] ?? .zero(instrument: instrument)
breakdown[month]![categoryId] = current + leg.amount
```

Change to convert the leg amount to profile currency when the instruments differ:
```swift
let amount: InstrumentAmount
if leg.instrument.id == instrument.id {
    amount = leg.amount
} else {
    let converted = try await conversionService.convert(
        leg.quantity, from: leg.instrument, to: instrument, on: txn.date)
    amount = InstrumentAmount(quantity: converted, instrument: instrument)
}
let current = breakdown[month]![categoryId] ?? .zero(instrument: instrument)
breakdown[month]![categoryId] = current + amount
```

This method becomes `async throws` (currently just `async`) since conversion can throw.

### `computeIncomeAndExpense`

Same pattern — every place that does `+= leg.amount` needs to convert first when `leg.instrument.id != instrument.id`. The affected accumulators are: `income`, `expense`, `profit`, `earmarkedIncome`, `earmarkedExpense`, `earmarkedProfit`, and the investment transfer contributions.

Extract a helper to avoid repeating the conversion check at every accumulation site:

```swift
private static func convertedAmount(
    _ leg: TransactionLeg,
    to instrument: Instrument,
    on date: Date,
    conversionService: any InstrumentConversionService
) async throws -> InstrumentAmount {
    if leg.instrument.id == instrument.id {
        return leg.amount
    }
    let converted = try await conversionService.convert(
        leg.quantity, from: leg.instrument, to: instrument, on: date)
    return InstrumentAmount(quantity: converted, instrument: instrument)
}
```

This method also becomes `async throws`.

### `fetchCategoryBalances`

Same issue — sums `leg.amount` without conversion. Apply the same `convertedAmount` helper.

### Signature changes

Both `computeExpenseBreakdown` and `computeIncomeAndExpense` gain a `conversionService` parameter. The call sites in `loadAll()` already have access to `conversionService`.

## Files Changed

| File | Change |
|------|--------|
| `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift` | Add `convertedAmount` helper; convert legs in `computeExpenseBreakdown`, `computeIncomeAndExpense`, and `fetchCategoryBalances`; thread `conversionService` parameter |

## Testing

- Add tests with a multi-currency profile (e.g. AUD profile with USD expense legs) verifying that expense breakdown and income/expense totals are in profile currency.
- Existing single-currency tests should pass unchanged (conversion is a no-op when instruments match).

## Out of Scope

- Net worth graph — already handles multi-currency.
- Forecast balances — these use `applyTransaction` which accumulates in profile instrument; foreign-currency scheduled transactions are a separate concern.
