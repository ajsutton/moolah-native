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
    self.cryptoPriceService = CryptoPriceService(
      clients: [CryptoCompareClient(), BinanceClient()]
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

    // Observe CloudKit remote changes for iCloud profiles
    if profile.backendType == .cloudKit {
      observeRemoteChanges()
    }
  }

  // MARK: - CloudKit Sync

  /// Observes remote CloudKit changes and silently reloads stores.
  /// Debounces rapid-fire notifications (CloudKit often sends several in quick succession).
  private func observeRemoteChanges() {
    NotificationCenter.default.addObserver(
      forName: .NSPersistentStoreRemoteChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.scheduleReloadFromSync()
      }
    }
  }

  /// Debounces sync reloads — cancels any pending reload and waits briefly.
  /// This avoids redundant reloads when CloudKit delivers multiple change notifications
  /// in quick succession, and gives the ModelContext time to merge the changes.
  private func scheduleReloadFromSync() {
    syncReloadTask?.cancel()
    syncReloadTask = Task {
      // Wait for ModelContext to merge remote changes and debounce rapid notifications.
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }

      logger.debug("Reloading stores after CloudKit sync")
      await accountStore.reloadFromSync()
      await categoryStore.reloadFromSync()
      await earmarkStore.reloadFromSync()
    }
  }
}
