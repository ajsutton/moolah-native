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

## Crypto preferences panel alignment

**Severity:** Low (cosmetic)
**Files:** Crypto preferences tab view

The "No Tokens" empty state view is left-aligned within the grey panel. It would look better center-aligned within the panel.

## Profile remove button click target too small

**Severity:** Low (UX)
**Files:** Profile list / settings view

The minus (-) button to remove profiles has a very small click target. It may not be using the full row height for its tap area.

## Migration shows no progress during data download

**Severity:** Low (UX)
**Files:** `Features/Migration/MigrationView.swift`, `Backends/CloudKit/Migration/MigrationCoordinator.swift`

The migration UI shows a progress bar during the import phase but not during the initial data download (export from remote backend). Should show a progress indicator while downloading accounts, categories, transactions, etc. from the server.

## Migration creates duplicate records

**Severity:** Critical
**Files:** `Backends/CloudKit/Migration/MigrationCoordinator.swift`, `Shared/ProfileContainerManager.swift`

After migration, accounts and earmarks appear duplicated (4x or more). Root cause under investigation — possibly related to CloudKit zone sharing between profile containers. The `ModelConfiguration` name was defaulting to `"default"` for all profiles (fixed to use unique names), but duplicates still appear even with unique zone names.

## Export Profile disabled for remote backend profiles

**Severity:** Medium (UX)
**Files:** `Features/Export/ExportImportCommands.swift`

The "Export Profile..." menu item is disabled when a remote backend profile is open. The button's `.disabled(session == nil)` check suggests the `session` focused value is nil for remote profiles. Export should work for any profile type since it uses the same `DataExporter`.

## Migration profile naming

**Severity:** Medium (UX)
**Files:** Migration/import code

When migrating from Remote to iCloud, profile naming should be:
- Original remote profile gets "(Remote)" appended if not already present
- New iCloud profile gets "(iCloud)" appended, or "(Remote)" replaced with "(iCloud)" if present
- Examples: "Moolah" → rename to "Moolah (Remote)", create "Moolah (iCloud)". "Moolah (Remote)" → unchanged, create "Moolah (iCloud)"
- If target name already exists, append " 2", " 3", etc. to find a unique name

## Incorrect earmark totals after import

After importing a profile exported from the remote backend, the earmarked total in the analysis view is incorrect. Needs investigation to determine whether the issue is in:
- The export (earmark data not exported correctly from remote backend)
- The import (earmark records not created correctly in SwiftData)
- The analysis computation (earmark amounts accumulated differently than the remote backend)
