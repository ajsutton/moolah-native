import Foundation
import Observation
import OSLog

@Observable
@MainActor
final class AccountStore {
    private(set) var accounts: [Account] = []
    private(set) var isLoading = false
    private(set) var error: Error?
    
    private let repository: AccountRepository
    private let logger = Logger(subsystem: "com.moolah.app", category: "AccountStore")
    
    init(repository: AccountRepository) {
        self.repository = repository
    }
    
    func load() async {
        guard !isLoading else { return }
        
        logger.debug("Loading accounts...")
        isLoading = true
        error = nil
        
        do {
            accounts = try await repository.fetchAll()
            logger.debug("Loaded \(self.accounts.count) accounts")
        } catch {
            logger.error("❌ Failed to load accounts: \(error.localizedDescription)")
            self.error = error
        }
        
        isLoading = false
    }
    
    var currentAccounts: [Account] {
        accounts.filter { $0.type.isCurrent && !$0.isHidden }
    }
    
    var earmarkAccounts: [Account] {
        return []
    }
    
    var investmentAccounts: [Account] {
        accounts.filter { $0.type == .investment && !$0.isHidden }
    }
    
    var currentTotal: Int {
        currentAccounts.reduce(0) { $0 + $1.balance }
    }
    
    var earmarkedTotal: Int {
        earmarkAccounts.reduce(0) { $0 + $1.balance }
    }
    
    var investmentTotal: Int {
        investmentAccounts.reduce(0) { $0 + $1.balance }
    }
    
    /// Total of current accounts minus the total of all positive earmarked funds.
    /// Negative earmarked values are skipped in the sum.
    var availableFunds: Int {
        let positiveEarmarksTotal = earmarkAccounts
            .filter { $0.balance > 0 }
            .reduce(0) { $0 + $1.balance }
        return currentTotal - positiveEarmarksTotal
    }
    
    var netWorth: Int {
        currentTotal + earmarkedTotal + investmentTotal
    }
}
