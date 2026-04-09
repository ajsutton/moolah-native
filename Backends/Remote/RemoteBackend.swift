import Foundation

/// Concrete BackendProvider that talks to the Moolah REST API.
/// Assembled at the composition root in MoolahApp; never imported by features directly.
/// @MainActor because it constructs RemoteAuthProvider which requires main-actor isolation.
@MainActor
final class RemoteBackend: BackendProvider {
  let auth: any AuthProvider
  let accounts: any AccountRepository
  let transactions: any TransactionRepository
  let categories: any CategoryRepository
  let earmarks: any EarmarkRepository
  let analysis: any AnalysisRepository
  let investments: any InvestmentRepository

  init(
    baseURL: URL,
    session: URLSession = .shared,
    cookieKeychain: CookieKeychain = CookieKeychain()
  ) {
    let client = APIClient(baseURL: baseURL, session: session)
    let cookieStorage = session.configuration.httpCookieStorage ?? .shared
    auth = RemoteAuthProvider(
      client: client, cookieKeychain: cookieKeychain, cookieStorage: cookieStorage)
    accounts = RemoteAccountRepository(client: client)
    transactions = RemoteTransactionRepository(client: client)
    categories = RemoteCategoryRepository(client: client)
    earmarks = RemoteEarmarkRepository(client: client)
    analysis = RemoteAnalysisRepository(client: client)
    investments = RemoteInvestmentRepository(client: client)
  }
}
