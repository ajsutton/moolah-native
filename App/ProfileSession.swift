import CloudKit
import Foundation
import OSLog
import SwiftData

/// Holds the backend and all stores for a single profile.
/// Each profile gets its own isolated URLSession, cookie storage, and keychain entry.
@Observable
@MainActor
final class ProfileSession: Identifiable {
  let profile: Profile
  let backend: BackendProvider
  let authStore: AuthStore
  let accountStore: AccountStore
  let transactionStore: TransactionStore
  let categoryStore: CategoryStore
  let earmarkStore: EarmarkStore
  let analysisStore: AnalysisStore
  let investmentStore: InvestmentStore
  let reportingStore: ReportingStore
  let exchangeRateService: ExchangeRateService
  let stockPriceService: StockPriceService
  let cryptoPriceService: CryptoPriceService
  let cryptoTokenStore: CryptoTokenStore
  let importStore: ImportStore

  /// Observer token for sync coordinator notifications (nil for remote profiles).
  private var syncObserverToken: SyncCoordinator.ObserverToken?

  nonisolated var id: UUID { profile.id }

  private let logger = Logger(subsystem: "com.moolah.app", category: "ProfileSession")
  private var syncReloadTask: Task<Void, Never>?
  private var pendingChangedTypes = Set<String>()
  private var lastSyncEventTime: ContinuousClock.Instant?

  init(
    profile: Profile, containerManager: ProfileContainerManager? = nil,
    syncCoordinator: SyncCoordinator? = nil
  ) {
    self.profile = profile

    let exchangeRateService = ExchangeRateService(client: FrankfurterClient())
    self.exchangeRateService = exchangeRateService

    let stockPriceService = StockPriceService(client: YahooFinanceClient())
    self.stockPriceService = stockPriceService

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

    let apiKeyStore = KeychainStore(
      service: "com.moolah.api-keys", account: "coingecko", synchronizable: true
    )
    let coinGeckoApiKey = try? apiKeyStore.restoreString()

    var priceClients: [CryptoPriceClient] = []
    if let coinGeckoApiKey, !coinGeckoApiKey.isEmpty {
      priceClients.append(CoinGeckoClient(apiKey: coinGeckoApiKey))
    }
    priceClients.append(cryptoCompareClient)
    priceClients.append(binanceClient)

    let cryptoPriceService = CryptoPriceService(
      clients: priceClients,
      tokenRepository: ICloudTokenRepository(),
      resolutionClient: CompositeTokenResolutionClient(coinGeckoApiKey: coinGeckoApiKey)
    )
    self.cryptoPriceService = cryptoPriceService
    self.cryptoTokenStore = CryptoTokenStore(cryptoPriceService: cryptoPriceService)

    let backend: BackendProvider
    switch profile.backendType {
    case .remote, .moolah:
      // Each profile gets its own cookie storage and URLSession.
      // Ephemeral config provides an isolated cookie storage that URLSession
      // actually integrates with for automatic Set-Cookie handling.
      let config = URLSessionConfiguration.ephemeral
      let cookieStorage = config.httpCookieStorage!
      let session = URLSession(configuration: config)

      // Each profile gets its own keychain entry keyed by profile ID
      let cookieKeychain = CookieKeychain(account: profile.id.uuidString)

      // RemoteBackend uses its own FiatConversionService internally;
      // moolah-server is fiat-only so stock/crypto conversion via remote is
      // out of scope. See issue #102 for the CloudKit fix.
      backend = RemoteBackend(
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
      let profileContainer = try! containerManager.container(for: profile.id)
      // CloudKit profiles need full stock+crypto conversion support. The
      // closure reads registered tokens from CryptoPriceService on each
      // conversion so registrations added at runtime become usable without
      // rebuilding the service. See issue #102.
      let conversionService = FullConversionService(
        exchangeRates: exchangeRateService,
        stockPrices: stockPriceService,
        cryptoPrices: cryptoPriceService,
        providerMappings: {
          await cryptoPriceService.registeredItems().map(\.mapping)
        }
      )
      backend = CloudKitBackend(
        modelContainer: profileContainer,
        instrument: profile.instrument,
        profileLabel: profile.label,
        conversionService: conversionService
      )
    }
    self.backend = backend
    self.authStore = AuthStore(backend: backend)
    self.accountStore = AccountStore(
      repository: backend.accounts, conversionService: backend.conversionService,
      targetInstrument: profile.instrument)
    self.categoryStore = CategoryStore(repository: backend.categories)
    self.earmarkStore = EarmarkStore(
      repository: backend.earmarks, conversionService: backend.conversionService,
      targetInstrument: profile.instrument)
    self.transactionStore = TransactionStore(
      repository: backend.transactions,
      conversionService: backend.conversionService,
      targetInstrument: profile.instrument,
      accountStore: self.accountStore,
      earmarkStore: self.earmarkStore
    )
    self.analysisStore = AnalysisStore(repository: backend.analysis)
    self.investmentStore = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService
    )
    self.reportingStore = ReportingStore(
      transactionRepository: backend.transactions,
      analysisRepository: backend.analysis,
      conversionService: backend.conversionService,
      profileCurrency: profile.instrument
    )

    // CSV import: ImportStore owns the pipeline orchestration; the staging
    // store lives per-profile on disk so pending/failed files follow the
    // profile across app restarts.
    let stagingDirectory = ProfileSession.importStagingDirectory(for: profile.id)
    do {
      let staging = try ImportStagingStore(directory: stagingDirectory)
      self.importStore = ImportStore(backend: backend, staging: staging)
    } catch {
      // Fall back to a scratch staging store in a temporary directory. This
      // keeps the store non-optional — pending/failed files won't persist
      // across app restarts in this degraded mode but the pipeline still
      // works.
      let fallback = FileManager.default.temporaryDirectory
        .appendingPathComponent("csv-staging-fallback-\(profile.id.uuidString)")
      // swiftlint:disable:next force_try — fallback in a tmp dir cannot fail
      // in practice on Apple platforms.
      let staging = try! ImportStagingStore(directory: fallback)
      self.importStore = ImportStore(backend: backend, staging: staging)
      let errDesc = error.localizedDescription
      let stagingPath = stagingDirectory.path
      logger.error(
        "Failed to open CSV import staging at \(stagingPath, privacy: .public): \(errDesc, privacy: .public). Falling back to tmp."
      )
    }

    // Wire up cross-store side effects. The callback is fire-and-forget in
    // production; `updateInvestmentValue` awaits its own first conversion
    // pass, so the sidebar reflects the new value once the Task completes
    // on MainActor.
    let accountStore = self.accountStore
    self.investmentStore.onInvestmentValueChanged = { accountId, latestValue in
      Task {
        await accountStore.updateInvestmentValue(accountId: accountId, value: latestValue)
      }
    }

    // Register with SyncCoordinator for iCloud profiles
    if profile.backendType == .cloudKit, let syncCoordinator {
      let zoneID = CKRecordZone.ID(
        zoneName: "profile-\(profile.id.uuidString)",
        ownerName: CKCurrentUserDefaultName)

      logger.info("Registering profile \(profile.id) with sync coordinator")
      self.syncObserverToken = syncCoordinator.addObserver(for: profile.id) {
        [weak self] changedTypes in
        self?.scheduleReloadFromSync(changedTypes: changedTypes)
      }

      // Wire repository sync closures to coordinator
      if let repo = backend.accounts as? CloudKitAccountRepository {
        repo.onRecordChanged = { [weak syncCoordinator] id in
          syncCoordinator?.queueSave(id: id, zoneID: zoneID)
        }
        repo.onRecordDeleted = { [weak syncCoordinator] id in
          syncCoordinator?.queueDeletion(id: id, zoneID: zoneID)
        }
        repo.onInstrumentChanged = { [weak syncCoordinator] id in
          syncCoordinator?.queueSave(recordName: id, zoneID: zoneID)
        }
      }
      if let repo = backend.transactions as? CloudKitTransactionRepository {
        repo.onRecordChanged = { [weak syncCoordinator] id in
          syncCoordinator?.queueSave(id: id, zoneID: zoneID)
        }
        repo.onRecordDeleted = { [weak syncCoordinator] id in
          syncCoordinator?.queueDeletion(id: id, zoneID: zoneID)
        }
        repo.onInstrumentChanged = { [weak syncCoordinator] id in
          syncCoordinator?.queueSave(recordName: id, zoneID: zoneID)
        }
      }
      if let repo = backend.categories as? CloudKitCategoryRepository {
        repo.onRecordChanged = { [weak syncCoordinator] id in
          syncCoordinator?.queueSave(id: id, zoneID: zoneID)
        }
        repo.onRecordDeleted = { [weak syncCoordinator] id in
          syncCoordinator?.queueDeletion(id: id, zoneID: zoneID)
        }
      }
      if let repo = backend.earmarks as? CloudKitEarmarkRepository {
        repo.onRecordChanged = { [weak syncCoordinator] id in
          syncCoordinator?.queueSave(id: id, zoneID: zoneID)
        }
        repo.onRecordDeleted = { [weak syncCoordinator] id in
          syncCoordinator?.queueDeletion(id: id, zoneID: zoneID)
        }
      }
      if let repo = backend.investments as? CloudKitInvestmentRepository {
        repo.onRecordChanged = { [weak syncCoordinator] id in
          syncCoordinator?.queueSave(id: id, zoneID: zoneID)
        }
        repo.onRecordDeleted = { [weak syncCoordinator] id in
          syncCoordinator?.queueDeletion(id: id, zoneID: zoneID)
        }
      }
      if let repo = backend.csvImportProfiles as? CloudKitCSVImportProfileRepository {
        repo.onRecordChanged = { [weak syncCoordinator] id in
          syncCoordinator?.queueSave(id: id, zoneID: zoneID)
        }
        repo.onRecordDeleted = { [weak syncCoordinator] id in
          syncCoordinator?.queueDeletion(id: id, zoneID: zoneID)
        }
      }
      if let repo = backend.importRules as? CloudKitImportRuleRepository {
        repo.onRecordChanged = { [weak syncCoordinator] id in
          syncCoordinator?.queueSave(id: id, zoneID: zoneID)
        }
        repo.onRecordDeleted = { [weak syncCoordinator] id in
          syncCoordinator?.queueDeletion(id: id, zoneID: zoneID)
        }
      }
    } else if profile.backendType == .cloudKit {
      logger.warning("CloudKit not available — profile sync disabled for \(profile.id)")
    }
  }

  // MARK: - CloudKit Sync

  /// Debounces sync reloads — cancels any pending reload and waits briefly.
  /// This avoids redundant reloads when CKSyncEngine delivers multiple change batches
  /// in quick succession. Only reloads stores affected by the changed record types.
  /// During bulk sync (rapid consecutive batches), the debounce increases to 2s to
  /// avoid thrashing.
  private func scheduleReloadFromSync(changedTypes: Set<String>) {
    pendingChangedTypes.formUnion(changedTypes)

    let now = ContinuousClock.now
    let isBulkSync: Bool
    if let last = lastSyncEventTime, now - last < .seconds(1) {
      isBulkSync = true
    } else {
      isBulkSync = false
    }
    lastSyncEventTime = now
    let debounceMs = isBulkSync ? 2000 : 500

    syncReloadTask?.cancel()
    syncReloadTask = Task {
      try? await Task.sleep(for: .milliseconds(debounceMs))
      guard !Task.isCancelled else { return }

      let types = self.pendingChangedTypes
      self.pendingChangedTypes.removeAll()

      let reloadStart = ContinuousClock.now
      logger.debug("Reloading stores after CloudKit sync: \(types)")
      let plan = Self.storesToReload(for: types)
      if plan.contains(.accounts) {
        await accountStore.reloadFromSync()
      }
      if plan.contains(.categories) {
        await categoryStore.reloadFromSync()
      }
      if plan.contains(.earmarks) {
        await earmarkStore.reloadFromSync()
      }
      let reloadMs = (ContinuousClock.now - reloadStart).inMilliseconds
      logger.info("📊 Store reloads after sync completed in \(reloadMs)ms for types: \(types)")
    }
  }

  /// Which stores should be reloaded for a given set of changed record types.
  /// Exposed as a pure static function so the reload-mapping policy can be
  /// unit-tested without driving the debounced async task.
  ///
  /// `TransactionLegRecord` drives both account balances and earmark positions,
  /// so a remote leg-only change (e.g. category/earmark reassignment performed
  /// on another device) must reload both stores even if the parent
  /// `TransactionRecord` did not change in this batch.
  struct StoreReloadPlan: OptionSet, Sendable, Equatable {
    let rawValue: Int
    static let accounts = StoreReloadPlan(rawValue: 1 << 0)
    static let categories = StoreReloadPlan(rawValue: 1 << 1)
    static let earmarks = StoreReloadPlan(rawValue: 1 << 2)
  }

  static func storesToReload(for changedTypes: Set<String>) -> StoreReloadPlan {
    var plan: StoreReloadPlan = []
    if changedTypes.contains(AccountRecord.recordType)
      || changedTypes.contains(TransactionRecord.recordType)
      || changedTypes.contains(TransactionLegRecord.recordType)
    {
      plan.insert(.accounts)
    }
    if changedTypes.contains(CategoryRecord.recordType) {
      plan.insert(.categories)
    }
    if changedTypes.contains(EarmarkRecord.recordType)
      || changedTypes.contains(EarmarkBudgetItemRecord.recordType)
      || changedTypes.contains(TransactionLegRecord.recordType)
    {
      plan.insert(.earmarks)
    }
    // NOTE: CSVImportProfileRecord and ImportRuleRecord arrive through sync but
    // have no dedicated stores yet. Phase F of the CSV import feature will add
    // CSVImportProfileStore and ImportRuleStore; this function will need
    // corresponding `plan.insert(…)` entries at that point. Until then, remote
    // changes land in SwiftData but no observer is notified — acceptable because
    // there's no UI consuming them yet.
    return plan
  }

  // MARK: - Sync Cleanup

  /// Removes the sync observer from the coordinator. Call when the session is being torn down.
  func cleanupSync(coordinator: SyncCoordinator) {
    if let token = syncObserverToken {
      coordinator.removeObserver(token: token)
      syncObserverToken = nil
    }
    syncReloadTask?.cancel()
    syncReloadTask = nil
  }

  /// Per-profile directory under Application Support where CSV import staging
  /// lives. Not part of the SwiftData store because staging is device-local
  /// and doesn't sync.
  nonisolated static func importStagingDirectory(for profileId: UUID) -> URL {
    let base =
      (try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true))
      ?? FileManager.default.temporaryDirectory
    return
      base
      .appendingPathComponent("Moolah", isDirectory: true)
      .appendingPathComponent("csv-staging", isDirectory: true)
      .appendingPathComponent(profileId.uuidString, isDirectory: true)
  }
}
