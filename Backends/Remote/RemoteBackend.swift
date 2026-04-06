import Foundation

/// Concrete BackendProvider that talks to the Moolah REST API.
/// Assembled at the composition root in MoolahApp; never imported by features directly.
@MainActor
final class RemoteBackend: BackendProvider {
  let auth: any AuthProvider
  let accounts: any AccountRepository
  let transactions: any TransactionRepository

  init(baseURL: URL) {
    let client = APIClient(baseURL: baseURL)
    auth = RemoteAuthProvider(client: client)
    accounts = RemoteAccountRepository(client: client)
    transactions = RemoteTransactionRepository(client: client)
  }
}
