import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class AccountStore {
  private(set) var accounts: Accounts = Accounts(from: [])
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
      accounts = Accounts(from: try await repository.fetchAll())
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

  var investmentAccounts: [Account] {
    accounts.filter { $0.type == .investment && !$0.isHidden }
  }

  var currentTotal: MonetaryAmount {
    currentAccounts.reduce(.zero) { $0 + $1.balance }
  }

  var investmentTotal: MonetaryAmount {
    investmentAccounts.reduce(.zero) { $0 + $1.balance }
  }

  /// Total of current accounts minus the total of all positive earmarked funds.
  /// Negative earmarked values are skipped in the sum.
  var availableFunds: MonetaryAmount {
    return currentTotal
  }

  var netWorth: MonetaryAmount {
    currentTotal + investmentTotal
  }

  /// Adjusts account balances locally based on a transaction change.
  /// - Parameters:
  ///   - old: The previous transaction (nil for creates).
  ///   - new: The new transaction (nil for deletes).
  func applyTransactionDelta(old: Transaction?, new: Transaction?) {
    var result = accounts

    // Remove the old transaction's effect
    if let old {
      if let accountId = old.accountId {
        result = result.adjustingBalance(of: accountId, by: -old.amount)
      }
      if let toAccountId = old.toAccountId {
        result = result.adjustingBalance(of: toAccountId, by: old.amount)
      }
    }

    // Apply the new transaction's effect
    if let new {
      if let accountId = new.accountId {
        result = result.adjustingBalance(of: accountId, by: new.amount)
      }
      if let toAccountId = new.toAccountId {
        result = result.adjustingBalance(of: toAccountId, by: -new.amount)
      }
    }

    accounts = result
  }
}
