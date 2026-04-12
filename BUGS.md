# Known Bugs

## Balance Calculations Are Inconsistent

Multiple balance values disagree with each other:

1. The sidebar account balance differs from the running balance on the latest transaction.
2. The same iCloud profile viewed on a different device shows yet another balance.
3. All of these differ from the correct balance on the original remote profile that was migrated, even though no transactions have changed since migration.

This suggests the cached balance on the account record, the running balance computed from transactions, and the balance synced via CloudKit are all being calculated or propagated differently.

## Transaction Side Panel Should Be Full-Window Width

The transaction detail side panel currently appears only within the upcoming transactions panel. It should instead be a right-hand side panel of the whole window, using the full analysis panel size.

## InstrumentAmount.formatted broken for non-fiat instruments

**Severity:** Medium
**Files:** `Domain/Models/InstrumentAmount.swift`, `Shared/InstrumentAmountView.swift`

`InstrumentAmount.formatted` and `InstrumentAmountView` both use `.currency(code: instrument.id)` for formatting. This works for fiat instruments where the ID is a currency code (e.g. "AUD", "USD"), but produces wrong output for:
- Stock instruments with IDs like `"ASX:BHP"` — renders as `ASX:BHP 150.00` instead of `150 BHP`
- Crypto instruments with IDs like `"1:native"` — renders nonsensically

Needs instrument-kind-aware formatting: fiat uses `.currency(code:)`, stocks/crypto should use a quantity + symbol format like `"150 BHP"` or `"0.5 BTC"`.

## InstrumentAmount arithmetic silently ignores instrument mismatches

**Severity:** Low (latent)
**File:** `Domain/Models/InstrumentAmount.swift`

The `+`, `-`, `+=`, `-=` operators on `InstrumentAmount` always use the left-hand operand's instrument, silently discarding the right-hand instrument. Adding `50 AUD + 10 ETH` produces `60 AUD` with no error. This could mask bugs when accidentally mixing instruments. Currently safe because `applyMultiInstrumentConversion` in `CloudKitAnalysisRepository` handles multi-instrument cases before arithmetic, but any new code that naively adds cross-instrument amounts will get wrong results silently.

Options: assert in debug builds, throw, or convert to a method that makes the instrument choice explicit.

## Domain/Services depends on Shared layer

**Severity:** Low (architectural)
**Files:** `Domain/Services/InstrumentConversionService.swift`

`FiatConversionService` and `FullConversionService` concrete types live in `Domain/Services/` but depend on `ExchangeRateService`, `StockPriceService`, and `CryptoPriceService` from `Shared/`. This inverts the intended dependency direction (Domain should not depend on Shared).

The `InstrumentConversionService` protocol is clean — only the implementations leak. Fix: move `FiatConversionService` and `FullConversionService` to `Shared/`, keeping only the protocol in `Domain/Services/`.

