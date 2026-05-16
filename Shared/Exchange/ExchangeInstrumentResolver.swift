import Foundation
import OSLog

/// Resolves exchange symbols to Moolah `Instrument`s. The fiat denomination
/// is injected (not hardcoded) so the resolver is reusable for a future
/// non-AUD exchange; asset legs go through the instrument registry. `any
/// InstrumentRegistryRepository` is intentional: there is exactly one
/// concrete registry in the app; the existential avoids a generic parameter
/// that would propagate to every call site without adding type safety.
struct ExchangeInstrumentResolver: Sendable {
  private let registry: any InstrumentRegistryRepository
  private let fiatInstrument: Instrument
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "ExchangeInstrumentResolver")

  init(registry: any InstrumentRegistryRepository, fiatInstrument: Instrument) {
    self.registry = registry
    self.fiatInstrument = fiatInstrument
  }

  /// Returns the matching `Instrument`, or `nil` when the symbol is genuinely
  /// unknown to the registry (the caller treats unknown groups as
  /// unimportable and drops them).
  ///
  /// Throws on a registry failure rather than returning `nil`: a database
  /// outage must surface as a transient error so the enclosing sync retries,
  /// not as a silent "every instrument unknown" signal that would permanently
  /// drop all imported transactions.
  func instrument(forSymbol symbol: String?, isFiat: Bool) async throws -> Instrument? {
    if isFiat { return fiatInstrument }
    guard let symbol else { return nil }
    do {
      // O(n) scan of the registry: the registry has no keyed by-ticker
      // lookup and holds at most a few hundred entries; called per
      // unresolved leg during a background sync, not on a hot UI path.
      return try await registry.all().first {
        $0.kind == .cryptoToken
          && $0.ticker?.caseInsensitiveCompare(symbol) == .orderedSame
      }
    } catch {
      Self.logger.error(
        "Registry scan failed resolving '\(symbol, privacy: .public)': \(error, privacy: .public)")
      throw error
    }
  }
}
