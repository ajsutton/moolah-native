import SwiftUI

struct CurrencyPicker: View {
  @Binding var selection: Instrument

  static let commonCurrencyCodes: [String] = [
    "AUD", "CAD", "CHF", "CNY", "EUR", "GBP", "HKD", "INR", "JPY", "KRW",
    "MXN", "NOK", "NZD", "SEK", "SGD", "USD", "ZAR",
  ]

  static func currencyName(for code: String) -> String {
    Locale.current.localizedString(forCurrencyCode: code) ?? code
  }

  private static let sortedCodes: [String] = commonCurrencyCodes.sorted {
    currencyName(for: $0).localizedCaseInsensitiveCompare(currencyName(for: $1))
      == .orderedAscending
  }

  var body: some View {
    Picker(
      "Currency",
      selection: Binding(
        get: { selection.id },
        set: { selection = Instrument.fiat(code: $0) }
      )
    ) {
      ForEach(Self.sortedCodes, id: \.self) { code in
        Text("\(code) — \(Self.currencyName(for: code))").tag(code)
      }
    }
    .pickerStyle(.menu)
  }
}

#Preview {
  @Previewable @State var selection: Instrument = .AUD
  Form {
    CurrencyPicker(selection: $selection)
  }
  .formStyle(.grouped)
}
