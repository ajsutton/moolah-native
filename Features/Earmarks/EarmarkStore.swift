import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class EarmarkStore {
  private(set) var earmarks: Earmarks = Earmarks(from: [])
  private(set) var isLoading = false
  private(set) var error: Error?

  private(set) var budgetItems: [EarmarkBudgetItem] = []
  private(set) var isBudgetLoading = false
  private(set) var budgetError: Error?

  private(set) var convertedTotalBalance: InstrumentAmount?
  private(set) var convertedBalances: [UUID: InstrumentAmount] = [:]
  private(set) var convertedSavedAmounts: [UUID: InstrumentAmount] = [:]
  private(set) var convertedSpentAmounts: [UUID: InstrumentAmount] = [:]

  private let repository: EarmarkRepository
  private let conversionService: any InstrumentConversionService
  let targetInstrument: Instrument
  /// Delay between retry attempts after a conversion failure. Production
  /// uses ~30s; tests pass a small value to keep retries snappy.
  private let retryDelay: Duration
  private let logger = Logger(subsystem: "com.moolah.app", category: "EarmarkStore")
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
      recomputeConvertedTotals()
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
        recomputeConvertedTotals()
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
  ) {
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
    recomputeConvertedTotals()
  }

  /// Recompute per-earmark balances and the aggregate total. Each earmark
  /// is converted in isolation: a failure for one leaves other earmarks'
  /// balances populated. The aggregate `convertedTotalBalance` is only
  /// published when *all* contributing earmarks succeed (an inaccurate
  /// total is worse than no total). On any failure, schedules a retry
  /// after `retryDelay` and keeps retrying until everything succeeds or a
  /// new recompute cancels this task.
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
        let (earmarkBalance, earmarkSaved, earmarkSpent) =
          try await convertEarmarkPositions(earmark)
        guard !Task.isCancelled else { return false }
        balances[earmark.id] = earmarkBalance
        saved[earmark.id] = earmarkSaved
        spent[earmark.id] = earmarkSpent

        // Convert earmark balance to target instrument for grand total.
        // Clamp negative balances to zero so they don't reduce the total.
        let convertedToTarget = try await conversionService.convertAmount(
          earmarkBalance, to: targetInstrument, on: Date())
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

  /// Sums an earmark's three position lists, each converted to the
  /// earmark's own instrument. Throws if any conversion fails so the
  /// caller treats the whole earmark as failed (we never display a
  /// partial earmark balance).
  private func convertEarmarkPositions(_ earmark: Earmark) async throws
    -> (
      balance: InstrumentAmount,
      saved: InstrumentAmount,
      spent: InstrumentAmount
    )
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
    return (balance, saved, spent)
  }

  func reorderEarmarks(from source: IndexSet, to destination: Int) async {
    var visible = visibleEarmarks
    visible.move(fromOffsets: source, toOffset: destination)

    for index in visible.indices {
      visible[index].position = index
      do {
        _ = try await repository.update(visible[index])
      } catch {
        logger.error("Failed to persist earmark reorder for \(visible[index].id): \(error)")
      }
    }

    let hiddenEarmarks = earmarks.ordered.filter { $0.isHidden }
    earmarks = Earmarks(from: visible + hiddenEarmarks)
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

  // MARK: - Budget

  func loadBudget(earmarkId: UUID) async {
    guard !isBudgetLoading else { return }
    isBudgetLoading = true
    budgetError = nil

    do {
      budgetItems = try await repository.fetchBudget(earmarkId: earmarkId)
    } catch {
      logger.error("Failed to load budget: \(error.localizedDescription)")
      budgetError = error
    }

    isBudgetLoading = false
  }

  func updateBudgetItem(
    earmarkId: UUID, categoryId: UUID, amount: InstrumentAmount
  ) async {
    let oldItems = budgetItems

    // Optimistic update
    budgetItems = budgetItems.map { item in
      guard item.categoryId == categoryId else { return item }
      var copy = item
      copy.amount = amount
      return copy
    }

    do {
      try await repository.setBudget(
        earmarkId: earmarkId, categoryId: categoryId, amount: amount)
    } catch {
      logger.error("Failed to update budget item: \(error.localizedDescription)")
      budgetItems = oldItems
      budgetError = error
    }
  }

  func addBudgetItem(
    earmarkId: UUID, categoryId: UUID, amount: InstrumentAmount
  ) async {
    let newItem = EarmarkBudgetItem(categoryId: categoryId, amount: amount)
    let oldItems = budgetItems
    budgetItems.append(newItem)

    do {
      try await repository.setBudget(
        earmarkId: earmarkId, categoryId: categoryId, amount: amount)
    } catch {
      logger.error("Failed to add budget item: \(error.localizedDescription)")
      budgetItems = oldItems
      budgetError = error
    }
  }

  func removeBudgetItem(earmarkId: UUID, categoryId: UUID) async {
    let oldItems = budgetItems
    budgetItems.removeAll { $0.categoryId == categoryId }

    do {
      // Setting amount to 0 removes the budget entry on the server
      try await repository.setBudget(
        earmarkId: earmarkId, categoryId: categoryId, amount: .zero(instrument: targetInstrument))
    } catch {
      logger.error("Failed to remove budget item: \(error.localizedDescription)")
      budgetItems = oldItems
      budgetError = error
    }
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
      recomputeConvertedTotals()
      return updated
    } catch {
      logger.error("Failed to update earmark: \(error.localizedDescription)")
      self.error = error
      return nil
    }
  }
}
