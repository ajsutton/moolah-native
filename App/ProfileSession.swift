import Foundation
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

  nonisolated var id: UUID { profile.id }

  init(profile: Profile, modelContainer: ModelContainer? = nil) {
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
      guard let modelContainer else {
        fatalError("ModelContainer is required for CloudKit profiles")
      }
      backend = CloudKitBackend(
        modelContainer: modelContainer,
        profileId: profile.id,
        currency: profile.currency,
        profileLabel: profile.label
      )
    }
    self.backend = backend
    self.exchangeRateService = ExchangeRateService(client: FrankfurterClient())

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
  }
}
