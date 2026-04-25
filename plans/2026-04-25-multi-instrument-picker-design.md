# Multi-Instrument Picker — Design

**Status:** Design approved 2026-04-25.
**Owners:** Adrian.
**Replaces:** `Shared/Views/CurrencyPicker.swift` and the raw `Picker` constructions in `Features/Transactions/Views/TransactionDetailView.swift`.

## 1. Goal

A single picker component that selects an `Instrument` (fiat currency, stock, or crypto token) for any of the call sites that today use `CurrencyPicker` plus the transaction-detail flows that today use a static `availableInstruments` list. The picker:

- Searches across the registered instruments visible to the profile (`InstrumentRegistryRepository.all()`) plus the ambient ISO fiat list and Yahoo-validated stock tickers.
- **Does not** show CoinGecko provider hits. Crypto tokens still enter the registry exclusively via the existing `AddTokenSheet` (chain + contract path), which defends against scam tokens that share names with established tokens.
- Auto-registers a Yahoo-validated stock on selection, so picking an unregistered stock from the search results is a single tap.
- Filters by `kinds: Set<Instrument.Kind>` at each call site. The same component renders a fiat-only experience for the eight `CurrencyPicker` sites and an all-kinds experience for `TransactionDetailView`.

User-facing copy never says "instrument" — call sites pass their own label ("Currency" or "Asset"). Swift type names keep the existing `Instrument*` nomenclature; that's a domain-internal term.

## 2. Non-goals

- Renaming the `Instrument` domain type or any of its companions (`InstrumentRegistryRepository`, `InstrumentAmount`, …).
- Changing `Profile.currencyCode: String` storage. Wire format / migration / fixture JSON / moolah-server contract all stay as they are; the picker converts at the view boundary.
- Multi-select. Every existing call site is single-select; multi-select is YAGNI.
- A dedicated stock-add UI separate from the picker. The picker *is* the stock-add UI.
- Surfacing a "recently used" or "common currencies" shortlist. Search-as-you-type is fast enough.
- A feature flag. The picker replaces existing UI directly; gating would only delay the migration and split the codebase across two pickers.

## 3. Architecture

The work splits into three phases. Each phase is independently shippable through the merge queue.

```
Domain/Repositories                        (unchanged)
  - InstrumentRegistryRepository
  - StockTickerValidator
  - CryptoSearchClient                     ← still used elsewhere, not by the picker

Shared
  - InstrumentSearchService                ← gains `providerSources` parameter (Phase 3)
  - InstrumentPickerStore       (new)      @MainActor @Observable
  - Views/InstrumentPickerSheet (new)      search field + results list
  - Views/InstrumentPickerField (new)      form-row trigger
  - Views/CurrencyPicker        (deleted in Phase 2)

Domain/Models
  - Instrument                             ← `currencySymbol` rewritten (Phase 1)
```

### 3.1 `Instrument.preferredCurrencySymbol`

`Instrument.currencySymbol` today resolves through `NumberFormatter` keyed on the **user's** locale, which makes USD render as "USD" on `en_AU` instead of "$". The new helper resolves through the currency's *own* representative locale:

```swift
extension Instrument {
  /// Symbol from the currency's primary locale, not the user's.
  /// Returns nil when no representative locale produces a distinctive
  /// symbol (the result would just echo the ISO code).
  static func preferredCurrencySymbol(for code: String) -> String? {
    symbolCache.withLock { cache in
      if let hit = cache[code] { return hit.value }
      let locale = Locale.availableIdentifiers
        .lazy
        .map(Locale.init(identifier:))
        .first { $0.currency?.identifier == code }
      let symbol = locale?.currencySymbol
      let resolved: String? = (symbol == nil || symbol == code) ? nil : symbol
      cache[code] = .init(value: resolved)
      return resolved
    }
  }

  private static let symbolCache = OSAllocatedUnfairLock<[String: SymbolCacheEntry]>(initialState: [:])
  private struct SymbolCacheEntry: Sendable { let value: String? }
}
```

`Instrument.currencySymbol` (instance) becomes a thin call-through to this helper for fiat. The lock is held for a deterministic O(1) hash lookup plus an O(n) miss-path enumeration; contention is bounded and acceptable for picker-row rendering.

This is independent of user locale, so AUD glyphs as "$" everywhere, USD glyphs as "$", GBP as "£", and the long tail (PLN, HUF) returns `nil` and falls back to the ISO code in the UI.

### 3.2 `InstrumentPickerField` (the trigger)

A form-row view, suitable inside any `Form`:

```swift
struct InstrumentPickerField: View {
  let label: LocalizedStringResource          // e.g. "Currency", "Asset"
  let kinds: Set<Instrument.Kind>
  @Binding var selection: Instrument
}
```

- Renders `LabeledContent(label) { glyph + Text(selection.id).fontWeight(.medium) + Image(systemName: "chevron.right") }`.
- `glyph` is a small (20–24 pt) rounded rectangle: the preferred currency symbol for fiat, the ticker for stock, the symbol (e.g. "ETH") for crypto, falling back to the ISO code when no distinctive glyph exists.
- Tap presents `InstrumentPickerSheet` via `.sheet(isPresented:)`.
- Owns a `@State var store: InstrumentPickerStore?` constructed lazily inside the sheet's `.task`. Reads `InstrumentSearchService` and `BackendProvider` from `@Environment`.

### 3.3 `InstrumentPickerSheet` (the search surface)

Thin view:

```swift
struct InstrumentPickerSheet: View {
  @Bindable var store: InstrumentPickerStore
  @Binding var selection: Instrument
  @Binding var isPresented: Bool
}
```

Layout, in a `NavigationStack`:

- Title: `"Choose \(label)"` (e.g. "Choose Currency", "Choose Asset"). Toolbar leading: Cancel button → dismisses without writing the binding.
- `.searchable(text: $store.query)` to drive the query state. Native search field with focus + Return handling.
- `List` body sectioned conditionally:
  - **All-kinds picker** (`kinds == Set(Instrument.Kind.allCases)`): three sections — *Registered* (registered rows of any kind), *Currencies* (ambient fiat ISO matches), *Stocks* (Yahoo-validated hits). Empty sections are omitted.
  - **Single-kind picker** (e.g. `[.fiatCurrency]`): single flat list, no section headers.
- Row format: glyph + ISO code or ticker (load-bearing) + name (secondary). For an unregistered Yahoo hit, a trailing `Text("Add")` pill so the affordance is unambiguous. The currently selected instrument shows a trailing checkmark.
- Footer hint when `kinds.contains(.cryptoToken)`: *"Add a crypto token in Settings → Crypto Tokens."* Always rendered (not just on empty results); it tells the user where the missing path lives.
- macOS: `.frame(minWidth: 400, minHeight: 480)`. iOS: presented as a sheet too (not a push) so the form's underlying `NavigationStack` isn't reused.

### 3.4 `InstrumentPickerStore`

`@MainActor @Observable`. Holds query / results / loading / error and orchestrates the multi-step select-and-register flow.

```swift
@MainActor @Observable
final class InstrumentPickerStore {
  private(set) var query: String = ""
  private(set) var results: [InstrumentSearchResult] = []
  private(set) var isLoading: Bool = false
  private(set) var error: String?

  let kinds: Set<Instrument.Kind>

  init(searchService: InstrumentSearchService,
       registry: any InstrumentRegistryRepository,
       kinds: Set<Instrument.Kind>)

  func start() async                                           // initial empty-query load
  func updateQuery(_ s: String)                                // debounced, cancellable
  func select(_ result: InstrumentSearchResult) async -> Instrument?
}
```

**Search loop.** `updateQuery` cancels the in-flight `Task<Void, Never>`, sleeps 250 ms, then calls `searchService.search(query:kinds:providerSources: .stocksOnly)`. `start()` kicks the same path with an empty query so the sheet opens populated. Failures from the service are logged and the store sets `error`; the `InstrumentSearchService` already swallows per-branch network failures and returns empty arrays per branch, so a thrown error here is an unexpected service-level fault.

**Selection.** `await store.select(result)`:

1. If `result.isRegistered` (which is also true for every fiat hit by service contract), return `result.instrument`.
2. Else (a Yahoo stock hit, `requiresResolution: false`), call `try await registry.registerStock(result.instrument)`. On success, return the instrument. On failure, set `error`, return `nil`. The sheet stays open so the user can retry or cancel.
3. By construction the store never receives an unregistered crypto hit (Phase 3's `providerSources: .stocksOnly` excludes them), so there is no `requiresResolution: true` branch to handle.

**View → store wiring.** On row tap: `Task { if let i = await store.select(result) { selection = i; isPresented = false } }`.

### 3.5 `InstrumentSearchService.search` parameter

Phase 3 adds:

```swift
enum ProviderSources: Sendable {
  case all          // current behaviour: registry + fiat + Yahoo + CoinGecko
  case stocksOnly   // registry + fiat + Yahoo
}

func search(query: String,
            kinds: Set<Instrument.Kind> = Set(Instrument.Kind.allCases),
            providerSources: ProviderSources = .all)
  async -> [InstrumentSearchResult]
```

`.all` is preserved as the default so the existing test surface and any future caller stay on the existing behaviour. The picker passes `.stocksOnly`. CoinGecko fan-out is suppressed when `providerSources == .stocksOnly` even if `kinds.contains(.cryptoToken)`.

## 4. Migration of call sites

### 4.1 `CurrencyPicker` callers (eight sites, all fiat-only)

| File | View-state today | After Phase 1 | After Phase 2 |
|------|------------------|---------------|---------------|
| `Features/Settings/MoolahProfileDetailView.swift` (×3 sub-views) | `@State currencyCode: String` | `@State currency: Instrument` | `InstrumentPickerField(label: "Currency", kinds: [.fiatCurrency], selection: $currency)` |
| `Features/Profiles/Views/ProfileFormView.swift` | `@State cloudCurrencyCode: String` | `@State cloudCurrency: Instrument` | as above |
| `Features/Profiles/Views/CreateProfileFormView.swift` | `@State currencyCode: String` | `@State currency: Instrument` | as above |
| `Features/Accounts/Views/CreateAccountView.swift` | `@State currencyCode: String` | binds directly to draft's `Instrument` field | as above |
| `Features/Accounts/Views/EditAccountView.swift` | `@State currencyCode: String` | binds directly to model `Instrument` | as above |
| `Features/Earmarks/Views/CreateEarmarkSheet.swift` | `@State currencyCode: String` | binds directly to draft `Instrument` | as above |
| `Features/Earmarks/Views/EditEarmarkSheet.swift` | `@State currencyCode: String` | binds directly to model `Instrument` | as above |

Profile sites are the only ones that need a string ↔ `Instrument` bridge (because `Profile.currencyCode` storage stays as a `String`): read `Instrument.fiat(code: profile.currencyCode)` on appear, write `currency.id` back on save. Account / earmark sites bind directly because their domain models already use `Instrument`.

### 4.2 `TransactionDetailView` migration

Today this view does **not** use `CurrencyPicker`. It uses a raw `Picker` driven by a static `availableInstruments` parameter that defaults to `CurrencyPicker.commonCurrencyCodes.map { Instrument.fiat(code: $0) }`. Phase 2:

- Removes the `availableInstruments` parameter from the public initialiser.
- Replaces the top-level currency picker with `InstrumentPickerField(label: "Asset", kinds: Set(Instrument.Kind.allCases), selection: …)` bound to the transaction-level instrument.
- Replaces `legCurrencyPicker(at:)` with the same field, bound through the existing leg-instrument-id binding.
- The `CurrencyPicker.currencyName(for:)` static helper used in row labels migrates to a free function on `Instrument` (`Instrument.localizedName(for: code)`) before `CurrencyPicker.swift` is deleted.

This is the only call site that actually exercises the picker's all-kinds path and the auto-register-on-stock-tap flow. Accounts and earmarks remain fiat-only by intentional restriction; the design memo for relaxing them later is captured in §6.

## 5. UI / UX details

### 5.1 Field (collapsed) row

`LabeledContent(label) { HStack { glyph; Text(selection.id).fontWeight(.medium); Image(systemName: "chevron.right").foregroundStyle(.tertiary) } }`. The glyph is a 24 pt rounded rect with the preferred symbol or ticker; ISO code shown in the glyph slot in a smaller font for currencies without a distinctive symbol. `.monospacedDigit()` on the visible code keeps alignment when several rows stack.

### 5.2 Sheet states

- **Loading:** `ProgressView` in the search bar trailing slot while a Yahoo lookup is in flight (debounced 250 ms after last keystroke).
- **Search failure:** red banner above the list — *"Couldn't search stocks. Tap to retry."* Registered + fiat results still render.
- **Registration failure:** banner inside the sheet — *"Couldn't add \(ticker)."* Sheet stays open so the user can retry or cancel.
- **Empty results, query non-empty:** `ContentUnavailableView` with title *"No matches"* and description *"No matching currencies, stocks, or registered tokens for '\(query)'."* (multi-kind) or the single-kind variant.
- **Submit-on-Return:** when `query` exactly matches the id of exactly one row, Return selects it. Implemented via `.onSubmit` on the search field.

### 5.3 Accessibility

- Field: `accessibilityLabel("\(label), \(selection.name)")`, `accessibilityHint("Double-tap to choose")`.
- Each row is a `Button`. Label combines the glyph alt-text + name + (when present) "Add" or "Selected": e.g. `"AUD, Australian Dollar, currency, selected"` or `"AAPL, NASDAQ, stock, add"`.
- Identifiers for UI tests: `instrumentPicker.field.<label>`, `instrumentPicker.search`, `instrumentPicker.row.<id>`. Identifier scheme follows `guides/UI_TEST_GUIDE.md`.

### 5.4 Word choice (user-facing)

| Site | `label` | Sheet title |
|------|---------|-------------|
| Profile / account / earmark | `"Currency"` | "Choose Currency" |
| `TransactionDetailView` top-level + per-leg | `"Asset"` | "Choose Asset" |

Empty / error copy uses the words "currencies, stocks, or tokens" rather than the noun "instrument".

## 6. Testing

Following `guides/TEST_GUIDE.md` and the project's TDD discipline.

### 6.1 Phase 1

- Unit test for `Instrument.preferredCurrencySymbol(for:)`. Cases: USD → "$", GBP → "£", AUD → "$", EUR → "€", PLN → `nil`. Run the same cases under `en_AU`, `en_US`, `pl_PL` host locales (using the `Locale.current` overrides established elsewhere in the suite) to confirm independence from the user's locale.
- Compile-time coverage handles the binding migration. Existing form view tests stay green.

### 6.2 Phase 2

`InstrumentPickerStoreTests`, against `TestBackend` (real `CloudKitBackend` + in-memory SwiftData):

- empty query yields registered + ambient fiat (per `kinds`)
- typed query narrows registered + fiat ISO matches
- `select` of a registered row returns its instrument without touching the registry
- `select` of a Yahoo hit calls `registerStock` and returns the new instrument
- registry failure on `select`: `error` is set, returned instrument is `nil`, sheet would stay open
- debounce: two rapid `updateQuery(_:)` calls within 250 ms produce one search (asserted via a counter on a fake `InstrumentSearchService`)
- cancellation: an in-flight search is cancelled when query changes (asserted via the fake)
- `kinds: [.fiatCurrency]` filter excludes registered crypto / stock rows

One UI test under `MoolahUITests_macOS/`: open the picker from `TransactionDetailView`, type "USD", press Return, assert the leg's currency updated to USD. Driver pattern per `guides/UI_TEST_GUIDE.md`. This is the sole UI test because everything else (debounce, error formatting, registration side effects) is reachable from the store test.

### 6.3 Phase 3

Extend `InstrumentSearchServiceTests` for `providerSources`:

- `.stocksOnly` excludes CoinGecko hits even when `kinds.contains(.cryptoToken)`.
- `.all` retains today's behaviour (existing assertions unchanged).

## 7. Rollout

Three PRs, in dependency order, each through the merge queue.

### PR-1 — Currency binding migration

Pure type-level change. `CurrencyPicker.selection` becomes `Binding<Instrument>` while still rendering the existing `.menu` style fiat picker. Each call site converts at the model boundary. `Instrument.preferredCurrencySymbol(for:)` lands here and `Instrument.currencySymbol` is rewritten to use it (because the new picker depends on the right symbol but the existing menu also benefits — and it is a strict bug fix vs the locale issue Adrian flagged).

Acceptance: all current views render the same as before. No behaviour change visible to users beyond AUD/USD now glyphing as "$" on `en_AU` (a localisation fix, not a regression).

### PR-2 — `providerSources` parameter on `InstrumentSearchService`

Adds the `ProviderSources` enum and parameter. Default remains `.all` so all existing callers (including tests) continue to fan out to CoinGecko. Extends `InstrumentSearchServiceTests` with assertions for `.stocksOnly`. No other code moves.

Lands before PR-3 so the picker has a parameter to call. PR-2 is a no-op for users.

### PR-3 — Picker + sheet + sweep

Adds `InstrumentPickerStore`, `InstrumentPickerSheet`, `InstrumentPickerField`. Picker passes `providerSources: .stocksOnly` to the service. Migrates the eight `CurrencyPicker` sites. Replaces the raw `Picker` in `TransactionDetailView` (top + per-leg). **Deletes `CurrencyPicker.swift`**. Adds a free-standing `Instrument.localizedName(for: code)` helper to replace `CurrencyPicker.currencyName(for:)`.

Acceptance: every fiat-only call site now opens a search sheet on tap; every transaction leg can pick from registered + fiat ISO + Yahoo-validated stocks; auto-register-on-stock-tap works end-to-end against `TestBackend`; no CoinGecko request fires for picker-driven searches.

## 8. Future work (explicitly out of scope)

- Lifting the fiat-only restriction on accounts and earmarks once the data model for non-fiat accounts is settled. The picker already supports it; only the call-site `kinds:` argument and the model docs need to change.
- "Recently used" pinning, fuzzy-matching, or keyboard arrow-key navigation on macOS sheets.
- A picker entry-point that opens `AddTokenSheet` directly. Today the footer hint points users to Settings → Crypto Tokens; deciding to inline that flow into the picker reopens the scam-token UX question and is a separate design.
