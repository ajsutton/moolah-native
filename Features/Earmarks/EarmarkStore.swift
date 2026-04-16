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
  private let conversionService: (any InstrumentConversionService)?
  let targetInstrument: Instrument
  private let logger = Logger(subsystem: "com.moolah.app", category: "EarmarkStore")
  private var conversionTask: Task<Void, Never>?

  init(
    repository: EarmarkRepository,
    conversionService: (any InstrumentConversionService)? = nil,
    targetInstrument: Instrument
  ) {
    self.repository = repository
    self.conversionService = conversionService
    self.targetInstrument = targetInstrument
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

  private func recomputeConvertedTotals() {
    conversionTask?.cancel()
    conversionTask = Task {
      do {
        var grandTotal = InstrumentAmount.zero(instrument: targetInstrument)
        var balances: [UUID: InstrumentAmount] = [:]
        var saved: [UUID: InstrumentAmount] = [:]
        var spent: [UUID: InstrumentAmount] = [:]

        for earmark in visibleEarmarks {
          var earmarkBalance = InstrumentAmount.zero(instrument: earmark.instrument)
          var earmarkSaved = InstrumentAmount.zero(instrument: earmark.instrument)
          var earmarkSpent = InstrumentAmount.zero(instrument: earmark.instrument)

          for position in earmark.positions {
            guard let conversionService else {
              earmarkBalance += position.amount
              continue
            }
            let converted = try await conversionService.convertAmount(
              position.amount, to: earmark.instrument, on: Date())
            guard !Task.isCancelled else { return }
            earmarkBalance += converted
          }
          for position in earmark.savedPositions {
            guard let conversionService else {
              earmarkSaved += position.amount
              continue
            }
            let converted = try await conversionService.convertAmount(
              position.amount, to: earmark.instrument, on: Date())
            guard !Task.isCancelled else { return }
            earmarkSaved += converted
          }
          for position in earmark.spentPositions {
            guard let conversionService else {
              earmarkSpent += position.amount
              continue
            }
            let converted = try await conversionService.convertAmount(
              position.amount, to: earmark.instrument, on: Date())
            guard !Task.isCancelled else { return }
            earmarkSpent += converted
          }

          balances[earmark.id] = earmarkBalance
          saved[earmark.id] = earmarkSaved
          spent[earmark.id] = earmarkSpent

          // Convert earmark balance to target instrument for grand total.
          // Clamp negative balances to zero so they don't reduce the total.
          let zeroInTarget = InstrumentAmount.zero(instrument: targetInstrument)
          if let conversionService {
            let convertedToTarget = try await conversionService.convertAmount(
              earmarkBalance, to: targetInstrument, on: Date())
            guard !Task.isCancelled else { return }
            grandTotal += max(convertedToTarget, zeroInTarget)
          } else {
            grandTotal += max(earmarkBalance, zeroInTarget)
          }
        }

        convertedBalances = balances
        convertedSavedAmounts = saved
        convertedSpentAmounts = spent
        convertedTotalBalance = grandTotal
      } catch {
        guard !Task.isCancelled else { return }
        logger.error("Failed to compute converted earmark totals: \(error.localizedDescription)")
      }
    }
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
      return updated
    } catch {
      logger.error("Failed to update earmark: \(error.localizedDescription)")
      self.error = error
      return nil
    }
  }
}
