import Foundation
import OSLog

/// Fiat denomination + the registry fallback for exchange asset legs.
/// The chain-pinned resolution (provider token metadata → discovery) is
/// orchestrated by `ExchangeSyncEngine`; this type owns only the fiat
/// instrument, a registry lookup by id, and the *fallback* used when the
/// provider gives no usable EVM metadata (e.g. non-EVM-modelled assets).
struct ExchangeInstrumentResolver: Sendable {
  private let fiat: Instrument
  private let registry: any InstrumentRegistryRepository
  private let existingLegInstrumentIds: @Sendable () async throws -> Set<String>
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "ExchangeInstrumentResolver")

  init(
    registry: any InstrumentRegistryRepository,
    fiatInstrument: Instrument,
    existingLegInstrumentIds: @escaping @Sendable () async throws -> Set<String>
  ) {
    self.registry = registry
    self.fiat = fiatInstrument
    self.existingLegInstrumentIds = existingLegInstrumentIds
  }

  /// The profile's fiat denomination. Read by `ExchangeSyncEngine`'s
  /// fiat-leg branch; intentional API surface, not raw field access.
  func fiatDenomination() -> Instrument { fiat }

  /// The registered instrument for `id`, if any (used for the explicit
  /// non-EVM native short-circuit in `ExchangeSyncEngine`).
  func registeredInstrument(id: String) async throws -> Instrument? {
    try await registry.cryptoRegistration(byId: id)?.instrument
  }

  /// Registry fallback for a crypto symbol with no usable EVM metadata.
  /// Excludes `.spam`; prefers a mapped/`.priced` registration over an
  /// `.unpriced` stub; then an instrument already used on an existing
  /// leg; then the lowest `Instrument.id` (deterministic). `nil` when
  /// every match is spam or none exist — caller drops + logs the group.
  ///
  /// Throws on registry failure (transient) so the sync retries rather
  /// than silently dropping every leg.
  func fallbackInstrument(forSymbol symbol: String) async throws -> Instrument? {
    let regs: [CryptoRegistration]
    do {
      regs = try await registry.allCryptoRegistrations()
    } catch {
      Self.logger.error(
        "Registry scan failed for '\(symbol, privacy: .public)': \(error, privacy: .public)")
      throw error
    }
    let candidates = regs.filter {
      $0.instrument.kind == .cryptoToken
        && $0.instrument.ticker?.caseInsensitiveCompare(symbol) == .orderedSame
        && $0.pricingStatus != .spam
    }
    guard !candidates.isEmpty else { return nil }

    let used = try await existingLegInstrumentIds()
    return candidates.min { lhs, rhs in
      Self.isBetterFallback(lhs, than: rhs, usedIds: used)
    }?.instrument
  }

  /// Returns `true` when `lhs` is the better registry-fallback candidate.
  /// Priced+mapped beats unpriced/unmapped (it has a visible price
  /// history); an instrument already on an existing leg beats an unused
  /// one (same coin resolves to the same registry entry across import
  /// cycles — avoids phantom duplicates); lowest id breaks ties
  /// deterministically across sync runs.
  private static func isBetterFallback(
    _ lhs: CryptoRegistration,
    than rhs: CryptoRegistration,
    usedIds: Set<String>
  ) -> Bool {
    let lhsPriced = (lhs.pricingStatus == .priced && lhs.mapping.hasProviderMapping) ? 0 : 1
    let rhsPriced = (rhs.pricingStatus == .priced && rhs.mapping.hasProviderMapping) ? 0 : 1
    if lhsPriced != rhsPriced { return lhsPriced < rhsPriced }
    let lhsUsed = usedIds.contains(lhs.instrument.id) ? 0 : 1
    let rhsUsed = usedIds.contains(rhs.instrument.id) ? 0 : 1
    if lhsUsed != rhsUsed { return lhsUsed < rhsUsed }
    return lhs.instrument.id < rhs.instrument.id
  }
}
