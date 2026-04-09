import Foundation

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

  nonisolated var id: UUID { profile.id }

  init(profile: Profile) {
    self.profile = profile

    // Each profile gets its own cookie storage and URLSession
    let cookieStorage = HTTPCookieStorage()
    let config = URLSessionConfiguration.default
    config.httpCookieStorage = cookieStorage
    let session = URLSession(configuration: config)

    // Each profile gets its own keychain entry keyed by profile ID
    let cookieKeychain = CookieKeychain(account: profile.id.uuidString)

    let remoteBackend = RemoteBackend(
      baseURL: profile.serverURL,
      session: session,
      cookieKeychain: cookieKeychain
    )
    self.backend = remoteBackend

    self.authStore = AuthStore(backend: remoteBackend)
    self.accountStore = AccountStore(repository: remoteBackend.accounts)
    self.transactionStore = TransactionStore(repository: remoteBackend.transactions)
    self.categoryStore = CategoryStore(repository: remoteBackend.categories)
    self.earmarkStore = EarmarkStore(repository: remoteBackend.earmarks)
    self.analysisStore = AnalysisStore(repository: remoteBackend.analysis)
    self.investmentStore = InvestmentStore(repository: remoteBackend.investments)

    // Wire up cross-store side effects
    let accountStore = self.accountStore
    let earmarkStore = self.earmarkStore
    self.transactionStore.onMutate = { old, new in
      accountStore.applyTransactionDelta(old: old, new: new)
      earmarkStore.applyTransactionDelta(old: old, new: new)
    }
  }
}
