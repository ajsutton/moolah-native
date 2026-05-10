import SwiftUI

/// The set of crypto instruments whose `CryptoRegistration.pricingStatus`
/// is currently `.spam` for the active profile. `TransactionRowView` reads
/// this to swap a leg's instrument symbol for an inline "⚠️ Spam" marker
/// in the row's trade-title sentence and amount column.
///
/// The default value is the empty set so previews and tests render without
/// any wiring; only screens that have access to the active `ProfileSession`
/// (currently `ContentView`) inject the live value.
private struct SpamInstrumentsKey: EnvironmentKey {
  static let defaultValue: Set<Instrument> = []
}

extension EnvironmentValues {
  var spamInstruments: Set<Instrument> {
    get { self[SpamInstrumentsKey.self] }
    set { self[SpamInstrumentsKey.self] = newValue }
  }
}
