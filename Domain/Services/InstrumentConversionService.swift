import Foundation

/// Converts quantities between instruments. Phase 2: fiat-to-fiat only.
/// Phase 3+ will add stock and crypto conversion paths.
protocol InstrumentConversionService: Sendable {
  /// Convert a raw quantity from one instrument to another on a given date.
  func convert(
    _ quantity: Decimal,
    from: Instrument,
    to: Instrument,
    on date: Date
  ) async throws -> Decimal

  /// Convenience: convert an InstrumentAmount to a different instrument.
  func convertAmount(
    _ amount: InstrumentAmount,
    to instrument: Instrument,
    on date: Date
  ) async throws -> InstrumentAmount

  /// Discriminated convert. Returns `.knownZero(targetInstrument: to)`
  /// when the source instrument's provider mapping resolves to a
  /// `.knownZero` price (e.g. `.unpriced` or `.spam` crypto token).
  /// Returns `.value` on real conversions. Throws on provider failure —
  /// never collapses failure to `.knownZero`.
  ///
  /// Required for any aggregation path that needs to keep "intentional
  /// zero" distinct from "rate unavailable" per
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11.
  func convertResult(
    _ amount: InstrumentAmount,
    to instrument: Instrument,
    on date: Date
  ) async throws -> ConversionResult

  /// Invalidate any cached state held about `instrument` (and any rate
  /// derived from it). Called when a user mutation changes
  /// `pricingStatus` for a crypto registration so the next aggregation
  /// reads fresh data. No-op for fiat instruments and for
  /// implementations that don't cache.
  func invalidateCache(for instrument: Instrument) async
}

enum ConversionError: Error, Equatable {
  case unsupportedInstrumentKind
  case unsupportedConversion(from: String, to: String)
  case noCryptoPriceService
  case noProviderMapping(instrumentId: String)
}
