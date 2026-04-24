import Foundation

/// One candidate returned by `InstrumentSearchService`. May represent an
/// already-registered instrument (pulled from `InstrumentRegistryRepository`),
/// a crypto provider hit that still needs resolution before it can be
/// persisted, a validated stock ticker, or an ambient fiat currency.
struct InstrumentSearchResult: Sendable, Identifiable {
  let instrument: Instrument
  let cryptoMapping: CryptoProviderMapping?
  let isRegistered: Bool
  let requiresResolution: Bool

  var id: String { instrument.id }
}

extension InstrumentSearchResult: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension InstrumentSearchResult: Hashable {
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
