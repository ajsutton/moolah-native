# Earmark Currency Picker — Plan

**Date:** 2026-04-17

## Goal

Let users create earmarks in a currency other than the profile's base currency, mirroring the per-account currency picker added in `2026-04-16-account-currency-picker-design.md`. Today the earmark UI hardcodes the profile currency even though `Earmark.instrument` is already persisted per-earmark and `EarmarkStore` already converts foreign-currency positions back to `earmark.instrument` for display.

## Context

- `Earmark.instrument` and `EarmarkRecord.instrumentId` already exist and persist through CloudKit sync.
- `EarmarkStore.recomputeConvertedTotals` (`Features/Earmarks/EarmarkStore.swift:114-168`) iterates each earmark's positions, converts them to `earmark.instrument`, then converts the earmark's balance a second time into `targetInstrument` (profile currency) for the sidebar grand total. Multi-instrument positions therefore already work at the data layer — only the UI is missing.
- `CreateEarmarkSheet` / `EditEarmarkSheet` live in `Features/Earmarks/Views/EarmarkFormSheet.swift`. The create sheet takes an `instrument: Instrument` parameter and uses it directly; the edit sheet renders `earmark.instrument.id` as a read-only label.
- Call sites that present the create sheet:
  - `Features/Navigation/SidebarView.swift:213-223` — passes `earmarkStore.targetInstrument`.
  - `App/ContentView.swift:122-132` — passes `accountStore.currentTotal.instrument` (this call is also affected by the sync-total crash logged in `BUGS.md`; once that bug is fixed the site will read the profile instrument directly).
  - `Features/Earmarks/Views/EarmarksView.swift:71-81` — passes `earmarkStore.targetInstrument`.
- Remote backends don't support per-earmark currencies. Like the account picker, the earmark picker must be gated on `profile.supportsComplexTransactions` (true only for CloudKit).
- The reusable `CurrencyPicker` already exists at `Shared/Views/CurrencyPicker.swift`.

## Design

### `CreateEarmarkSheet`

- Add a `supportsComplexTransactions: Bool` parameter (default `false` to keep existing previews happy).
- Add `@State private var currencyCode: String`, initialised from the injected `instrument.id`.
- When `supportsComplexTransactions` is true, render `CurrencyPicker(selection: $currencyCode)` in the "Details" section above the savings-goal field. The savings-goal row's leading `Text(instrument.id)` becomes `Text(currencyCode)` so the symbol follows the picker.
- In `createEarmark()`, resolve `let selected = supportsComplexTransactions ? Instrument.fiat(code: currencyCode) : instrument` and use `selected` for both the goal amount and the earmark's `instrument` field.

### `EditEarmarkSheet`

- Also accept `supportsComplexTransactions: Bool`.
- Add `@State private var currencyCode: String` initialised from `earmark.instrument.id`.
- When `supportsComplexTransactions` is true, render `CurrencyPicker(selection: $currencyCode)`; otherwise keep the existing read-only label.
- In `saveChanges()`, only update `earmark.instrument` when `supportsComplexTransactions` is true. Build the new goal `InstrumentAmount` in the selected instrument so the goal, balance, and display stay aligned.
- Leave existing `positions` / `savedPositions` / `spentPositions` untouched. Because `EarmarkStore.recomputeConvertedTotals` converts every position to `earmark.instrument` on each recompute, changing the earmark's instrument simply re-reports the same underlying value in a new currency — no data migration is required (parallel to the account case).

### Call sites

- `SidebarView.swift` and `EarmarksView.swift` both already have `session.profile`; pass `supportsComplexTransactions: session.profile.supportsComplexTransactions` into `CreateEarmarkSheet`. Do the same for `EditEarmarkSheet` wherever it's presented (`EarmarksView`, `EarmarkDetailView`).
- `ContentView.swift:124` keeps its call site shape but should receive the profile instrument + `supportsComplexTransactions` after the sync-total crash bug (see `BUGS.md`) is resolved. If that fix lands first, just wire the flag through; otherwise this plan can fix the call site inline by reading `session.profile.instrument` / `session.profile.supportsComplexTransactions` directly.

## Files Changed

| File | Change |
|------|--------|
| `Features/Earmarks/Views/EarmarkFormSheet.swift` | Add picker + `supportsComplexTransactions` param to both `CreateEarmarkSheet` and `EditEarmarkSheet`; drive goal/instrument from the selected code. |
| `Features/Navigation/SidebarView.swift` | Pass `supportsComplexTransactions` into `CreateEarmarkSheet`. |
| `Features/Earmarks/Views/EarmarksView.swift` | Pass `supportsComplexTransactions` into `CreateEarmarkSheet` and `EditEarmarkSheet`. |
| `Features/Earmarks/Views/EarmarkDetailView.swift` | Pass `supportsComplexTransactions` into `EditEarmarkSheet` if it is presented from here. |
| `App/ContentView.swift` | Pass `supportsComplexTransactions` into `CreateEarmarkSheet` (and use the profile instrument instead of the sync-total instrument — aligns with the sidebar-totals crash fix). |

## Testing

Follow TDD — tests first, then code.

- **Domain round-trip (contract):** extend the earmark repository contract test with a case that creates an earmark in a non-profile currency, reloads, and asserts `instrument.id` is preserved. One test on `CloudKitBackend` + in-memory SwiftData is enough; the remote backend doesn't support this path.
- **Store:** extend `EarmarkStoreTests` to cover
  - Creating an earmark in a currency different from the profile and confirming `EarmarkStore.convertedBalance(for:)` converts positions from the underlying account currency to the earmark currency.
  - Updating an earmark's instrument on an earmark with existing positions and asserting the converted balance is re-expressed in the new currency (no crash, no data loss).
- **Sheet wiring:** no new UI tests — the picker is the same control already covered by the account currency picker work; snapshot/preview the new sheet to sanity-check layout on macOS and iOS.

## Out of Scope

- Expanding the currency list beyond the 17 shared with the account picker.
- Letting earmark budget-line items pick a different currency from the earmark (they inherit `earmark.instrument`).
- Backfilling or re-denominating historical positions — not required, since the store already converts per-position on every recompute.
- Fixing the sync-totals crash or the permanent-spinner behaviour on exchange-rate failure — tracked separately in `BUGS.md`.
