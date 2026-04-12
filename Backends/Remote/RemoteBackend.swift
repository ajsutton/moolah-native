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
    instrument: Instrument,
    session: URLSession = .shared,
    cookieKeychain: CookieKeychain = CookieKeychain(),
    cookieStorage: HTTPCookieStorage? = nil
  ) {
    let client = APIClient(baseURL: baseURL, session: session)
    let resolvedCookieStorage = cookieStorage ?? session.configuration.httpCookieStorage ?? .shared
    auth = RemoteAuthProvider(
      client: client, cookieKeychain: cookieKeychain, cookieStorage: resolvedCookieStorage)
    accounts = RemoteAccountRepository(client: client, instrument: instrument)
    transactions = RemoteTransactionRepository(client: client, instrument: instrument)
    categories = RemoteCategoryRepository(client: client)
    earmarks = RemoteEarmarkRepository(client: client, instrument: instrument)
    analysis = RemoteAnalysisRepository(client: client, instrument: instrument)
    investments = RemoteInvestmentRepository(client: client, instrument: instrument)
  }
}
