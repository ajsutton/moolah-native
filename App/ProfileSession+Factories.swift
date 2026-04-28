// swiftlint:disable multiline_arguments

import CloudKit
import Foundation
import GRDB
import OSLog
import SwiftData

extension ProfileSession {
  // MARK: - Market Data Services

  /// Bundle of the external market-data services a profile session depends
  /// on: fiat exchange rates, stock prices, and crypto prices. Returned
  /// from `makeMarketDataServices` so `init` can assign each field in one
  /// step.
  struct MarketDataServices {
    let exchangeRate: ExchangeRateService
    let stockPrice: StockPriceService
    let cryptoPrice: CryptoPriceService
    let yahooPriceFetcher: any YahooFinancePriceFetcher
    let coinGeckoApiKey: String?
  }

  /// Builds the fiat/stock/crypto market-data services used throughout the
  /// profile session. Standalone helper so `ProfileSession.init` can build
  /// and assign the trio in one step. Each rate service persists to the
  /// supplied per-profile `database`.
  static func makeMarketDataServices(database: any DatabaseWriter) -> MarketDataServices {
    let yahooClient = YahooFinanceClient()
    let apiKeyStore = KeychainStore(
      service: "com.moolah.api-keys", account: "coingecko", synchronizable: true
    )
    let coinGeckoApiKey = try? apiKeyStore.restoreString()
    return MarketDataServices(
      exchangeRate: ExchangeRateService(client: FrankfurterClient(), database: database),
      stockPrice: StockPriceService(client: yahooClient, database: database),
      cryptoPrice: Self.makeCryptoPriceService(
        coinGeckoApiKey: coinGeckoApiKey, database: database),
      yahooPriceFetcher: yahooClient,
      coinGeckoApiKey: coinGeckoApiKey
    )
  }

  /// Builds the crypto-price service with its configured clients
  /// (CoinGecko when an API key is present in the keychain, plus
  /// CryptoCompare and Binance as fallbacks) and the token resolver.
  static func makeCryptoPriceService(
    coinGeckoApiKey: String?,
    database: any DatabaseWriter
  ) -> CryptoPriceService {
    let cryptoCompareClient = CryptoCompareClient()
    let binanceClient = BinanceClient { date in
      let usdtMapping = CryptoProviderMapping(
        instrumentId: "1:0xdac17f958d2ee523a2206206994597c13d831ec7",
        coingeckoId: "tether", cryptocompareSymbol: "USDT", binanceSymbol: nil
      )
      do {
        return try await cryptoCompareClient.dailyPrice(for: usdtMapping, on: date)
      } catch {
        return Decimal(1)
      }
    }

    var priceClients: [CryptoPriceClient] = []
    if let coinGeckoApiKey, !coinGeckoApiKey.isEmpty {
      priceClients.append(CoinGeckoClient(apiKey: coinGeckoApiKey))
    }
    priceClients.append(cryptoCompareClient)
    priceClients.append(binanceClient)

    return CryptoPriceService(
      clients: priceClients,
      database: database,
      resolutionClient: CompositeTokenResolutionClient(coinGeckoApiKey: coinGeckoApiKey)
    )
  }

  // MARK: - Backend

  /// Builds the CloudKit `BackendProvider` for the profile.
  static func makeBackend(
    profile: Profile,
    containerManager: ProfileContainerManager?,
    syncCoordinator: SyncCoordinator? = nil,
    services: MarketDataServices,
    database: any DatabaseWriter
  ) -> BackendProvider {
    guard let containerManager else {
      fatalError("ProfileContainerManager is required for CloudKit profiles")
    }
    return makeCloudKitBackend(
      profile: profile,
      containerManager: containerManager,
      syncCoordinator: syncCoordinator,
      marketData: CloudKitMarketDataServices(
        exchangeRates: services.exchangeRate,
        stockPrices: services.stockPrice,
        cryptoPrices: services.cryptoPrice))
  }

  // MARK: - Registry Wiring

  /// Bundle of the optional instrument-registry pieces: the registry,
  /// crypto token store, search service, CoinGecko catalog, and token
  /// resolution client. Populated for CloudKit profiles; nil fields indicate
  /// a degraded state (e.g. catalog init failure).
  ///
  /// `catalogRefreshTask` carries the once-per-session
  /// `refreshIfStale()` background task so `ProfileSession` can store and
  /// cancel it on teardown. `nil` when catalog construction failed.
  struct RegistryWiring {
    let registry: (any InstrumentRegistryRepository)?
    let cryptoTokenStore: CryptoTokenStore?
    let searchService: InstrumentSearchService?
    let coinGeckoCatalog: (any CoinGeckoCatalog)?
    let tokenResolutionClient: (any TokenResolutionClient)?
    let catalogRefreshTask: Task<Void, Never>?
  }

  /// Resolves the instrument-registry wiring for a CloudKit profile. Returns
  /// a populated bundle; nil fields indicate a degraded state (e.g. catalog
  /// init failure).
  ///
  /// CloudKit profiles also build a `SQLiteCoinGeckoCatalog` and fire its
  /// `refreshIfStale()` once per session on a background task so the on-disk
  /// snapshot honours the 24 h max-age + ETag guards without blocking
  /// session init. A catalog construction failure (e.g. the SQLite file
  /// can't be opened) is logged and the catalog is left `nil` — search
  /// degrades to the registry/Yahoo paths only.
  ///
  /// Under `--ui-testing` the active `UITestSeed` may register fake
  /// catalog/resolver implementations via
  /// `UITestSeedCryptoOverrides.overrides(for:)` — those replace the live
  /// SQLite snapshot and `CompositeTokenResolutionClient` so the picker
  /// flow runs deterministically without disk or network access.
  @MainActor
  static func makeRegistryWiring(
    backend: BackendProvider,
    cryptoPriceService: CryptoPriceService,
    yahooPriceFetcher: any YahooFinancePriceFetcher,
    coinGeckoApiKey: String?
  ) -> RegistryWiring {
    guard let cloudBackend = backend as? CloudKitBackend else {
      fatalError("makeBackend only constructs CloudKitBackend")
    }

    let catalog: (any CoinGeckoCatalog)?
    let refreshTask: Task<Void, Never>?
    let resolutionClient: any TokenResolutionClient
    if let overrides = uiTestingCryptoOverrides() {
      catalog = overrides.catalog
      refreshTask = nil
      resolutionClient = overrides.resolutionClient
    } else {
      let made = makeCoinGeckoCatalog()
      catalog = made.catalog
      refreshTask = made.refreshTask
      resolutionClient = CompositeTokenResolutionClient(coinGeckoApiKey: coinGeckoApiKey)
    }
    let store = CryptoTokenStore(
      registry: cloudBackend.instrumentRegistry,
      cryptoPriceService: cryptoPriceService)
    let searchService = InstrumentSearchService(
      registry: cloudBackend.instrumentRegistry,
      catalog: catalog,
      resolutionClient: resolutionClient,
      stockSearchClient: YahooFinanceStockSearchClient()
    )
    return RegistryWiring(
      registry: cloudBackend.instrumentRegistry,
      cryptoTokenStore: store,
      searchService: searchService,
      coinGeckoCatalog: catalog,
      tokenResolutionClient: resolutionClient,
      catalogRefreshTask: refreshTask
    )
  }

  /// Returns the catalog/resolver overrides for the active UI test seed,
  /// or `nil` for production launches. Reads the same arguments and
  /// environment variable that `MoolahApp+Setup.uiTestingSeed(from:)`
  /// consumes during app init — keeping the gating consistent between the
  /// two call sites.
  @MainActor
  private static func uiTestingCryptoOverrides()
    -> (catalog: any CoinGeckoCatalog, resolutionClient: any TokenResolutionClient)?
  {
    guard CommandLine.arguments.contains("--ui-testing") else { return nil }
    guard let raw = ProcessInfo.processInfo.environment["UI_TESTING_SEED"],
      let seed = UITestSeed(rawValue: raw)
    else { return nil }
    return UITestSeedCryptoOverrides.overrides(for: seed)
  }

  /// Builds the per-profile CoinGecko catalog and kicks off a background
  /// `refreshIfStale()` so the SQLite snapshot is brought up to date once per
  /// session without blocking init. Returns `(nil, nil)` (and logs) when the
  /// SQLite file can't be opened — the caller treats that as a degraded
  /// search path. The returned `refreshTask` handle is stored on
  /// `ProfileSession` so it can be cancelled on teardown.
  @MainActor
  private static func makeCoinGeckoCatalog()
    -> (catalog: (any CoinGeckoCatalog)?, refreshTask: Task<Void, Never>?)
  {
    let directory = URL.moolahScopedApplicationSupport
      .appending(path: "InstrumentRegistry", directoryHint: .isDirectory)
    do {
      let catalog = try SQLiteCoinGeckoCatalog(directory: directory)
      // `SQLiteCoinGeckoCatalog` is an actor, so `await catalog.refreshIfStale()`
      // hops to the catalog's executor regardless of the enclosing Task's
      // isolation — no `Task.detached` needed (CONCURRENCY_GUIDE §8).
      let refreshTask = Task(priority: .background) { [catalog] in
        await catalog.refreshIfStale()
      }
      return (catalog, refreshTask)
    } catch {
      Logger(subsystem: "com.moolah.app", category: "ProfileSession")
        .error("CoinGecko catalog init failed: \(error.localizedDescription, privacy: .public)")
      return (nil, nil)
    }
  }

  // MARK: - Domain Stores

  /// Bundle of the per-profile domain stores. Returned from
  /// `makeDomainStores` so `ProfileSession.init` can assign each stored
  /// property in one step without inlining every constructor call.
  struct DomainStores {
    let auth: AuthStore
    let account: AccountStore
    let category: CategoryStore
    let earmark: EarmarkStore
    let transaction: TransactionStore
    let analysis: AnalysisStore
    let investment: InvestmentStore
    let reporting: ReportingStore
  }

  /// Builds all of the domain stores for a profile against a shared
  /// `BackendProvider`. The construction order (accounts + earmarks before
  /// transactions) is preserved to match the previous inline init sequence.
  static func makeDomainStores(
    profile: Profile,
    backend: BackendProvider
  ) -> DomainStores {
    let auth = AuthStore(backend: backend)
    let account = AccountStore(
      repository: backend.accounts, conversionService: backend.conversionService,
      targetInstrument: profile.instrument, investmentRepository: backend.investments)
    let category = CategoryStore(repository: backend.categories)
    let earmark = EarmarkStore(
      repository: backend.earmarks, conversionService: backend.conversionService,
      targetInstrument: profile.instrument)
    let transaction = TransactionStore(
      repository: backend.transactions,
      conversionService: backend.conversionService,
      targetInstrument: profile.instrument,
      accountStore: account,
      earmarkStore: earmark
    )
    let analysis = AnalysisStore(repository: backend.analysis)
    let investment = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService
    )
    let reporting = ReportingStore(
      transactionRepository: backend.transactions,
      analysisRepository: backend.analysis,
      conversionService: backend.conversionService,
      profileCurrency: profile.instrument
    )
    return DomainStores(
      auth: auth, account: account, category: category, earmark: earmark,
      transaction: transaction, analysis: analysis, investment: investment,
      reporting: reporting
    )
  }

}
