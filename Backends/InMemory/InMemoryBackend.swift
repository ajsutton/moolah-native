import Foundation

/// Full in-memory implementation of BackendProvider.
/// Grows a property each time a new repository protocol is introduced.
final class InMemoryBackend: BackendProvider, @unchecked Sendable {
    let auth: any AuthProvider
    let accounts: any AccountRepository
    let transactions: any TransactionRepository

    init(
        auth: any AuthProvider = InMemoryAuthProvider(),
        accounts: any AccountRepository = InMemoryAccountRepository(),
        transactions: any TransactionRepository = InMemoryTransactionRepository()
    ) {
        self.auth = auth
        self.accounts = accounts
        self.transactions = transactions
    }
}
