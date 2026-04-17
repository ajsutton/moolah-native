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

  /// Per-account display balance (sum of positions converted to the
  /// account's own instrument), updated by `recomputeConvertedTotals`.
  /// An entry is absent if conversion failed for any of the account's
  /// positions; per the bug fix, we never display a partial balance.
  private(set) var convertedBalances: [UUID: InstrumentAmount] = [:]

  /// Investment values keyed by account ID, updated by InvestmentStore.
  private(set) var investmentValues: [UUID: InstrumentAmount] = [:]

  private let repository: AccountRepository
  private let conversionService: any InstrumentConversionService
  private let targetInstrument: Instrument
  /// Delay between retry attempts after a conversion failure. Production
  /// uses ~30s; tests pass a small value to keep retries snappy.
  private let retryDelay: Duration
  private let logger = Logger(subsystem: "com.moolah.app", category: "AccountStore")
  private var conversionTask: Task<Void, Never>?

  init(
    repository: AccountRepository,
    conversionService: any InstrumentConversionService,
    targetInstrument: Instrument,
    retryDelay: Duration = .seconds(30)
  ) {
    self.repository = repository
    self.conversionService = conversionService
    self.targetInstrument = targetInstrument
    self.retryDelay = retryDelay
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

  /// The display balance for an account in its own instrument. For investment
  /// accounts with an externally-provided value, returns that; otherwise sums
  /// every position converted via the conversion service. The conversion service
  /// caches rates, so repeated calls are cheap.
  func displayBalance(for accountId: UUID) async throws -> InstrumentAmount {
    guard let account = accounts.by(id: accountId) else {
      return .zero(instrument: targetInstrument)
    }
    if account.type == .investment, let value = investmentValues[accountId] {
      return value
    }
    var total = InstrumentAmount.zero(instrument: account.instrument)
    let date = Date()
    for position in account.positions {
      let converted = try await conversionService.convertAmount(
        position.amount, to: account.instrument, on: date)
      total += converted
    }
    return total
  }

  /// Whether an account can be deleted (all positions are zero or empty).
  func canDelete(_ accountId: UUID) -> Bool {
    guard let account = accounts.by(id: accountId) else { return false }
    return account.positions.isEmpty || account.positions.allSatisfy { $0.quantity == 0 }
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
    var total = InstrumentAmount.zero(instrument: target)
    let date = Date()
    for account in investmentAccounts {
      let accountBalance = try await displayBalance(for: account.id)
      let converted = try await conversionService.convertAmount(
        accountBalance, to: target, on: date)
      total += converted
    }
    return total
  }

  /// Compute converted net worth (current + investment totals) in a target instrument.
  func computeConvertedNetWorth(in target: Instrument) async throws -> InstrumentAmount {
    let current = try await computeConvertedCurrentTotal(in: target)
    let investment = try await computeConvertedInvestmentTotal(in: target)
    return current + investment
  }

  /// Recompute per-account balances and aggregate totals. Each account is
  /// converted in isolation: a failure for one leaves other accounts'
  /// balances populated. Aggregate totals are only published when *all*
  /// underlying conversions succeed (an inaccurate aggregate is worse than
  /// no aggregate). On any failure, schedules a retry after `retryDelay`
  /// and keeps retrying until everything succeeds or a new recompute
  /// cancels this task.
  private func recomputeConvertedTotals() {
    conversionTask?.cancel()
    let delay = retryDelay
    // `[weak self]` so the retry loop doesn't pin the store alive when the
    // owning view goes away while conversions are still failing.
    conversionTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let anyFailed = await self.runConversionAttempt()
        if !anyFailed { return }
        try? await Task.sleep(for: delay)
      }
    }
  }

  /// Single pass over all accounts; returns `true` if any conversion failed.
  /// Always publishes the latest computed state, even if partial.
  private func runConversionAttempt() async -> Bool {
    var anyFailed = false
    var newBalances: [UUID: InstrumentAmount] = [:]

    // Phase 1: per-account display balance in the account's own instrument.
    // Iterate ALL accounts so per-account display works regardless of showHidden.
    for account in accounts.ordered {
      do {
        let balance = try await displayBalance(for: account.id)
        guard !Task.isCancelled else { return false }
        newBalances[account.id] = balance
      } catch {
        anyFailed = true
        logger.warning(
          "Conversion failed for account \(account.name): \(error.localizedDescription)")
      }
    }

    // Phase 2: aggregate totals — only valid if every contributing account
    // converted successfully *and* the per-account → target conversion works.
    let date = Date()
    let (currentTotal, currentValid) = await sumConverted(
      accounts: currentAccounts, balances: newBalances, on: date)
    let (investmentTotal, investmentValid) = await sumConverted(
      accounts: investmentAccounts, balances: newBalances, on: date)

    guard !Task.isCancelled else { return false }

    if !currentValid || !investmentValid {
      anyFailed = true
    }

    convertedBalances = newBalances
    convertedCurrentTotal = currentValid ? currentTotal : nil
    convertedInvestmentTotal = investmentValid ? investmentTotal : nil
    convertedNetWorth =
      (currentValid && investmentValid) ? (currentTotal + investmentTotal) : nil

    return anyFailed
  }

  /// Sums per-account balances converted to `targetInstrument`. Returns
  /// `(total, valid)`; `valid` is false if any account is missing from
  /// `balances` or if its target conversion throws.
  private func sumConverted(
    accounts list: [Account],
    balances: [UUID: InstrumentAmount],
    on date: Date
  ) async -> (InstrumentAmount, Bool) {
    var total = InstrumentAmount.zero(instrument: targetInstrument)
    var valid = true
    for account in list {
      guard let balance = balances[account.id] else {
        valid = false
        continue
      }
      do {
        let converted = try await conversionService.convertAmount(
          balance, to: targetInstrument, on: date)
        if valid {
          total += converted
        }
      } catch {
        valid = false
        logger.warning(
          "Aggregate conversion failed for \(account.name): \(error.localizedDescription)")
      }
    }
    return (total, valid)
  }

  /// Awaits any in-flight converted-totals recomputation. Intended for tests
  /// that need deterministic synchronisation after `load()` / `applyDelta` /
  /// `updateInvestmentValue` kick off `recomputeConvertedTotals()`.
  ///
  /// Note: when conversions fail and retry is in progress, this will only
  /// return when retries succeed (or a new recompute cancels this task).
  func waitForPendingConversions() async {
    guard let task = conversionTask else { return }
    await task.value
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
