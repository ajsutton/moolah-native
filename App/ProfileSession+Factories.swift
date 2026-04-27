// swiftlint:disable multiline_arguments

import CloudKit
import Foundation
import OSLog
import SwiftData

extension ProfileSession {
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
  /// and assign the trio in one step.
  static func makeMarketDataServices() -> MarketDataServices {
    let yahooClient = YahooFinanceClient()
    let apiKeyStore = KeychainStore(
      service: "com.moolah.api-keys", account: "coingecko", synchronizable: true
    )
    let coinGeckoApiKey = try? apiKeyStore.restoreString()
    return MarketDataServices(
      exchangeRate: ExchangeRateService(client: FrankfurterClient()),
      stockPrice: StockPriceService(client: yahooClient),
      cryptoPrice: Self.makeCryptoPriceService(coinGeckoApiKey: coinGeckoApiKey),
      yahooPriceFetcher: yahooClient,
      coinGeckoApiKey: coinGeckoApiKey
    )
  }

  /// Builds the crypto-price service with its configured clients
  /// (CoinGecko when an API key is present in the keychain, plus
  /// CryptoCompare and Binance as fallbacks) and the token resolver.
  static func makeCryptoPriceService(
    coinGeckoApiKey: String?
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
      resolutionClient: CompositeTokenResolutionClient(coinGeckoApiKey: coinGeckoApiKey)
    )
  }

  /// Builds the `BackendProvider` for the profile based on its backend type.
  /// iCloud profiles get the full conversion service (stock + crypto + fiat);
  /// remote profiles use their own internal fiat-only conversion.
  static func makeBackend(
    profile: Profile,
    containerManager: ProfileContainerManager?,
    syncCoordinator: SyncCoordinator? = nil,
    exchangeRates: ExchangeRateService,
    stockPrices: StockPriceService,
    cryptoPrices: CryptoPriceService
  ) -> BackendProvider {
    switch profile.backendType {
    case .remote, .moolah:
      // Each profile gets its own cookie storage and URLSession.
      // Ephemeral config provides an isolated cookie storage that URLSession
      // actually integrates with for automatic Set-Cookie handling.
      let config = URLSessionConfiguration.ephemeral
      // URLSessionConfiguration.ephemeral always has a non-nil httpCookieStorage.
      // swiftlint:disable:next force_unwrapping
      let cookieStorage = config.httpCookieStorage!
      let session = URLSession(configuration: config)
      let cookieKeychain = CookieKeychain(account: profile.id.uuidString)
      // RemoteBackend uses its own FiatConversionService internally;
      // moolah-server is fiat-only so stock/crypto conversion via remote is
      // out of scope. See issue #102 for the CloudKit fix.
      return RemoteBackend(
        baseURL: profile.resolvedServerURL,
        instrument: profile.instrument,
        session: session,
        cookieKeychain: cookieKeychain,
        cookieStorage: cookieStorage
      )

    case .cloudKit:
      guard let containerManager else {
        fatalError("ProfileContainerManager is required for CloudKit profiles")
      }
      // A missing container here means the profile can't be constructed;
      // every call site depends on the session existing so there's no recovery.
      // swiftlint:disable:next force_try
      let profileContainer = try! containerManager.container(for: profile.id)
      let zoneID = CKRecordZone.ID(
        zoneName: "profile-\(profile.id.uuidString)",
        ownerName: CKCurrentUserDefaultName)
      let registry = CloudKitInstrumentRegistryRepository(
        modelContainer: profileContainer,
        onRecordChanged: { [weak syncCoordinator] recordName in
          // Registry callbacks may run off MainActor; hop onto MainActor to
          // reach the actor-isolated SyncCoordinator.queueSave(_:zoneID:).
          Task { @MainActor [weak syncCoordinator] in
            syncCoordinator?.queueSave(recordName: recordName, zoneID: zoneID)
          }
        },
        onRecordDeleted: { [weak syncCoordinator] recordName in
          Task { @MainActor [weak syncCoordinator] in
            syncCoordinator?.queueDeletion(recordName: recordName, zoneID: zoneID)
          }
        }
      )
      // CloudKit profiles need full stock+crypto conversion support. The
      // closure reads the profile's registry on each conversion so
      // registrations added at runtime become usable without rebuilding the
      // service. See issue #102.
      let conversionService = FullConversionService(
        exchangeRates: exchangeRates,
        stockPrices: stockPrices,
        cryptoPrices: cryptoPrices,
        providerMappings: {
          try await registry.allCryptoRegistrations().map(\.mapping)
        }
      )
      return CloudKitBackend(
        modelContainer: profileContainer,
        instrument: profile.instrument,
        profileLabel: profile.label,
        conversionService: conversionService,
        instrumentRegistry: registry
      )
    }
  }

  /// Bundle of the optional instrument-registry pieces: only CloudKit
  /// profiles expose a registry, crypto token store, search service, and
  /// CoinGecko catalogue. Remote/moolah profiles are single-instrument by
  /// server design and leave all four nil.
  struct RegistryWiring {
    let registry: (any InstrumentRegistryRepository)?
    let cryptoTokenStore: CryptoTokenStore?
    let searchService: InstrumentSearchService?
    let coinGeckoCatalog: (any CoinGeckoCatalog)?
  }

  /// Resolves the optional instrument-registry wiring for a profile. Returns
  /// a populated bundle for CloudKit profiles; returns nils for Remote/moolah
  /// profiles so settings views can gate on `cryptoTokenStore != nil`.
  ///
  /// CloudKit profiles also build a `SQLiteCoinGeckoCatalog` and fire its
  /// `refreshIfStale()` once per session on a background task so the on-disk
  /// snapshot honours the 24 h max-age + ETag guards without blocking
  /// session init. A catalog construction failure (e.g. the SQLite file
  /// can't be opened) is logged and the catalogue is left `nil` — search
  /// degrades to the registry/Yahoo paths only.
  @MainActor
  static func makeRegistryWiring(
    backend: BackendProvider,
    cryptoPriceService: CryptoPriceService,
    yahooPriceFetcher: any YahooFinancePriceFetcher,
    coinGeckoApiKey: String?
  ) -> RegistryWiring {
    guard let cloudBackend = backend as? CloudKitBackend else {
      return RegistryWiring(
        registry: nil, cryptoTokenStore: nil, searchService: nil, coinGeckoCatalog: nil)
    }

    let catalog = makeCoinGeckoCatalog()
    let store = CryptoTokenStore(
      registry: cloudBackend.instrumentRegistry,
      cryptoPriceService: cryptoPriceService)
    let searchService = InstrumentSearchService(
      registry: cloudBackend.instrumentRegistry,
      catalog: catalog,
      resolutionClient: CompositeTokenResolutionClient(coinGeckoApiKey: coinGeckoApiKey),
      stockSearchClient: YahooFinanceStockSearchClient()
    )
    return RegistryWiring(
      registry: cloudBackend.instrumentRegistry,
      cryptoTokenStore: store,
      searchService: searchService,
      coinGeckoCatalog: catalog
    )
  }

  /// Builds the per-profile CoinGecko catalogue and kicks off a background
  /// `refreshIfStale()` so the SQLite snapshot is brought up to date once per
  /// session without blocking init. Returns `nil` (and logs) when the
  /// SQLite file can't be opened — the caller treats that as a degraded
  /// search path.
  @MainActor
  private static func makeCoinGeckoCatalog() -> (any CoinGeckoCatalog)? {
    let directory = URL.moolahScopedApplicationSupport
      .appending(path: "InstrumentRegistry", directoryHint: .isDirectory)
    do {
      let catalog = try SQLiteCoinGeckoCatalog(directory: directory)
      Task(priority: .background) { [catalog] in
        await catalog.refreshIfStale()
      }
      return catalog
    } catch {
      Logger(subsystem: "com.moolah.app", category: "ProfileSession")
        .error("CoinGecko catalog init failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

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

  /// Bundle of the full CSV import pipeline: the `ImportStore`, the import-rule
  /// store, and the three folder-watch pieces. Returned from `makeImportPipeline`
  /// so `ProfileSession.init` can assign all five fields in one step.
  struct ImportPipeline {
    let importStore: ImportStore
    let importRuleStore: ImportRuleStore
    let preferences: ImportPreferences
    let scanner: FolderScanService
    let watcher: FolderWatchService
  }

  /// Builds the complete CSV import pipeline for a profile: staging store,
  /// import rules, folder watch, and wires the delete-after-import default
  /// closure into `ImportStore` before returning.
  static func makeImportPipeline(
    backend: BackendProvider,
    profileId: UUID,
    logger: Logger
  ) -> ImportPipeline {
    let stagingDirectory = ProfileSession.importStagingDirectory(for: profileId)
    let importStore = Self.makeImportStore(
      backend: backend,
      stagingDirectory: stagingDirectory,
      profileId: profileId,
      logger: logger
    )
    let importRuleStore = ImportRuleStore(repository: backend.importRules)
    let folderWatch = Self.makeFolderWatch(
      stagingDirectory: stagingDirectory,
      profileId: profileId,
      importStore: importStore
    )
    importStore.folderWatchDeleteAfterImport = { [preferences = folderWatch.preferences] in
      preferences.deleteAfterImportFolderDefault
    }
    return ImportPipeline(
      importStore: importStore,
      importRuleStore: importRuleStore,
      preferences: folderWatch.preferences,
      scanner: folderWatch.scanner,
      watcher: folderWatch.watcher
    )
  }

  /// Bundle of the services that make up folder-watch ingestion for a
  /// profile: the on-disk `ImportPreferences`, the catch-up `FolderScanService`,
  /// and the live `FolderWatchService`. Returned from `makeFolderWatch` so
  /// `ProfileSession.init` can assign each field in one step.
  struct FolderWatchServices {
    let preferences: ImportPreferences
    let scanner: FolderScanService
    let watcher: FolderWatchService
  }

  /// Builds the folder-watch bundle for a profile. `stagingDirectory` is the
  /// per-profile CSV staging directory; preferences live in its parent so
  /// they survive staging-store recreation.
  static func makeFolderWatch(
    stagingDirectory: URL,
    profileId: UUID,
    importStore: ImportStore
  ) -> FolderWatchServices {
    let preferencesDirectory = stagingDirectory.deletingLastPathComponent()
    let preferences = ImportPreferences(directory: preferencesDirectory)
    let scanner = FolderScanService(
      profileId: profileId,
      importStore: importStore,
      preferences: preferences)
    let watcher = FolderWatchService(
      importStore: importStore,
      preferences: preferences,
      scanner: scanner)
    return FolderWatchServices(preferences: preferences, scanner: scanner, watcher: watcher)
  }

  /// Opens the per-profile CSV import staging store. Falls back to a scratch
  /// directory in the tmp dir (which cannot fail in practice on Apple
  /// platforms) if the real directory can't be opened, so the pipeline
  /// remains functional in the degraded mode.
  static func makeImportStore(
    backend: BackendProvider,
    stagingDirectory: URL,
    profileId: UUID,
    logger: Logger
  ) -> ImportStore {
    do {
      let staging = try ImportStagingStore(directory: stagingDirectory)
      return ImportStore(backend: backend, staging: staging)
    } catch {
      let fallback = FileManager.default.temporaryDirectory
        .appendingPathComponent("csv-staging-fallback-\(profileId.uuidString)")
      // Fallback in a tmp dir cannot fail in practice on Apple platforms.
      // swiftlint:disable:next force_try
      let staging = try! ImportStagingStore(directory: fallback)
      let errDesc = error.localizedDescription
      let stagingPath = stagingDirectory.path
      logger.error(
        "Failed to open CSV import staging at \(stagingPath, privacy: .public): \(errDesc, privacy: .public). Falling back to tmp."
      )
      return ImportStore(backend: backend, staging: staging)
    }
  }
}
