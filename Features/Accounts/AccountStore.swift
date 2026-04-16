import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class AccountStore {
  private(set) var accounts: Accounts = Accounts(from: [])
  private(set) var isLoading = false
  private(set) var error: Error?

  private(set) var convertedCurrentTotal: InstrumentAmount?
  private(set) var convertedInvestmentTotal: InstrumentAmount?
  private(set) var convertedNetWorth: InstrumentAmount?

  /// Investment values keyed by account ID, updated by InvestmentStore.
  private(set) var investmentValues: [UUID: InstrumentAmount] = [:]

  private let repository: AccountRepository
  private let conversionService: (any InstrumentConversionService)?
  private let targetInstrument: Instrument
  private let logger = Logger(subsystem: "com.moolah.app", category: "AccountStore")
  private var conversionTask: Task<Void, Never>?

  init(
    repository: AccountRepository,
    conversionService: (any InstrumentConversionService)? = nil,
    targetInstrument: Instrument
  ) {
    self.repository = repository
    self.conversionService = conversionService
    self.targetInstrument = targetInstrument
  }

  func load() async {
    guard !isLoading else { return }

    logger.debug("Loading accounts...")
    isLoading = true
    error = nil

    do {
      accounts = Accounts(from: try await repository.fetchAll())
      logger.debug("Loaded \(self.accounts.count) accounts")
      recomputeConvertedTotals()
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
      let elapsed = (ContinuousClock.now - start).inMilliseconds
      if fresh.ordered != accounts.ordered {
        accounts = fresh
        logger.debug("Sync: updated accounts (\(fresh.count) accounts) in \(elapsed)ms")
        recomputeConvertedTotals()
      }
      if elapsed > 16 {
        logger.warning("⚠️ PERF: accountStore.reloadFromSync took \(elapsed)ms")
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

  /// Get the balance for an account in its own instrument, computed from positions.
  func balance(for accountId: UUID) -> InstrumentAmount {
    guard let account = accounts.by(id: accountId) else {
      return .zero(instrument: targetInstrument)
    }
    let primaryPosition = account.positions.first(where: { $0.instrument == account.instrument })
    return primaryPosition?.amount ?? .zero(instrument: account.instrument)
  }

  /// The display balance for an account: investment value if available for investment accounts,
  /// otherwise the primary position amount.
  func displayBalance(for accountId: UUID) -> InstrumentAmount {
    guard let account = accounts.by(id: accountId) else {
      return .zero(instrument: targetInstrument)
    }
    if account.type == .investment, let value = investmentValues[accountId] {
      return value
    }
    let primaryPosition = account.positions.first(where: { $0.instrument == account.instrument })
    return primaryPosition?.amount ?? .zero(instrument: account.instrument)
  }

  /// Whether an account can be deleted (all positions are zero or empty).
  func canDelete(_ accountId: UUID) -> Bool {
    guard let account = accounts.by(id: accountId) else { return false }
    return account.positions.isEmpty || account.positions.allSatisfy { $0.quantity == 0 }
  }

  var currentTotal: InstrumentAmount {
    currentAccounts.reduce(.zero(instrument: targetInstrument)) {
      $0 + balance(for: $1.id)
    }
  }

  var investmentTotal: InstrumentAmount {
    investmentAccounts.reduce(
      .zero(instrument: targetInstrument)
    ) { $0 + displayBalance(for: $1.id) }
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
  func computeConvertedTotal(for accountList: [Account], in target: Instrument) async throws
    -> InstrumentAmount
  {
    guard let conversionService else {
      return accountList.reduce(.zero(instrument: target)) { $0 + balance(for: $1.id) }
    }

    var total = InstrumentAmount.zero(instrument: target)
    let date = Date()

    for account in accountList {
      for position in account.positions {
        let converted = try await conversionService.convertAmount(
          position.amount, to: target, on: date)
        total += converted
      }
    }
    return total
  }

  /// Compute converted total for current accounts.
  func computeConvertedCurrentTotal(in target: Instrument) async throws -> InstrumentAmount {
    try await computeConvertedTotal(for: currentAccounts, in: target)
  }

  /// Compute converted total for investment accounts.
  func computeConvertedInvestmentTotal(in target: Instrument) async throws -> InstrumentAmount {
    guard let conversionService else {
      return investmentTotal
    }
    var total = InstrumentAmount.zero(instrument: target)
    let date = Date()
    for account in investmentAccounts {
      let converted = try await conversionService.convertAmount(
        displayBalance(for: account.id), to: target, on: date)
      total += converted
    }
    return total
  }

  private func recomputeConvertedTotals() {
    conversionTask?.cancel()
    conversionTask = Task {
      do {
        let current = try await computeConvertedCurrentTotal(in: targetInstrument)
        guard !Task.isCancelled else { return }
        let investment = try await computeConvertedInvestmentTotal(in: targetInstrument)
        guard !Task.isCancelled else { return }
        convertedCurrentTotal = current
        convertedInvestmentTotal = investment
        convertedNetWorth = current + investment
      } catch {
        guard !Task.isCancelled else { return }
        logger.error("Failed to compute converted totals: \(error.localizedDescription)")
      }
    }
  }

  /// Updates the investment value for a specific account locally.
  /// Called when InvestmentStore sets or removes a value.
  func updateInvestmentValue(accountId: UUID, value: InstrumentAmount?) {
    guard accounts.by(id: accountId) != nil else { return }
    if let value {
      investmentValues[accountId] = value
    } else {
      investmentValues.removeValue(forKey: accountId)
    }
    recomputeConvertedTotals()
  }

  /// Applies position deltas to account balances.
  func applyDelta(_ accountDeltas: PositionDeltas) {
    var result = accounts
    for (accountId, instrumentDeltas) in accountDeltas {
      result = result.adjustingPositions(of: accountId, by: instrumentDeltas)
    }
    accounts = result
    recomputeConvertedTotals()
  }

  // MARK: - Mutations

  func create(_ account: Account, openingBalance: InstrumentAmount? = nil) async throws -> Account {
    isLoading = true
    error = nil

    do {
      let created = try await repository.create(account, openingBalance: openingBalance)

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
