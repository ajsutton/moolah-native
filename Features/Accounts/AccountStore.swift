import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class AccountStore {
  private(set) var accounts = Accounts(from: [])
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
  /// Read-through cache of externally-set investment values. `internal`
  /// (rather than `private`) so the `+ConvertedTotals.swift` extension
  /// file can pass it to the balance calculator without a wrapper.
  let investmentValueCache: InvestmentValueCache
  /// `internal` so the `+ConvertedTotals.swift` extension can call the
  /// calculator directly. Stays `let` — mutating it externally would
  /// invalidate the retry loop's invariants.
  let balanceCalculator: AccountBalanceCalculator
  /// Delay between retry attempts after a conversion failure. Production
  /// uses ~30s; tests pass a small value to keep retries snappy.
  private let retryDelay: Duration
  private let logger = Logger(subsystem: "com.moolah.app", category: "AccountStore")

  /// The single observation `Task` that runs the `withTaskGroup` of
  /// child tasks subscribing to `repository.observeAll()`,
  /// `repository.observeErrors()`, `conversionService.observeRates()`,
  /// and `conversionService.observeErrors()`. Spawned from `init`,
  /// torn down by `stopObserving()` (called from
  /// `ProfileSession.cleanupSync`) or by `deinit` as a safety net.
  private var observationTask: Task<Void, Never>?

  /// Background retry loop spawned by `recomputeConvertedTotals()` when
  /// a conversion pass reports any failure. Cancelled when a subsequent
  /// pass succeeds; otherwise continues until success or the store is
  /// torn down. See the conditional-cancel pattern below.
  private var conversionTask: Task<Void, Never>?

  /// Test-only emission tick stream. Yields `()` after every state
  /// assignment in `apply(accounts:)` and after every recompute in
  /// `recomputeConvertedTotals()`. Tests use the
  /// `TestableStoreObservation` helpers in
  /// `MoolahTests/Support/TestableStoreObservation.swift` to await
  /// emissions deterministically. `internal` access is intentional;
  /// `@testable import Moolah` exposes it to the test target.
  let testObservationTickStream: AsyncStream<Void>
  private let testObservationTickContinuation: AsyncStream<Void>.Continuation

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
    let pair = AsyncStream<Void>.makeStream()
    self.testObservationTickStream = pair.stream
    self.testObservationTickContinuation = pair.continuation

    // Strong `self` capture is intentional: the store is `@MainActor`,
    // the task already holds an implicit strong reference, and
    // `stopObserving()` (called from `cleanupSync`) is the sole lifetime
    // gate. A weak capture would just add a nil-check hazard without
    // preventing the retain — and `guard let self else { return }` would
    // mask cancellation-propagation bugs by silently exiting.
    observationTask = Task { await self.observe() }
  }

  deinit {
    // Safety net for the case where `cleanupSync` is missed (e.g. an
    // early-error tear-down path that drops the ProfileSession without
    // calling cleanupSync). Cancels the strongly-held observation Task
    // so it does not retain `self` and a stale GRDB connection forever.
    // Under normal lifecycle, `stopObserving()` runs first via
    // `cleanupSync` and this is a no-op. Swift 6 makes `deinit`
    // nonisolated; reading `@MainActor`-isolated state requires
    // `MainActor.assumeIsolated`. The store is owned by main-actor
    // code (`ProfileSession`), so the assumption holds in practice.
    MainActor.assumeIsolated {
      observationTask?.cancel()
      conversionTask?.cancel()
      testObservationTickContinuation.finish()
    }
  }

  /// Subscribes to the four reactive streams in parallel via a
  /// `TaskGroup`. The child tasks run nonisolated; each per-emission
  /// body awaits a `@MainActor`-isolated method on `self` so state
  /// assignments happen on the main actor. Capturing the streams
  /// locally (instead of `self.repository.observeAll()` inside the
  /// `addTask` closure) lets the region-based isolation checker reason
  /// about Sendable-ness.
  private func observe() async {
    let accountsStream = repository.observeAll()
    let accountErrors = repository.observeErrors()
    let rateStream = conversionService.observeRates()
    let rateErrors = conversionService.observeErrors()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { [self] in
        for await fresh in accountsStream {
          await self.apply(accounts: fresh)
        }
      }
      group.addTask { [self] in
        for await error in accountErrors {
          await self.surface(error: error)
        }
      }
      group.addTask { [self] in
        for await _ in rateStream {
          await self.recomputeConvertedTotals()
        }
      }
      group.addTask { [self] in
        for await error in rateErrors {
          await self.surface(error: error)
        }
      }
      // Cancellation of `observationTask` cancels the group; the
      // `for await` loops exit; the group returns naturally.
    }
  }

  /// Applies a fresh accounts snapshot from `observeAll()`. Preloads
  /// investment values, then triggers a balance recompute. Both steps
  /// run on `@MainActor` so the publish order is deterministic.
  private func apply(accounts fresh: [Account]) async {
    self.accounts = Accounts(from: fresh)
    await preloadInvestmentValues()
    await recomputeConvertedTotals()
    testObservationTickContinuation.yield(())
  }

  private func surface(error: any Error) {
    logger.error("AccountStore observation error: \(error.localizedDescription)")
    self.error = error
  }

  /// Tears down the observation task. Idempotent. Called from
  /// `ProfileSession.cleanupSync(coordinator:)` AFTER any
  /// `deleteAllLocalData()` call so the empty-state transition is
  /// emitted to subscribed views before cancellation.
  func stopObserving() {
    observationTask?.cancel()
    observationTask = nil
    conversionTask?.cancel()
    conversionTask = nil
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
    accounts.filter { $0.type.isInvestmentLike && (showHidden || !$0.isHidden) }
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

  /// Whether the sidebar should show "Not set" instead of `$0` for an
  /// investment account in `.recordedValue` mode (no snapshot recorded;
  /// initial conversion already completed). See
  /// `INSTRUMENT_CONVERSION_GUIDE.md` Rule 11 — `$0` would otherwise roll
  /// into net-worth as a real number.
  func hasUnrecordedValue(_ account: Account) -> Bool {
    guard hasCompletedInitialConversion else { return false }
    guard account.type == .investment, account.valuationMode == .recordedValue else {
      return false
    }
    return investmentValueCache.value(for: account.id) == nil
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

  /// Recompute per-account balances and aggregate totals via
  /// `balanceCalculator`. Driven by emissions from either
  /// `repository.observeAll()` (fresh data) or
  /// `conversionService.observeRates()` (rate changes). The first pass
  /// publishes inline. If the pass reports any conversion failure and
  /// no retry loop is already running, a `@MainActor` background retry
  /// is spawned that keeps attempting until everything succeeds.
  ///
  /// Conditional cancel: the retry is cancelled only on success. Leaving
  /// it running on repeat failure is intentional — every emission from
  /// either source would otherwise reset the clock and a profile with
  /// frequent unrelated rate ticks could delay recovery indefinitely.
  private func recomputeConvertedTotals() async {
    let snapshot = await computeBalanceSnapshot()
    publishSnapshot(snapshot)
    testObservationTickContinuation.yield(())
    if !snapshot.anyFailed {
      // Success — kill any in-flight retry; nothing left to retry.
      conversionTask?.cancel()
      conversionTask = nil
      return
    }
    // Failure — start a retry only if one isn't already running.
    // Critical: the `guard conversionTask == nil else { return }` line
    // is load-bearing. Without it, every emission from observeRates()
    // (including writes for instruments unrelated to this profile) would
    // cancel and respawn the retry loop, resetting the wait clock and
    // potentially delaying recovery indefinitely.
    guard conversionTask == nil else { return }
    let delay = retryDelay
    // `Task { @MainActor in … }`: the closure mutates
    // `self.conversionTask` and calls `publishSnapshot` (both
    // MainActor-isolated). The annotation is required even though the
    // call site is already on `@MainActor` — future refactors that move
    // `recomputeConvertedTotals` off MainActor would silently introduce
    // a race without the explicit annotation.
    conversionTask = Task { @MainActor in
      while !Task.isCancelled {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }
        let retry = await self.computeBalanceSnapshot()
        self.publishSnapshot(retry)
        self.testObservationTickContinuation.yield(())
        if !retry.anyFailed {
          self.conversionTask = nil
          return
        }
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

  /// Applies position deltas to account balances. Used by
  /// `TransactionStore` to keep the sidebar fresh between a write and
  /// the next observation emission. The reactive observation will
  /// overwrite this state with authoritative GRDB content shortly
  /// after; the delta keeps the UI snappy in the interim.
  func applyDelta(_ accountDeltas: PositionDeltas) async {
    var result = accounts
    for (accountId, instrumentDeltas) in accountDeltas {
      result = result.adjustingPositions(of: accountId, by: instrumentDeltas)
    }
    accounts = result
    await recomputeConvertedTotals()
  }

  // Mutation methods live in `AccountStore+Mutations.swift`.

  /// Module-internal hook used by `AccountStore+Mutations.swift` to
  /// surface and reset the published `error` property. Lives here
  /// (rather than on the extension) because `error` is `private(set)`
  /// — the extension cannot mutate it directly.
  func setError(_ error: (any Error)?) {
    self.error = error
  }

  /// Module-internal helper for `AccountStore+Mutations.swift` to log
  /// against the shared logger.
  var mutationLogger: Logger { logger }

  /// Module-internal accessor for `AccountStore+Mutations.swift` to
  /// reach the underlying repository.
  var mutationRepository: AccountRepository { repository }
}
