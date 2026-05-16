import Foundation
import OSLog

/// Resolves exchange symbols to Moolah `Instrument`s. The fiat denomination
/// is injected (not hardcoded) so the resolver is reusable for a future
/// non-AUD exchange; asset legs go through the instrument registry. `any
/// InstrumentRegistryRepository` is intentional: v1 has a single concrete
/// registry and the existential keeps construction simple.
struct ExchangeInstrumentResolver: Sendable {
  private let registry: any InstrumentRegistryRepository
  private let fiatInstrument: Instrument
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "ExchangeInstrumentResolver")

  init(registry: any InstrumentRegistryRepository, fiatInstrument: Instrument) {
    self.registry = registry
    self.fiatInstrument = fiatInstrument
  }

  /// `throws` (NOT `try?`): a registry failure (DB unavailable) must
  /// propagate so the sync fails with a transient error and retries —
  /// silently returning nil would misdiagnose a DB outage as "every
  /// instrument unknown" and permanently drop every imported transaction.
  /// `nil` means genuinely not found (engine drops that group).
  func instrument(forSymbol symbol: String?, isFiat: Bool) async throws -> Instrument? {
    if isFiat { return fiatInstrument }
    guard let symbol else { return nil }
    do {
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
