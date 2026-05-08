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

  /// Reactive "rate-tick" stream. Emits one `Void` value when the
  /// service is subscribed (initial tick) and then re-emits whenever
  /// any of the live price-cache tables changes — `exchange_rate`
  /// (FX), `stock_price`, or `crypto_price`. Stores that compute
  /// converted balances subscribe and recompute on each tick so a
  /// remote sync write that updates a rate triggers UI refresh
  /// without a manual reload. The stream is non-throwing: errors
  /// surface out-of-band on `observeErrors()`.
  ///
  /// The conformance must use the explicit-region form
  /// `ValueObservation.tracking(regions:fetch:)` because the cache
  /// tables may be empty on a fresh-install profile. The inference
  /// form (`tracking { db in }` reading rows) only registers a table
  /// after the first row is read — fresh-install profiles would miss
  /// the first sync write to each cache table. See
  /// `guides/DATABASE_CODE_GUIDE.md` §2 convention 1.
  ///
  /// **No `removeDuplicates()`.** `Void == Void` would suppress every
  /// emission. The retry helper used elsewhere unconditionally chains
  /// `removeDuplicates()`, so this stream wires its own retry path
  /// (via the underlying `makeRetryingAsyncStream` driver, which has
  /// no `Equatable` requirement).
  func observeRates() -> AsyncStream<Void>

  /// Companion error stream for `observeRates()`. A healthy service
  /// stays quiet here for its lifetime; a programmer-bug or
  /// non-recoverable I/O error from the underlying observation is
  /// yielded once and then the stream completes. Mirrors the
  /// `AccountRepository.observeErrors()` contract.
  func observeErrors() -> AsyncStream<any Error>
}

enum ConversionError: Error, Equatable {
  case unsupportedInstrumentKind
  case unsupportedConversion(from: String, to: String)
  case noCryptoPriceService
  case noProviderMapping(instrumentId: String)
}
