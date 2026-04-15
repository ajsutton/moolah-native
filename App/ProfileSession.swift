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
  let tradeStore: TradeStore
  let exchangeRateService: ExchangeRateService
  let stockPriceService: StockPriceService
  let cryptoPriceService: CryptoPriceService

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
      backend = CloudKitBackend(
        modelContainer: profileContainer,
        instrument: profile.instrument,
        profileLabel: profile.label
      )
    }
    self.backend = backend
    self.exchangeRateService = ExchangeRateService(client: FrankfurterClient())
    self.stockPriceService = StockPriceService(client: YahooFinanceClient())
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

    self.cryptoPriceService = CryptoPriceService(
      clients: priceClients,
      tokenRepository: ICloudTokenRepository(),
      resolutionClient: CompositeTokenResolutionClient(coinGeckoApiKey: coinGeckoApiKey)
    )
    self.authStore = AuthStore(backend: backend)
    self.accountStore = AccountStore(
      repository: backend.accounts, conversionService: backend.conversionService)
    self.transactionStore = TransactionStore(
      repository: backend.transactions,
      conversionService: backend.conversionService,
      targetInstrument: profile.instrument
    )
    self.categoryStore = CategoryStore(repository: backend.categories)
    self.earmarkStore = EarmarkStore(repository: backend.earmarks)
    self.analysisStore = AnalysisStore(repository: backend.analysis)
    self.investmentStore = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions
    )
    self.tradeStore = TradeStore(transactions: backend.transactions)

    // Wire up cross-store side effects
    let accountStore = self.accountStore
    let earmarkStore = self.earmarkStore
    self.transactionStore.onMutate = { old, new in
      accountStore.applyTransactionDelta(old: old, new: new)
      earmarkStore.applyTransactionDelta(old: old, new: new)
    }
    self.investmentStore.onInvestmentValueChanged = { accountId, latestValue in
      accountStore.updateInvestmentValue(accountId: accountId, value: latestValue)
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
      if types.contains(AccountRecord.recordType) || types.contains(TransactionRecord.recordType) {
        await accountStore.reloadFromSync()
      }
      if types.contains(CategoryRecord.recordType) {
        await categoryStore.reloadFromSync()
      }
      if types.contains(EarmarkRecord.recordType)
        || types.contains(EarmarkBudgetItemRecord.recordType)
      {
        await earmarkStore.reloadFromSync()
      }
      let reloadMs = (ContinuousClock.now - reloadStart).inMilliseconds
      logger.info("📊 Store reloads after sync completed in \(reloadMs)ms for types: \(types)")
    }
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
}
