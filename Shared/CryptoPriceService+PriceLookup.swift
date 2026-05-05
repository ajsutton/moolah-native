// Shared/CryptoPriceService+PriceLookup.swift

import Foundation

// MARK: - Discriminated price lookup

// `priceLookup(for:on:)` honours `CryptoRegistration.pricingStatus` so
// `.unpriced` / `.spam` tokens resolve to `.knownZero` without invoking
// any provider, while a `.priced` registration goes through the
// existing `price(for:mapping:on:)` path and surfaces provider failure
// via `throw` (never collapsed to `.knownZero`). Lives in its own file
// to keep `CryptoPriceService.swift` under SwiftLint's `file_length`
// threshold.

extension CryptoPriceService {
  /// Discriminated price lookup. Honours `registration.pricingStatus`:
  /// - `.priced`   → `.priced(rate)` from the existing
  ///   `price(for:mapping:on:)` path.
  /// - `.unpriced` → `.knownZero` (no provider call).
  /// - `.spam`     → `.knownZero` (no provider call).
  ///
  /// Provider failure on a `.priced` registration still throws.
  ///
  /// Per `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11: this seam is
  /// the load-bearing fix that lets aggregation sites keep "intentional
  /// zero" distinct from "rate unavailable" for any total that aggregates
  /// crypto tokens.
  func priceLookup(
    for registration: CryptoRegistration,
    on date: Date
  ) async throws -> CryptoPriceLookup {
    switch registration.pricingStatus {
    case .unpriced, .spam:
      return .knownZero
    case .priced:
      let rate = try await price(
        for: registration.instrument,
        mapping: registration.mapping,
        on: date)
      return .priced(rate)
    }
  }
}
