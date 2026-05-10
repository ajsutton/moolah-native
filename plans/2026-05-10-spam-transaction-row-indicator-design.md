# Spam Token Indicator for Transaction Rows — Design

Date: 2026-05-10

## Problem

When a crypto registration is marked spam (`CryptoRegistration.pricingStatus == .spam`), the registry hides it from token lists and `InstrumentConversionService` folds its fiat value to zero, but the underlying transactions still appear in `TransactionListView` showing the raw token symbol (e.g. `"Bought 1,000,000 SCAM"`, `"-50.23 SCAM"`). The user has no row-level signal that this is a spam-flagged token; the symbol reads identically to a legitimate one.

## Goal

In every place a transaction row currently displays a spam-flagged token's symbol or name, replace that text with a clear `⚠️ Spam` indicator. The indicator must be:

- Larger / more prominent than the row's caption metadata (date · category · earmark).
- Not overwhelming — the row keeps its layout, no extra row inserted.
- Accessible — VoiceOver reads "spam token" instead of the swapped symbol.

The label is informational only. Hiding spam transactions, deleting them, or filtering them out is out of scope.

## Scope — what counts as "involving a spam token"

Per **leg / per amount**, not row-wide. A transaction leg whose `instrument` corresponds to a `CryptoRegistration` with `pricingStatus == .spam`.

- A trade `AUD ↔ SCAM` displays the AUD side normally and replaces only the SCAM side. The user still gets to see how much real money was put in or taken out.
- A simple expense in a spam token (e.g. an unsolicited airdrop received as `.income`) replaces its single amount.
- The row's `balance` line uses the row's reference instrument; if that reference is itself spam (rare — would require viewing a wallet whose native token is spam-flagged), it follows the same swap.

## What changes in the row

`TransactionRowView` keeps its existing structure (icon, title, metadata caption, amount column, balance line). The spam swap applies to:

1. **Trade-title sentence** (the parenthesised action sentence inside the title line):
   - `"Bought 1,000,000 SCAM"` → `"Bought 1,000,000 ⚠️ Spam"`
   - `"Sold 1,000,000 SCAM"` → `"Sold 1,000,000 ⚠️ Spam"`
   - `"Swapped 100 AUD for 1,000,000 SCAM"` → `"Swapped 100 AUD for 1,000,000 ⚠️ Spam"`
   - Both legs spam → both replaced.
2. **Amount column** (`displayAmounts`): each `InstrumentAmount` whose `instrument` is in the spam set renders as `<magnitude> ⚠️ Spam` instead of `<magnitude> SCAM`. Sign is preserved unchanged (an income leg of a spam airdrop still reads positive).
3. **Balance line**: same rule applied to the `InstrumentAmount` for the row's running balance.
4. **Accessibility label**: in the comma-joined description that `accessibilityDescription` builds, every spam amount renders as `<magnitude> spam token` (lowercase, spelled out — VoiceOver reads naturally without the punctuation a glyph would introduce).

The row's plain payee/title text (top-line, outside the trade sentence) is **not** swapped. Wallet sync does not currently set the payee to the token name, so there is nothing to substitute. If a future wallet-sync change starts seeding the token name into payee, that is a separate decision.

## Visual specification

- **Symbol:** SF Symbol `exclamationmark.triangle.fill`, foreground `.red`.
- **Label text:** `"Spam"` (capitalised, English-only — the existing trade-title verbs are also English-only).
- **Color:** `.red` for both glyph and label, applied via `Text` `.foregroundStyle(.red)` so it scales with dynamic type and inherits the surrounding font.
- **Font / weight:** inherits the host context — body weight in the trade title and amount column (same as the surrounding text it replaces). The metadata caption row is *not* a host context for spam labels; nothing in that row ever needs swapping.
- **Inline layout:** glyph and word sit on the same baseline as the magnitude they accompany, separated by a regular space — no pill, no capsule background, no extra padding. Concretely:
  ```
  Text("\(magnitude) ")
    + Text(Image(systemName: "exclamationmark.triangle.fill")).foregroundStyle(.red)
    + Text(" Spam").foregroundStyle(.red)
  ```

## Architecture

### 1. Spam-instrument lookup

Add a derived view on the existing `CryptoTokenStore`:

```swift
extension CryptoTokenStore {
  /// Set of instruments whose registration carries `pricingStatus == .spam`.
  /// Drives the row-level "⚠️ Spam" replacement in `TransactionRowView`.
  var spamInstruments: Set<Instrument> {
    Set(spamRegistrations.map(\.instrument))
  }
}
```

The store is already `@Observable`, so any view that reads this set re-renders when the user flips a registration's status.

### 2. Environment plumbing

`TransactionListView` is constructed from many call sites (`StandardAccountView`, `InvestmentAccountView`, `EarmarkDetailView`, `CryptoWalletAccountView`, `ReportsView`, `UpcomingView`, `RecentlyAddedView`). Threading a `Set<Instrument>` parameter through every call site is noisy and bug-prone. Instead, expose the set via SwiftUI environment:

```swift
private struct SpamInstrumentsKey: EnvironmentKey {
  static let defaultValue: Set<Instrument> = []
}

extension EnvironmentValues {
  /// Crypto instruments currently marked `pricingStatus == .spam` for this
  /// profile. Read by `TransactionRowView` to swap the token symbol for a
  /// "⚠️ Spam" indicator. Default `[]` so previews and tests render normally
  /// without wiring a profile session.
  var spamInstruments: Set<Instrument> {
    get { self[SpamInstrumentsKey.self] }
    set { self[SpamInstrumentsKey.self] = newValue }
  }
}
```

Inject once at the profile root — wherever the existing `BackendProvider` / `ProfileSession` injection happens (`ContentView`-level scope, where the active `ProfileSession` is in hand). Pseudocode:

```swift
.environment(\.spamInstruments, session.cryptoTokenStore?.spamInstruments ?? [])
```

The injection site is the same place that already reads `session.cryptoTokenStore` for other UI; no new dependency is created.

### 3. Trade-title helper returns segments, not a String

`Transaction.tradeTitleSentence(scopeReference:)` currently returns a flat `String`. To support inline glyph-and-color substitution, replace it with a Text-returning sibling:

```swift
extension Transaction {
  /// Builds the action sentence for a `.trade` row title as a SwiftUI
  /// `Text`. Legs whose instrument is in `spamInstruments` render their
  /// magnitude followed by the inline "⚠️ Spam" indicator instead of the
  /// instrument's normal symbol.
  func tradeTitleText(
    scopeReference: Instrument,
    spamInstruments: Set<Instrument>
  ) -> Text?
}
```

The flat-String form is removed (it has a single caller — `TransactionRowView.titleText`). Unit tests that pinned the existing string output are rewritten against the segment helper.

The helper composes from a smaller per-leg primitive:

```swift
/// Renders an `InstrumentAmount`'s magnitude (always positive) for trade
/// title sentences, swapping the instrument symbol for the spam indicator
/// when the instrument is flagged.
func tradeMagnitudeText(_ leg: TransactionLeg, spamInstruments: Set<Instrument>) -> Text
```

### 4. Amount-column rendering

Introduce a thin SwiftUI helper that wraps `InstrumentAmountView`'s output and applies the spam swap when needed. It must continue to return a view compatible with the existing `WrappedHStack` and balance-line uses:

```swift
struct SpamAwareAmountView: View {
  let amount: InstrumentAmount
  let spamInstruments: Set<Instrument>
  let font: Font

  var body: some View {
    if spamInstruments.contains(amount.instrument) {
      // magnitude with sign preserved + inline ⚠️ Spam in red
    } else {
      InstrumentAmountView(amount: amount, font: font)
    }
  }
}
```

`TransactionRowView`'s `amountColumn` and balance line both switch from `InstrumentAmountView` to `SpamAwareAmountView`, reading `spamInstruments` from `@Environment`.

### 5. Accessibility

`accessibilityDescription` currently calls `displayAmounts.map(\.formatted).joined(separator: " and ")`. Replace with a helper that produces the same comma-joined sentence but substitutes `"<magnitude> spam token"` for spam-instrument amounts:

```swift
private func amountAccessibilityPhrase(
  _ amount: InstrumentAmount,
  spamInstruments: Set<Instrument>
) -> String
```

The trade-title sentence's accessibility variant follows the same rule — VoiceOver reads "Bought one million spam token" rather than reading the warning-triangle glyph aloud.

## Why these choices

- **Per-amount swap, not row-wide:** Preserving the fiat side of a `AUD ↔ SCAM` trade keeps real-money information visible. A row-wide flag would obscure the AUD magnitude that the user actually cares about.
- **Inline `Text` concatenation, not a pill:** Pills add layout complexity (capsule background, padding, vertical alignment within `firstTextBaseline` HStack) and visual weight that the user explicitly rejected. Concatenation reuses existing typography and stays at the same baseline as the magnitude.
- **EnvironmentValues over parameter threading:** seven `TransactionListView` call sites already exist; adding a parameter to each is a maintenance tax. The set is global to the profile, so an environment value matches its lifecycle. Default `[]` keeps previews and tests rendering correctly without wiring.
- **`Set<Instrument>` over a closure or store reference:** the row only needs a yes/no membership test. A set is the simplest type that captures that and remains `Sendable` / `Hashable` for use in `task(id:)` if a downstream view ever needs to invalidate on changes.
- **Removing the flat-`String` form of `tradeTitleSentence`:** keeping both flat-`String` and segmented variants invites them to drift. The single caller — `TransactionRowView.titleText` — is updated in the same change.

## Out of scope

- **Hiding spam transactions:** the existing UI keeps showing them (consistent with the broader "registry hides from pickers but transactions remain visible" model). A future feature could add a per-account toggle.
- **Analysis dashboard upcoming card:** `UpcomingTransactionsCard` uses its own `SimpleTransactionRow`, not `TransactionRowView`. If we later want consistency there, a follow-up.
- **Transaction detail / inspector view:** the inspector renders amounts via different code paths. Rolling spam treatment into the inspector is a separate change.
- **Spam payee text:** wallet sync does not seed the payee from the token name today. If that changes, a separate decision.

## Test plan

### Unit tests (`MoolahTests/Domain/`)
- `Transaction+Display`: rewrite the existing trade-title-sentence pinning tests against `tradeTitleText(scopeReference:spamInstruments:)`. New cases:
  - Spam on the bought side only — fiat side renders as the locale-formatted fiat string; spam side renders `<magnitude> ⚠️ Spam` (assert via the rendered `Text` value where possible, otherwise via a private helper that exposes segments for testing).
  - Spam on the sold side only.
  - Both legs spam.
  - No legs spam — output is identical to the prior flat-`String` form (regression guard).
- Accessibility helper: spam amount produces `"<magnitude> spam token"`; non-spam unchanged.

### View tests / previews
- `TransactionRowView` `#Preview` gains a spam-row spec: a wallet-account-style trade with a spam contract address. Verify visually via the `reviewing-ui-with-preview` skill flow that the indicator renders inline in red.

### UI test (`MoolahUITests_macOS`)
- Seed a profile with one priced AUD account and one spam-marked crypto registration; create a transaction whose leg uses that instrument. Assert the row shows the warning glyph and the string `"Spam"` (via accessibility identifier; the row already exposes `UITestIdentifiers.TransactionList.transaction(id)` which we keep). Skip if writing this requires a new seed primitive that adds disproportionate scaffolding for a label-only feature; a unit test on the helper plus the preview check is the floor.

## Implementation notes

- The `TransactionListView` `registrationsVersion` parameter and `PositionsTaskKey` already invalidate the per-row valuator when a spam flip happens. The new environment value re-renders rows automatically via `@Observable`, so no `task(id:)` change is needed for the spam-label feature itself.
- `InstrumentAmountView` is generic and reused outside transactions (positions, balances, reports). It must remain spam-agnostic; only the row-level wrapper is spam-aware.
