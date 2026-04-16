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

  /// Currency codes sorted by their localized display name.
  private static let sortedCodes: [String] = commonCurrencyCodes.sorted {
    currencyName(for: $0).localizedCaseInsensitiveCompare(currencyName(for: $1))
      == .orderedAscending
  }

  var body: some View {
    Picker("Currency", selection: $selection) {
      ForEach(Self.sortedCodes, id: \.self) { code in
        Text("\(code) — \(Self.currencyName(for: code))").tag(code)
      }
    }
    .pickerStyle(.menu)
  }
}

#Preview {
  @Previewable @State var selection = "AUD"
  Form {
    CurrencyPicker(selection: $selection)
  }
  .formStyle(.grouped)
}
