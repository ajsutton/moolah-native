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
  private let conversionService: (any InstrumentConversionService)?
  private let logger = Logger(subsystem: "com.moolah.app", category: "AccountStore")

  init(
    repository: AccountRepository,
    conversionService: (any InstrumentConversionService)? = nil
  ) {
    self.repository = repository
    self.conversionService = conversionService
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

  /// Re-fetches accounts without showing loading state or clearing errors.
  /// Used when CloudKit delivers remote changes — avoids UI flicker.
  func reloadFromSync() async {
    let start = ContinuousClock.now
    do {
      let fresh = Accounts(from: try await repository.fetchAll())
      let fetchMs = (ContinuousClock.now - start).inMilliseconds
      if fresh.ordered != accounts.ordered {
        accounts = fresh
        logger.debug("Sync: updated accounts (\(fresh.count) accounts)")
      }
      let totalMs = (ContinuousClock.now - start).inMilliseconds
      if totalMs > 16 {
        logger.warning(
          "⚠️ PERF: accountStore.reloadFromSync took \(totalMs)ms (fetch: \(fetchMs)ms, diff+assign: \(totalMs - fetchMs)ms)"
        )
      }
    } catch {
      logger.error("Sync reload failed: \(error.localizedDescription)")
    }
  }

  var showHidden: Bool = false

  var currentAccounts: [Account] {
    accounts.filter { $0.type.isCurrent && (showHidden || !$0.isHidden) }
  }

  var investmentAccounts: [Account] {
    accounts.filter { $0.type == .investment && (showHidden || !$0.isHidden) }
  }

  var currentTotal: InstrumentAmount {
    currentAccounts.reduce(.zero(instrument: currentAccounts.first?.balance.instrument ?? .AUD)) {
      $0 + $1.balance
    }
  }

  var investmentTotal: InstrumentAmount {
    investmentAccounts.reduce(
      .zero(instrument: investmentAccounts.first?.displayBalance.instrument ?? .AUD)
    ) { $0 + $1.displayBalance }
  }

  /// Total of current accounts minus the total of all positive, visible earmarked funds.
  /// Hidden earmarks and those with negative balances are excluded from the sum.
  func availableFunds(earmarks: Earmarks) -> InstrumentAmount {
    let earmarked = earmarks.ordered
      .filter { !$0.isHidden && $0.balance.isPositive }
      .reduce(InstrumentAmount.zero(instrument: currentTotal.instrument)) { $0 + $1.balance }
    return currentTotal - earmarked
  }

  var netWorth: InstrumentAmount {
    currentTotal + investmentTotal
  }

  /// Positions for a given account. Returns empty array if not loaded.
  func positions(for accountId: UUID) -> [Position] {
    accounts.by(id: accountId)?.positions ?? []
  }

  /// Compute the total value of all current accounts in a target instrument,
  /// converting foreign-currency positions via the conversion service.
  func convertedTotal(for accountList: [Account], in targetInstrument: Instrument) async throws
    -> InstrumentAmount
  {
    guard let conversionService else {
      return accountList.reduce(.zero(instrument: targetInstrument)) { $0 + $1.balance }
    }

    var total = InstrumentAmount.zero(instrument: targetInstrument)
    let date = Date()

    for account in accountList {
      let positions = account.positions
      if positions.isEmpty {
        // Fallback: use the single balance
        let converted = try await conversionService.convertAmount(
          account.balance, to: targetInstrument, on: date)
        total += converted
      } else {
        for position in positions {
          let converted = try await conversionService.convertAmount(
            position.amount, to: targetInstrument, on: date)
          total += converted
        }
      }
    }
    return total
  }

  /// Converted total for current accounts.
  func convertedCurrentTotal(in targetInstrument: Instrument) async throws -> InstrumentAmount {
    try await convertedTotal(for: currentAccounts, in: targetInstrument)
  }

  /// Converted total for investment accounts.
  func convertedInvestmentTotal(in targetInstrument: Instrument) async throws -> InstrumentAmount {
    guard let conversionService else {
      return investmentTotal
    }
    var total = InstrumentAmount.zero(instrument: targetInstrument)
    let date = Date()
    for account in investmentAccounts {
      let converted = try await conversionService.convertAmount(
        account.displayBalance, to: targetInstrument, on: date)
      total += converted
    }
    return total
  }

  /// Updates the investment value for a specific account locally.
  /// Called when InvestmentStore sets or removes a value.
  func updateInvestmentValue(accountId: UUID, value: InstrumentAmount?) {
    guard accounts.by(id: accountId) != nil else { return }
    let updated = accounts.ordered.map { account in
      guard account.id == accountId else { return account }
      var copy = account
      copy.investmentValue = value
      return copy
    }
    accounts = Accounts(from: updated)
  }

  /// Adjusts account balances locally based on a transaction change.
  /// - Parameters:
  ///   - old: The previous transaction (nil for creates).
  ///   - new: The new transaction (nil for deletes).
  func applyTransactionDelta(old: Transaction?, new: Transaction?) {
    var result = accounts

    // Remove the old transaction's effect (skip scheduled — they don't affect balances)
    if let old, !old.isScheduled {
      for leg in old.legs {
        guard let accountId = leg.accountId else { continue }
        result = result.adjustingBalance(of: accountId, by: -leg.amount)
      }
    }

    // Apply the new transaction's effect (skip scheduled — they don't affect balances)
    if let new, !new.isScheduled {
      for leg in new.legs {
        guard let accountId = leg.accountId else { continue }
        result = result.adjustingBalance(of: accountId, by: leg.amount)
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
