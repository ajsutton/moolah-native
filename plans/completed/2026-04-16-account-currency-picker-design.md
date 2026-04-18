# Account Currency Picker — Design

**Date:** 2026-04-16

## Goal

Allow users to select a currency when creating or editing an account, so accounts can hold a currency different from the profile's base currency.

## Context

- `Account.instrument` and `AccountRecord.instrumentId` already exist and persist correctly.
- `AccountStore` already converts foreign-currency accounts to profile currency for sidebar totals.
- `ProfileFormView` has a hardcoded 17-currency picker — this needs to be extracted into a shared component.
- Remote backends don't support per-account currencies. The picker is gated on `profile.supportsComplexTransactions` (true only for CloudKit).

## Design

### Shared `CurrencyPicker` view

Extract the currency list and picker into a reusable `CurrencyPicker` view in `Shared/Views/`:

```swift
struct CurrencyPicker: View {
  @Binding var selection: String

  static let commonCurrencyCodes: [String] = [
    "AUD", "CAD", "CHF", "CNY", "EUR", "GBP", "HKD", "INR", "JPY", "KRW",
    "MXN", "NOK", "NZD", "SEK", "SGD", "USD", "ZAR",
  ]

  static func currencyName(for code: String) -> String {
    Locale.current.localizedString(forCurrencyCode: code) ?? code
  }

  var body: some View {
    Picker("Currency", selection: $selection) {
      ForEach(Self.commonCurrencyCodes, id: \.self) { code in
        Text("\(code) — \(Self.currencyName(for: code))").tag(code)
      }
    }
  }
}
```

### CreateAccountView

- Add `@State private var currencyCode: String` initialized from the `instrument` parameter's `.id`.
- Show `CurrencyPicker(selection: $currencyCode)` when `supportsComplexTransactions` is true.
- In `submit()`, build the account instrument from the selected code: `Instrument.fiat(code: currencyCode)`.
- The view needs a `supportsComplexTransactions: Bool` parameter, passed from `SidebarView` via `session.profile.supportsComplexTransactions`.

### EditAccountView

- Add `@State private var currencyCode: String` initialized from `account.instrument.id`.
- Show `CurrencyPicker(selection: $currencyCode)` when `supportsComplexTransactions` is true.
- In `save()`, set `updated.instrument = Instrument.fiat(code: currencyCode)`.

### ProfileFormView

- Replace `commonCurrencyCodes`, `currencyName(for:)`, and the inline picker with `CurrencyPicker(selection: $cloudCurrencyCode)`.

### Call site changes

- `SidebarView` passes `supportsComplexTransactions` to `CreateAccountView`. It currently doesn't have access to `ProfileSession` — needs `@Environment(ProfileSession.self)` or the flag threaded through as a `Bool`.

## Files Changed

| File | Change |
|------|--------|
| **Create:** `Shared/Views/CurrencyPicker.swift` | Shared picker component with currency list |
| `Features/Accounts/Views/CreateAccountView.swift` | Add currency state, show picker conditionally, use selected currency |
| `Features/Accounts/Views/EditAccountView.swift` | Add currency state, show picker conditionally, save selected currency |
| `Features/Profiles/Views/ProfileFormView.swift` | Replace inline picker with `CurrencyPicker` |
| `Features/Navigation/SidebarView.swift` | Pass `supportsComplexTransactions` to `CreateAccountView` |

## Testing

- Store-level: verify `AccountStore.create` and `AccountStore.update` persist the selected instrument and it round-trips through fetch.
- No UI tests — currency picker is a standard SwiftUI `Picker`.

## Out of Scope

- Expanding the currency list beyond the current 17 (future work).
- Cross-currency transfer UI.
- Analysis views with date-appropriate rates.
