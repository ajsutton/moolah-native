import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class AccountStore {
  private(set) var accounts = Accounts(from: [])
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

  /// Externally-set values for investment accounts (e.g. mark-to-market share
  /// prices set via `InvestmentStore`). Read-through to `investmentValueCache`
  /// so existing call sites can continue to inspect the map directly.
  var investmentValues: [UUID: InstrumentAmount] { investmentValueCache.values }

  /// True once at least one conversion pass has completed, regardless of
  /// success or failure. Views use this to distinguish "still loading"
  /// from "conversion ran and produced no balance".
  private(set) var hasCompletedInitialConversion: Bool = false

  private let repository: AccountRepository
  private let conversionService: any InstrumentConversionService
  private let targetInstrument: Instrument
  private let investmentValueCache: InvestmentValueCache
  private let balanceCalculator: AccountBalanceCalculator
  /// Delay between retry attempts after a conversion failure. Production
  /// uses ~30s; tests pass a small value to keep retries snappy.
  private let retryDelay: Duration
  private let logger = Logger(subsystem: "com.moolah.app", category: "AccountStore")
  private var conversionTask: Task<Void, Never>?

  init(
    repository: AccountRepository,
    conversionService: any InstrumentConversionService,
    targetInstrument: Instrument,
    investmentRepository: (any InvestmentRepository)? = nil,
    retryDelay: Duration = .seconds(30)
  ) {
    self.repository = repository
    self.conversionService = conversionService
    self.targetInstrument = targetInstrument
    self.investmentValueCache = InvestmentValueCache(repository: investmentRepository)
    self.balanceCalculator = AccountBalanceCalculator(
      conversionService: conversionService, targetInstrument: targetInstrument)
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
      await preloadInvestmentValues()
      await recomputeConvertedTotals()
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
        await preloadInvestmentValues()
        await recomputeConvertedTotals()
      }
      if elapsed > 16 {
        logger.warning("⚠️ PERF: accountStore.reloadFromSync took \(elapsed)ms")
      }
    } catch {
      logger.error("Sync reload failed: \(error.localizedDescription)")
    }
  }

  /// Asks `investmentValueCache` to hydrate itself with the latest value for
  /// every investment account. Without this, `displayBalance` falls back to
  /// summing positions until `InvestmentStore` happens to call
  /// `updateInvestmentValue(accountId:value:)`, so the sidebar flashes the
  /// transaction sum until the user opens an investment account. See
  /// `InvestmentValueCache.preload(for:)` for the failure-tolerant details.
  private func preloadInvestmentValues() async {
    // Only `recordedValue` investment accounts read from the snapshot cache;
    // `calculatedFromTrades` accounts derive their value from positions, so
    // their snapshot fetch would be a wasted round-trip.
    let investmentAccountIds = accounts.ordered
      .filter { $0.type == .investment && $0.valuationMode == .recordedValue }
      .map(\.id)
    await investmentValueCache.preload(for: investmentAccountIds)
  }

  var showHidden: Bool = false

  var currentAccounts: [Account] {
    accounts.filter { $0.type.isCurrent && (showHidden || !$0.isHidden) }
  }

  var investmentAccounts: [Account] {
    accounts.filter { $0.type == .investment && (showHidden || !$0.isHidden) }
  }

  /// The display balance for an account in its own instrument. Forwards to
  /// `balanceCalculator`, passing the cached externally-set investment value
  /// when the account is an investment account.
  func displayBalance(for accountId: UUID) async throws -> InstrumentAmount {
    guard let account = accounts.by(id: accountId) else {
      return .zero(instrument: targetInstrument)
    }
    return try await balanceCalculator.displayBalance(
      for: account, investmentValue: investmentValueCache.value(for: accountId))
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

  /// Total value of `accountList` in `target`, summing positions directly.
  func computeConvertedTotal(for accountList: [Account], in target: Instrument) async throws
    -> InstrumentAmount
  {
    try await balanceCalculator.totalConverted(for: accountList, to: target)
  }

  /// Total value of current accounts in `target`.
  func computeConvertedCurrentTotal(in target: Instrument) async throws -> InstrumentAmount {
    try await balanceCalculator.totalConverted(for: currentAccounts, to: target)
  }

  /// Total value of investment accounts in `target`. Uses cached external
  /// values when present; otherwise sums positions. Single-pass to avoid
  /// the double-conversion a two-phase approach would chain.
  func computeConvertedInvestmentTotal(in target: Instrument) async throws -> InstrumentAmount {
    try await balanceCalculator.totalConverted(
      for: investmentAccounts, to: target, using: investmentValueCache)
  }

  /// Net worth (current + investment) in `target`.
  func computeConvertedNetWorth(in target: Instrument) async throws -> InstrumentAmount {
    let current = try await computeConvertedCurrentTotal(in: target)
    let investment = try await computeConvertedInvestmentTotal(in: target)
    return current + investment
  }

  /// Recompute per-account balances and aggregate totals via
  /// `balanceCalculator`. The first pass runs inline and is awaited by the
  /// caller, so after `load()` (and every other caller below) returns,
  /// observers see fully-published balances. If the first pass reports any
  /// conversion failure, a `[weak self]` background retry loop is spawned
  /// that keeps attempting until everything succeeds or a new recompute
  /// cancels it. Callers that want to await retry success use
  /// `waitForPendingConversions()`.
  private func recomputeConvertedTotals() async {
    conversionTask?.cancel()
    conversionTask = nil

    let snapshot = await computeBalanceSnapshot()
    publishSnapshot(snapshot)
    guard snapshot.anyFailed else { return }

    let delay = retryDelay
    conversionTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: delay)
        guard let self, !Task.isCancelled else { return }
        let retry = await self.computeBalanceSnapshot()
        self.publishSnapshot(retry)
        if !retry.anyFailed { return }
      }
    }
  }

  private func computeBalanceSnapshot() async -> AccountBalanceCalculator.Snapshot {
    await balanceCalculator.compute(
      allAccounts: accounts.ordered,
      currentAccounts: currentAccounts,
      investmentAccounts: investmentAccounts,
      investmentValues: investmentValueCache)
  }

  private func publishSnapshot(_ snapshot: AccountBalanceCalculator.Snapshot) {
    convertedBalances = snapshot.balances
    convertedCurrentTotal = snapshot.currentTotal
    convertedInvestmentTotal = snapshot.investmentTotal
    convertedNetWorth = snapshot.netWorth
    hasCompletedInitialConversion = true
  }

  /// Awaits the background retry loop, if one is running. Only relevant
  /// after a first pass that hit a conversion failure — returns immediately
  /// when the store has no retry task pending. When a retry loop is running,
  /// this returns when it terminates (which happens only when a retry pass
  /// succeeds, or a new recompute cancels the loop).
  func waitForPendingConversions() async {
    guard let task = conversionTask else { return }
    await task.value
  }

  /// Updates the investment value for a specific account locally.
  /// Called when `InvestmentStore` sets or removes a value.
  func updateInvestmentValue(accountId: UUID, value: InstrumentAmount?) async {
    guard accounts.by(id: accountId) != nil else { return }
    investmentValueCache.set(value, for: accountId)
    await recomputeConvertedTotals()
  }

  /// Applies position deltas to account balances.
  func applyDelta(_ accountDeltas: PositionDeltas) async {
    var result = accounts
    for (accountId, instrumentDeltas) in accountDeltas {
      result = result.adjustingPositions(of: accountId, by: instrumentDeltas)
    }
    accounts = result
    await recomputeConvertedTotals()
  }

  // MARK: - Mutations

  func create(_ account: Account, openingBalance: InstrumentAmount? = nil) async throws -> Account {
    isLoading = true
    error = nil

    // User-driven creation defaults investment accounts to
    // `.calculatedFromTrades`. Migration paths write through
    // `AccountRepository.update`, not `create`, so existing rows are
    // unaffected. Callers that want the struct default explicitly pass
    // `valuationMode: .recordedValue`; that input is preserved.
    var toCreate = account
    if toCreate.type == .investment && toCreate.valuationMode == .recordedValue {
      toCreate.valuationMode = .calculatedFromTrades
    }

    do {
      let created = try await repository.create(toCreate, openingBalance: openingBalance)

      // Optimistically add to local state
      accounts = Accounts(from: accounts.ordered + [created])
      logger.debug("Created account: \(created.name)")

      // Populate `convertedBalances` for the new account. Without this,
      // an account whose positions never differ from what `fetchAll`
      // returns (notably an empty investment account) would spin forever
      // in the sidebar, because `reloadFromSync` only recomputes when
      // fetched accounts differ from the local copy.
      await recomputeConvertedTotals()

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

      // Preload picks up snapshots for accounts whose mode changed to
      // `recordedValue`: without this, a flip from `calculatedFromTrades`
      // would leave `displayBalance` returning zero until CloudKit sync
      // delivered an unrelated refresh.
      await preloadInvestmentValues()
      await recomputeConvertedTotals()

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
    // Save previous state for rollback on failure.
    let previousAccounts = accounts
    error = nil

    // Optimistic local reorder so the UI reflects the new ordering immediately.
    var optimistic = accounts.ordered
    for (index, account) in reordered.enumerated() {
      guard let existingIndex = optimistic.firstIndex(where: { $0.id == account.id }) else {
        continue
      }
      optimistic[existingIndex].position = positionOffset + index
    }
    accounts = Accounts(from: optimistic)

    // Persist each reorder. Accumulate the first encountered error rather than
    // silently swallowing failures — partial failure leaves server state
    // inconsistent, so we must surface it and roll back.
    var firstError: Error?
    for (index, account) in reordered.enumerated() {
      var updated = account
      updated.position = positionOffset + index
      do {
        _ = try await repository.update(updated)
      } catch {
        logger.error("Failed to persist account reorder for \(updated.id): \(error)")
        if firstError == nil { firstError = error }
      }
    }

    if let firstError {
      // Roll back optimistic state and reload to reconcile with whatever did
      // persist on the server. Set the error AFTER reload, since load()
      // clears `error` at its start and would otherwise swallow the failure.
      accounts = previousAccounts
      await load()
      self.error = firstError
      return
    }

    // Success: reload to get authoritative state from the repository.
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
