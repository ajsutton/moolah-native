// App/SharedInstrumentScope.swift

import Foundation
import Observation

/// App-level holder for the shared instrument registry and the
/// price-cache / search / discovery services that go with it. One
/// instance per app; injected into every `ProfileSession` so all
/// profiles see the same registry data and share price-cache rows.
///
/// This stage stands the holder up as a passive container: the app
/// boot path (a later stage) constructs the dependencies and hands
/// them in. The holder does not currently wire any sync hooks,
/// observation closures, or remote-change fan-out — those land in
/// later stages once the consumers exist.
///
/// **Isolation: `@MainActor`.** UI consumers (Settings, sidebar
/// widgets, sync stores) are all `@MainActor`-isolated; the actor
/// types this class owns (`CryptoPriceService`, `StockPriceService`,
/// `ExchangeRateService`, `CryptoTokenDiscoveryService`) are accessed
/// via `await` and are themselves `Sendable`. `@MainActor`
/// confinement avoids the `@unchecked Sendable` carve-out that would
/// otherwise be required.
///
/// **`@Observable`** is applied even though every property is `let`
/// today — the convention for `@MainActor` holders that participate
/// in SwiftUI dependency injection is to be observable, so adding a
/// mutable counter or `Bool` flag later triggers view updates without
/// a separate refactor.
@MainActor
@Observable
final class SharedInstrumentScope {
  /// Authoritative source of instrument identity, shared across every
  /// profile session on the same iCloud account. All registry
  /// mutations flow through this single instance so spam decisions,
  /// discovered-token resolutions, and provider mappings propagate
  /// to every profile without per-session re-load.
  let instrumentRegistry: any InstrumentRegistryRepository

  /// Single price-cache service per app — the shared backing DB
  /// dedupes API calls that two profiles holding the same crypto
  /// token would otherwise issue independently.
  let cryptoPriceService: CryptoPriceService

  /// Single stock-price service per app, sharing the cache for the
  /// same reason as `cryptoPriceService`.
  let stockPriceService: StockPriceService

  /// Single FX-rate service per app — exchange rates are user-scoped,
  /// not profile-scoped.
  let exchangeRateService: ExchangeRateService

  /// Search service composing the registry, CoinGecko catalog, and
  /// resolution client. Shared so search results match the registry
  /// state visible to every profile.
  let instrumentSearchService: InstrumentSearchService

  /// Per-(chain, contractAddress) discovery actor. Sharing the actor
  /// across sessions coalesces concurrent resolves of the same key
  /// from different profiles into one network round-trip.
  let cryptoTokenDiscovery: CryptoTokenDiscoveryService

  init(
    instrumentRegistry: any InstrumentRegistryRepository,
    cryptoPriceService: CryptoPriceService,
    stockPriceService: StockPriceService,
    exchangeRateService: ExchangeRateService,
    instrumentSearchService: InstrumentSearchService,
    cryptoTokenDiscovery: CryptoTokenDiscoveryService
  ) {
    self.instrumentRegistry = instrumentRegistry
    self.cryptoPriceService = cryptoPriceService
    self.stockPriceService = stockPriceService
    self.exchangeRateService = exchangeRateService
    self.instrumentSearchService = instrumentSearchService
    self.cryptoTokenDiscovery = cryptoTokenDiscovery
  }
}
