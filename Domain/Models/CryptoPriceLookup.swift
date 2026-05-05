import Foundation

/// Discriminated price-lookup result. `.unpriced` and `.spam` registrations
/// resolve to `.knownZero`; provider failure for a `.priced` registration
/// continues to `throw` — distinguishable from `.knownZero` everywhere.
///
/// Per `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11: an intentional
/// zero (the user has marked the token unpriced or spam) must stay
/// distinct from a real provider failure ("rate unavailable") at every
/// aggregation surface, so we never substitute `0` for an unavailable
/// rate or surface a thrown error as zero.
enum CryptoPriceLookup: Sendable, Equatable {
  /// Real provider rate (USD-denominated for the existing
  /// `CryptoPriceService.price(for:mapping:on:)` path).
  case priced(Decimal)
  /// The source registration is `.unpriced` or `.spam`; its fiat value
  /// is intentionally zero. No provider call was made.
  case knownZero
}
