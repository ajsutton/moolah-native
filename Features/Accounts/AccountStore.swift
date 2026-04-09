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
    investmentAccounts.reduce(.zero) { $0 + $1.displayBalance }
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

  // MARK: - Mutations

  func create(_ account: Account) async throws -> Account {
    isLoading = true
    error = nil

    do {
      let created = try await repository.create(account)

      // Optimistically add to local state
      accounts = Accounts(from: accounts.ordered + [created])
      logger.debug("Created account: \(created.name)")

      isLoading = false
      return created
    } catch {
      logger.error("Failed to create account: \(error.localizedDescription)")
      self.error = error
      isLoading = false
      throw error
    }
  }

  func update(_ account: Account) async throws -> Account {
    isLoading = true
    error = nil

    // Store previous state for rollback
    let previousAccounts = accounts

    // Optimistic update
    accounts = Accounts(from: accounts.ordered.map { $0.id == account.id ? account : $0 })

    do {
      let updated = try await repository.update(account)

      // Replace with server's version (accept server's balance)
      accounts = Accounts(from: accounts.ordered.map { $0.id == updated.id ? updated : $0 })
      logger.debug("Updated account: \(updated.name)")

      isLoading = false
      return updated
    } catch {
      // Rollback on failure
      accounts = previousAccounts
      logger.error("Failed to update account: \(error.localizedDescription)")
      self.error = error
      isLoading = false
      throw error
    }
  }

  func reorderAccounts(_ reordered: [Account], positionOffset: Int = 0) async {
    for (index, account) in reordered.enumerated() {
      var updated = account
      updated.position = positionOffset + index
      do {
        _ = try await repository.update(updated)
      } catch {
        logger.error("Failed to persist account reorder for \(updated.id): \(error)")
      }
    }
    // Reload to get consistent state
    await load()
  }

  func delete(id: UUID) async throws {
    isLoading = true
    error = nil

    // Store previous state for rollback
    let previousAccounts = accounts

    do {
      try await repository.delete(id: id)

      // Remove from local state (filter out hidden)
      accounts = Accounts(from: accounts.ordered.filter { $0.id != id })
      logger.debug("Deleted account: \(id)")

      isLoading = false
    } catch {
      // Rollback on failure
      accounts = previousAccounts
      logger.error("Failed to delete account: \(error.localizedDescription)")
      self.error = error
      isLoading = false
      throw error
    }
  }
}
