import Foundation

/// Discriminated conversion result. `.value` carries the successful
/// conversion; `.knownZero` indicates an intentionally-zero contribution
/// (e.g. the source instrument is an `.unpriced` or `.spam` crypto token).
/// A real failure throws — never collapses to `.knownZero`.
///
/// Required by aggregation paths that need to keep "intentional zero"
/// distinct from "rate unavailable" per
/// `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11.
enum ConversionResult: Sendable, Equatable {
  /// A converted amount in the caller-supplied target instrument.
  case value(InstrumentAmount)
  /// The source's registration resolved to `.knownZero` (the token is
  /// `.unpriced` or `.spam`); the contribution to any total is exactly
  /// zero in `targetInstrument`. The caller can fold this in as a
  /// `.zero(instrument: targetInstrument)` cleanly.
  case knownZero(targetInstrument: Instrument)
}
