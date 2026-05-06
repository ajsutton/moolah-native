import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class EarmarkStore {
  private(set) var earmarks = Earmarks(from: [])
  private(set) var error: Error?

  // Budget storage stays mutable from the `+Budget` extension; the
  // budget surface is still imperative (loadBudget / updateBudgetItem /
  // …) and pre-dates the reactive migration. Subsequent UI work will
  // adopt `repository.observeBudget(earmarkId:)`.
  var budgetItems: [EarmarkBudgetItem] = []
  var isBudgetLoading = false
  var budgetError: Error?

  private(set) var convertedTotalBalance: InstrumentAmount?
  private(set) var convertedBalances: [UUID: InstrumentAmount] = [:]
  private(set) var convertedSavedAmounts: [UUID: InstrumentAmount] = [:]
  private(set) var convertedSpentAmounts: [UUID: InstrumentAmount] = [:]

  // internal (not `private`) so the `+Budget` and `+Mutations` extensions
  // can reach the repository for budget CRUD and pass-through writes.
  let repository: EarmarkRepository
  private let conversionService: any InstrumentConversionService
  let targetInstrument: Instrument
  /// Delay between retry attempts after a conversion failure. Production
  /// uses ~30s; tests pass a small value to keep retries snappy.
  private let retryDelay: Duration
  // internal (not `private`) so the `+Budget` and `+Mutations` extensions
  // can log under the same subsystem/category.
  let logger = Logger(subsystem: "com.moolah.app", category: "EarmarkStore")

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
  /// assignment in `apply(earmarks:)` and after every recompute in
  /// `recomputeConvertedTotals()`. Tests use the
  /// `TestableStoreObservation` helpers in
  /// `MoolahTests/Support/TestableStoreObservation.swift` to await
  /// emissions deterministically. `internal` access is intentional;
  /// `@testable import Moolah` exposes it to the test target.
  let testObservationTickStream: AsyncStream<Void>
  private let testObservationTickContinuation: AsyncStream<Void>.Continuation

  init(
    repository: EarmarkRepository,
    conversionService: any InstrumentConversionService,
    targetInstrument: Instrument,
    retryDelay: Duration = .seconds(30)
  ) {
    self.repository = repository
    self.conversionService = conversionService
    self.targetInstrument = targetInstrument
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
    let earmarksStream = repository.observeAll()
    let earmarkErrors = repository.observeErrors()
    let rateStream = conversionService.observeRates()
    let rateErrors = conversionService.observeErrors()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { [self] in
        for await fresh in earmarksStream {
          await self.apply(earmarks: fresh)
        }
      }
      group.addTask { [self] in
        for await error in earmarkErrors {
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

  /// Applies a fresh earmarks snapshot from `observeAll()`. Wrapped in
  /// the Layer 7 signpost interval so benchmarks and Instruments traces
  /// can attribute `mainThreadMs` to this method. The nested
  /// `recomputeConvertedTotals` call has its own signpost; the outer
  /// interval includes both bodies.
  private func apply(earmarks fresh: [Earmark]) async {
    await withReactiveStoreSignpost("earmark-store-apply") {
      self.earmarks = Earmarks(from: fresh)
      await recomputeConvertedTotals()
      testObservationTickContinuation.yield(())
    }
  }

  private func surface(error: any Error) {
    logger.error("EarmarkStore observation error: \(error.localizedDescription)")
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

  func convertedBalance(for earmarkId: UUID) -> InstrumentAmount? {
    convertedBalances[earmarkId]
  }

  func convertedSaved(for earmarkId: UUID) -> InstrumentAmount? {
    convertedSavedAmounts[earmarkId]
  }

  func convertedSpent(for earmarkId: UUID) -> InstrumentAmount? {
    convertedSpentAmounts[earmarkId]
  }

  var showHidden: Bool = false

  var visibleEarmarks: [Earmark] {
    earmarks.filter { showHidden || !$0.isHidden }
  }

  /// Applies position deltas to earmark balances, saved, and spent.
  /// Used by `TransactionStore` to keep the sidebar fresh between a
  /// write and the next observation emission. The reactive observation
  /// will overwrite this state with authoritative GRDB content shortly
  /// after; the delta keeps the UI snappy in the interim.
  func applyDelta(
    earmarkDeltas: PositionDeltas,
    savedDeltas: PositionDeltas,
    spentDeltas: PositionDeltas
  ) async {
    var result = earmarks
    let allIds = Set(earmarkDeltas.keys).union(savedDeltas.keys).union(spentDeltas.keys)
    for earmarkId in allIds {
      result = result.adjustingPositions(
        of: earmarkId,
        positionDeltas: earmarkDeltas[earmarkId] ?? [:],
        savedDeltas: savedDeltas[earmarkId] ?? [:],
        spentDeltas: spentDeltas[earmarkId] ?? [:]
      )
    }
    earmarks = result
    await recomputeConvertedTotals()
  }

  /// Recompute per-earmark balances and the aggregate total. Driven by
  /// emissions from either `repository.observeAll()` (fresh data) or
  /// `conversionService.observeRates()` (rate changes). The first pass
  /// publishes inline. If the pass reports any conversion failure and
  /// no retry loop is already running, a `@MainActor` background retry
  /// is spawned that keeps attempting until everything succeeds.
  ///
  /// Conditional cancel: the retry is cancelled only on success.
  /// Leaving it running on repeat failure is intentional — every
  /// emission from either source would otherwise reset the clock and a
  /// profile with frequent unrelated rate ticks could delay recovery
  /// indefinitely.
  ///
  /// Each earmark is converted in isolation: a failure for one leaves
  /// other earmarks' balances populated. The aggregate
  /// `convertedTotalBalance` is only published when *all* contributing
  /// earmarks succeed (an inaccurate total is worse than no total).
  private func recomputeConvertedTotals() async {
    let anyFailed = await withReactiveStoreSignpost("earmark-store-recompute") {
      let failed = await runConversionAttempt()
      testObservationTickContinuation.yield(())
      return failed
    }
    if !anyFailed {
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
    // `self.conversionTask` and yields the test tick (both
    // MainActor-isolated). The annotation is required even though the
    // call site is already on `@MainActor` — future refactors that move
    // `recomputeConvertedTotals` off MainActor would silently introduce
    // a race without the explicit annotation.
    conversionTask = Task { @MainActor in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: delay)
        } catch {
          return  // CancellationError — exit the retry loop immediately
        }
        guard !Task.isCancelled else { return }
        let retryFailed = await self.runConversionAttempt()
        self.testObservationTickContinuation.yield(())
        if !retryFailed {
          self.conversionTask = nil
          return
        }
      }
    }
  }

  /// Awaits the background retry loop, if one is running. Only relevant
  /// after a first pass that hit a conversion failure — returns
  /// immediately when the store has no retry task pending. When a retry
  /// loop is running, this returns when it terminates (which happens
  /// only when a retry pass succeeds, or a new recompute cancels the
  /// loop).
  func waitForPendingConversions() async {
    guard let task = conversionTask else { return }
    await task.value
  }

  /// Single pass over all visible earmarks; returns `true` if any
  /// conversion failed. Always publishes the latest computed state,
  /// even if partial.
  private func runConversionAttempt() async -> Bool {
    var anyFailed = false
    var balances: [UUID: InstrumentAmount] = [:]
    var saved: [UUID: InstrumentAmount] = [:]
    var spent: [UUID: InstrumentAmount] = [:]
    var grandTotal = InstrumentAmount.zero(instrument: targetInstrument)
    var grandTotalValid = true
    let zeroInTarget = InstrumentAmount.zero(instrument: targetInstrument)

    for earmark in visibleEarmarks {
      do {
        let totals = try await convertEarmarkPositions(earmark)
        guard !Task.isCancelled else { return false }
        balances[earmark.id] = totals.balance
        saved[earmark.id] = totals.saved
        spent[earmark.id] = totals.spent

        // Convert earmark balance to target instrument for grand total.
        // Clamp negative balances to zero so they don't reduce the total.
        let convertedToTarget = try await conversionService.convertAmount(
          totals.balance, to: targetInstrument, on: Date())
        guard !Task.isCancelled else { return false }
        if grandTotalValid {
          grandTotal += max(convertedToTarget, zeroInTarget)
        }
      } catch {
        anyFailed = true
        grandTotalValid = false
        logger.warning(
          "Conversion failed for earmark \(earmark.name): \(error.localizedDescription)")
      }
    }

    guard !Task.isCancelled else { return false }

    convertedBalances = balances
    convertedSavedAmounts = saved
    convertedSpentAmounts = spent
    convertedTotalBalance = grandTotalValid ? grandTotal : nil

    return anyFailed
  }

  /// Per-earmark conversion result: the three position-list totals,
  /// each expressed in the earmark's own instrument.
  private struct ConvertedEarmarkTotals {
    let balance: InstrumentAmount
    let saved: InstrumentAmount
    let spent: InstrumentAmount
  }

  /// Sums an earmark's three position lists, each converted to the
  /// earmark's own instrument. `.knownZero` positions (an `.unpriced`
  /// / `.spam` crypto registration) contribute zero rather than
  /// failing the earmark — issue #790. A real provider failure still
  /// throws so the caller treats the whole earmark as failed (we never
  /// display a partial earmark balance under transient outage).
  private func convertEarmarkPositions(_ earmark: Earmark) async throws
    -> ConvertedEarmarkTotals
  {
    let date = Date()
    var balance = InstrumentAmount.zero(instrument: earmark.instrument)
    var saved = InstrumentAmount.zero(instrument: earmark.instrument)
    var spent = InstrumentAmount.zero(instrument: earmark.instrument)
    for position in earmark.positions {
      balance += try await convertPositionOrZero(
        position.amount, to: earmark.instrument, on: date)
    }
    for position in earmark.savedPositions {
      saved += try await convertPositionOrZero(
        position.amount, to: earmark.instrument, on: date)
    }
    for position in earmark.spentPositions {
      spent += try await convertPositionOrZero(
        position.amount, to: earmark.instrument, on: date)
    }
    return ConvertedEarmarkTotals(balance: balance, saved: saved, spent: spent)
  }

  /// Convert `amount` to `target` on `date`, folding `.knownZero` (an
  /// `.unpriced` / `.spam` crypto source) to zero in `target`.
  /// Issue #790.
  private func convertPositionOrZero(
    _ amount: InstrumentAmount, to target: Instrument, on date: Date
  ) async throws -> InstrumentAmount {
    let result = try await conversionService.convertResult(
      amount, to: target, on: date)
    switch result {
    case .value(let converted): return converted
    case .knownZero: return .zero(instrument: target)
    }
  }

  // Mutation methods live in `EarmarkStore+Mutations.swift`.
  // Budget CRUD lives in `EarmarkStore+Budget.swift`.

  /// Module-internal hook used by `EarmarkStore+Mutations.swift` to
  /// surface and reset the published `error` property. Lives here
  /// (rather than on the extension) because `error` is `private(set)`
  /// — the extension cannot mutate it directly.
  func setError(_ error: (any Error)?) {
    self.error = error
  }
}
