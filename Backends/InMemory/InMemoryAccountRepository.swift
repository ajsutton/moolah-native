import Foundation

actor InMemoryAccountRepository: AccountRepository {
    private var accounts: [UUID: Account]
    
    init(initialAccounts: [Account] = []) {
        self.accounts = Dictionary(uniqueKeysWithValues: initialAccounts.map { ($0.id, $0) })
    }
    
    func fetchAll() async throws -> [Account] {
        return Array(accounts.values).sorted { $0.position < $1.position }
    }
    
    // For test setup
    func setAccounts(_ accounts: [Account]) {
        self.accounts = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
    }
}
