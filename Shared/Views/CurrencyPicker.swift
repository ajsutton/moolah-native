import SwiftUI

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
