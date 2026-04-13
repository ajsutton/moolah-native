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
  let exchangeRateService: ExchangeRateService
  let stockPriceService: StockPriceService
  let cryptoPriceService: CryptoPriceService
  let priceConversionService: PriceConversionService

  /// The sync engine for this profile's CloudKit zone (nil for remote profiles).
  private(set) var profileSyncEngine: ProfileSyncEngine?

  nonisolated var id: UUID { profile.id }

  private let logger = Logger(subsystem: "com.moolah.app", category: "ProfileSession")
  private var syncReloadTask: Task<Void, Never>?

  init(profile: Profile, containerManager: ProfileContainerManager? = nil) {
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
        currency: profile.currency,
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
        currency: profile.currency,
        profileLabel: profile.label
      )
    }
    self.backend = backend
    self.exchangeRateService = ExchangeRateService(client: FrankfurterClient())
    self.stockPriceService = StockPriceService(client: YahooFinanceClient())
    let cryptoCompareClient = CryptoCompareClient()
    let binanceClient = BinanceClient { date in
      let usdt = CryptoToken(
        chainId: 1,
        contractAddress: "0xdac17f958d2ee523a2206206994597c13d831ec7",
        symbol: "USDT", name: "Tether", decimals: 6,
        coingeckoId: "tether", cryptocompareSymbol: "USDT", binanceSymbol: nil
      )
      do {
        return try await cryptoCompareClient.dailyPrice(for: usdt, on: date)
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
    self.priceConversionService = PriceConversionService(
      cryptoPrices: self.cryptoPriceService,
      exchangeRates: self.exchangeRateService
    )

    self.authStore = AuthStore(backend: backend)
    self.accountStore = AccountStore(repository: backend.accounts)
    self.transactionStore = TransactionStore(repository: backend.transactions)
    self.categoryStore = CategoryStore(repository: backend.categories)
    self.earmarkStore = EarmarkStore(repository: backend.earmarks)
    self.analysisStore = AnalysisStore(repository: backend.analysis)
    self.investmentStore = InvestmentStore(repository: backend.investments)

    // Wire up cross-store side effects
    let accountStore = self.accountStore
    let earmarkStore = self.earmarkStore
    self.transactionStore.onMutate = { old, new in
      accountStore.applyTransactionDelta(old: old, new: new)
      earmarkStore.applyTransactionDelta(old: old, new: new)
    }

    // Set up CKSyncEngine for iCloud profiles
    if profile.backendType == .cloudKit, let containerManager {
      let profileContainer = try! containerManager.container(for: profile.id)
      let syncEngine = ProfileSyncEngine(profileId: profile.id, modelContainer: profileContainer)
      syncEngine.onRemoteChangesApplied = { [weak self] in
        self?.scheduleReloadFromSync()
      }
      self.profileSyncEngine = syncEngine

      // Wire repository sync closures — only CloudKit repositories have these properties
      if let repo = backend.accounts as? CloudKitAccountRepository {
        repo.onRecordChanged = { [weak syncEngine] id in syncEngine?.queueSave(id: id) }
        repo.onRecordDeleted = { [weak syncEngine] id in syncEngine?.queueDeletion(id: id) }
      }
      if let repo = backend.transactions as? CloudKitTransactionRepository {
        repo.onRecordChanged = { [weak syncEngine] id in syncEngine?.queueSave(id: id) }
        repo.onRecordDeleted = { [weak syncEngine] id in syncEngine?.queueDeletion(id: id) }
      }
      if let repo = backend.categories as? CloudKitCategoryRepository {
        repo.onRecordChanged = { [weak syncEngine] id in syncEngine?.queueSave(id: id) }
        repo.onRecordDeleted = { [weak syncEngine] id in syncEngine?.queueDeletion(id: id) }
      }
      if let repo = backend.earmarks as? CloudKitEarmarkRepository {
        repo.onRecordChanged = { [weak syncEngine] id in syncEngine?.queueSave(id: id) }
        repo.onRecordDeleted = { [weak syncEngine] id in syncEngine?.queueDeletion(id: id) }
      }
      if let repo = backend.investments as? CloudKitInvestmentRepository {
        repo.onRecordChanged = { [weak syncEngine] id in syncEngine?.queueSave(id: id) }
        repo.onRecordDeleted = { [weak syncEngine] id in syncEngine?.queueDeletion(id: id) }
      }

      syncEngine.start()
    }
  }

  // MARK: - CloudKit Sync

  /// Debounces sync reloads — cancels any pending reload and waits briefly.
  /// This avoids redundant reloads when CKSyncEngine delivers multiple change batches
  /// in quick succession.
  private func scheduleReloadFromSync() {
    syncReloadTask?.cancel()
    syncReloadTask = Task {
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }

      logger.debug("Reloading stores after CloudKit sync")
      await accountStore.reloadFromSync()
      await categoryStore.reloadFromSync()
      await earmarkStore.reloadFromSync()
    }
  }
}
