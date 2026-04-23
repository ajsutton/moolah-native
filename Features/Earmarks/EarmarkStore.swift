import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class EarmarkStore {
  private(set) var earmarks = Earmarks(from: [])
  private(set) var isLoading = false
  private(set) var error: Error?

  // Setter widened from `private(set)` to default (internal) so the
  // `+Budget` extension file can mutate these from budget CRUD. The
  // `private(set)` invariant still holds within this type for all
  // external consumers — only the sibling extension assigns.
  var budgetItems: [EarmarkBudgetItem] = []
  var isBudgetLoading = false
  var budgetError: Error?

  private(set) var convertedTotalBalance: InstrumentAmount?
  private(set) var convertedBalances: [UUID: InstrumentAmount] = [:]
  private(set) var convertedSavedAmounts: [UUID: InstrumentAmount] = [:]
  private(set) var convertedSpentAmounts: [UUID: InstrumentAmount] = [:]

  // internal (was private) so the `+Budget` extension file in the same module
  // can reach the repository for budget CRUD.
  let repository: EarmarkRepository
  private let conversionService: any InstrumentConversionService
  let targetInstrument: Instrument
  /// Delay between retry attempts after a conversion failure. Production
  /// uses ~30s; tests pass a small value to keep retries snappy.
  private let retryDelay: Duration
  // internal (was private) so the `+Budget` extension file can log under the
  // same subsystem/category.
  let logger = Logger(subsystem: "com.moolah.app", category: "EarmarkStore")
  private var conversionTask: Task<Void, Never>?

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

  func load() async {
    guard !isLoading else { return }

    logger.debug("Loading earmarks...")
    isLoading = true
    error = nil

    do {
      earmarks = Earmarks(from: try await repository.fetchAll())
      logger.debug("Loaded \(self.earmarks.count) earmarks")
      await recomputeConvertedTotals()
    } catch {
      logger.error("Failed to load earmarks: \(error.localizedDescription)")
      self.error = error
    }

    isLoading = false
  }

  /// Re-fetches earmarks without showing loading state or clearing errors.
  /// Used when CloudKit delivers remote changes — avoids UI flicker.
  func reloadFromSync() async {
    let start = ContinuousClock.now
    do {
      let fresh = Earmarks(from: try await repository.fetchAll())
      let elapsed = (ContinuousClock.now - start).inMilliseconds
      if fresh.ordered != earmarks.ordered {
        earmarks = fresh
        logger.debug("Sync: updated earmarks (\(fresh.count) earmarks) in \(elapsed)ms")
        await recomputeConvertedTotals()
      }
      if elapsed > 16 {
        logger.warning("⚠️ PERF: earmarkStore.reloadFromSync took \(elapsed)ms")
      }
    } catch {
      logger.error("Sync reload failed: \(error.localizedDescription)")
    }
  }

  var showHidden: Bool = false

  var visibleEarmarks: [Earmark] {
    earmarks.filter { showHidden || !$0.isHidden }
  }

  /// Applies position deltas to earmark balances, saved, and spent.
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

  /// Recompute per-earmark balances and the aggregate total. The first
  /// pass runs inline and is awaited by the caller, so observers see
  /// fully-published state the moment `load()`/`applyDelta` returns —
  /// no poll, no race. If the first pass hits any conversion failure,
  /// a background retry loop is spawned that keeps attempting until
  /// everything succeeds or a new recompute cancels it. Callers that
  /// want to await retry success use `waitForPendingConversions()`.
  ///
  /// Each earmark is converted in isolation: a failure for one leaves
  /// other earmarks' balances populated. The aggregate
  /// `convertedTotalBalance` is only published when *all* contributing
  /// earmarks succeed (an inaccurate total is worse than no total).
  private func recomputeConvertedTotals() async {
    conversionTask?.cancel()
    conversionTask = nil

    let anyFailed = await runConversionAttempt()
    guard anyFailed else { return }

    let delay = retryDelay
    // `[weak self]` so the retry loop doesn't pin the store alive when the
    // owning view goes away while conversions are still failing.
    conversionTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: delay)
        guard let self, !Task.isCancelled else { return }
        if !(await self.runConversionAttempt()) { return }
      }
    }
  }

  /// Awaits the background retry loop, if one is running. Only relevant
  /// after a first pass that hit a conversion failure — returns
  /// immediately when there is no retry task pending. When a retry loop
  /// is running, this returns when it terminates (on the first
  /// successful attempt, or when a new recompute cancels it).
  func waitForPendingConversions() async {
    guard let task = conversionTask else { return }
    await task.value
  }

  /// Single pass over all visible earmarks; returns `true` if any
  /// conversion failed. Always publishes the latest computed state, even
  /// if partial.
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
  /// earmark's own instrument. Throws if any conversion fails so the
  /// caller treats the whole earmark as failed (we never display a
  /// partial earmark balance).
  private func convertEarmarkPositions(_ earmark: Earmark) async throws
    -> ConvertedEarmarkTotals
  {
    let date = Date()
    var balance = InstrumentAmount.zero(instrument: earmark.instrument)
    var saved = InstrumentAmount.zero(instrument: earmark.instrument)
    var spent = InstrumentAmount.zero(instrument: earmark.instrument)
    for position in earmark.positions {
      balance += try await conversionService.convertAmount(
        position.amount, to: earmark.instrument, on: date)
    }
    for position in earmark.savedPositions {
      saved += try await conversionService.convertAmount(
        position.amount, to: earmark.instrument, on: date)
    }
    for position in earmark.spentPositions {
      spent += try await conversionService.convertAmount(
        position.amount, to: earmark.instrument, on: date)
    }
    return ConvertedEarmarkTotals(balance: balance, saved: saved, spent: spent)
  }

  /// Reorders the visible earmarks, persisting each new position to the
  /// repository. On any failure, rolls back local state, reloads from the
  /// repository to reconcile partial writes, and surfaces the error via
  /// `self.error`. Hidden earmarks keep their existing positions.
  func reorderEarmarks(from source: IndexSet, to destination: Int) async {
    // Save old state for rollback.
    let previousEarmarks = earmarks
    error = nil

    var visible = visibleEarmarks
    visible.move(fromOffsets: source, toOffset: destination)
    for index in visible.indices {
      visible[index].position = index
    }

    // Apply optimistic update so the UI reflects the new order immediately.
    let hiddenEarmarks = earmarks.ordered.filter { $0.isHidden }
    earmarks = Earmarks(from: visible + hiddenEarmarks)

    for earmark in visible {
      do {
        _ = try await repository.update(earmark)
      } catch {
        logger.error("Failed to persist earmark reorder for \(earmark.id): \(error)")
        // Rollback local state, then reload to reconcile any partial writes
        // already persisted to the backend before the failure. Use
        // `reloadFromSync` so it preserves `self.error` set below.
        earmarks = previousEarmarks
        await reloadFromSync()
        self.error = error
        return
      }
    }
  }

  func create(_ earmark: Earmark) async -> Earmark? {
    logger.debug("Creating earmark: \(earmark.name)")
    error = nil

    do {
      let created = try await repository.create(earmark)
      // Add the created earmark to local state instead of reloading
      var updated = earmarks.ordered
      updated.append(created)
      earmarks = Earmarks(from: updated)
      logger.debug("Added earmark to local state: \(created.name)")
      return created
    } catch {
      logger.error("Failed to create earmark: \(error.localizedDescription)")
      self.error = error
      return nil
    }
  }

  /// Marks an earmark as hidden so it no longer appears in default lists.
  @discardableResult
  func hide(_ earmark: Earmark) async -> Earmark? {
    var hidden = earmark
    hidden.isHidden = true
    return await update(hidden)
  }

  func update(_ earmark: Earmark) async -> Earmark? {
    logger.debug("Updating earmark: \(earmark.name)")
    error = nil

    do {
      let updated = try await repository.update(earmark)
      // Update the earmark in local state instead of reloading
      let updatedList = earmarks.ordered.map { existing in
        existing.id == updated.id ? updated : existing
      }
      earmarks = Earmarks(from: updatedList)
      logger.debug("Updated earmark in local state: \(updated.name)")
      // Rebuild converted balances — a changed instrument (or hidden flag)
      // requires re-expressing existing positions in the new display currency.
      await recomputeConvertedTotals()
      return updated
    } catch {
      logger.error("Failed to update earmark: \(error.localizedDescription)")
      self.error = error
      return nil
    }
  }
}
