import SwiftUI

// Profile-level currency picker: fiat-only menu used by all three detail views.
// ProfileSession is not reliably in the SwiftUI environment for Settings views,
// so InstrumentPickerField is not used here.
struct ProfileCurrencyPicker: View {
  @Binding var selection: Instrument

  private static let codes: [String] = [
    "AUD", "CAD", "CHF", "CNY", "EUR", "GBP", "HKD", "INR", "JPY", "KRW",
    "MXN", "NOK", "NZD", "SEK", "SGD", "USD", "ZAR",
  ].sorted {
    Instrument.localizedName(for: $0).localizedCaseInsensitiveCompare(
      Instrument.localizedName(for: $1)) == .orderedAscending
  }

  var body: some View {
    Picker(
      "Currency",
      selection: Binding(
        get: { selection.id },
        set: { selection = Instrument.fiat(code: $0) }
      )
    ) {
      ForEach(Self.codes, id: \.self) { code in
        Text("\(code) — \(Instrument.localizedName(for: code))").tag(code)
      }
    }
    .pickerStyle(.menu)
  }
}
