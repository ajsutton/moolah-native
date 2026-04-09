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

  private let repository: EarmarkRepository
  private let logger = Logger(subsystem: "com.moolah.app", category: "EarmarkStore")

  init(repository: EarmarkRepository) {
    self.repository = repository
  }

  func load() async {
    guard !isLoading else { return }

    logger.debug("Loading earmarks...")
    isLoading = true
    error = nil

    do {
      earmarks = Earmarks(from: try await repository.fetchAll())
      logger.debug("Loaded \(self.earmarks.count) earmarks")
    } catch {
      logger.error("Failed to load earmarks: \(error.localizedDescription)")
      self.error = error
    }

    isLoading = false
  }

  var visibleEarmarks: [Earmark] {
    earmarks.filter { !$0.isHidden }
  }

  var totalBalance: MonetaryAmount {
    visibleEarmarks.reduce(.zero) { $0 + $1.balance }
  }

  /// Adjusts earmark balances locally based on a transaction change.
  /// - Parameters:
  ///   - old: The previous transaction (nil for creates).
  ///   - new: The new transaction (nil for deletes).
  func applyTransactionDelta(old: Transaction?, new: Transaction?) {
    var updated = earmarks.ordered

    // Remove the old transaction's effect
    if let old, let earmarkId = old.earmarkId {
      // Reverse the effect: remove from balance and reverse saved/spent
      updated = updated.map { earmark in
        guard earmark.id == earmarkId else { return earmark }
        var copy = earmark
        copy.balance = copy.balance - old.amount
        if old.amount.cents > 0 {
          // Was income, decrease saved
          copy.saved = copy.saved - old.amount
        } else {
          // Was expense, decrease spent
          let absAmount = MonetaryAmount(
            cents: abs(old.amount.cents), currency: old.amount.currency)
          copy.spent = copy.spent - absAmount
        }
        return copy
      }
    }

    // Apply the new transaction's effect
    if let new, let earmarkId = new.earmarkId {
      updated = updated.map { earmark in
        guard earmark.id == earmarkId else { return earmark }
        var copy = earmark
        copy.balance = copy.balance + new.amount
        if new.amount.cents > 0 {
          // Is income, increase saved
          copy.saved = copy.saved + new.amount
        } else {
          // Is expense, increase spent
          let absAmount = MonetaryAmount(
            cents: abs(new.amount.cents), currency: new.amount.currency)
          copy.spent = copy.spent + absAmount
        }
        return copy
      }
    }

    earmarks = Earmarks(from: updated)
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
    earmarkId: UUID, categoryId: UUID, amount: MonetaryAmount
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
        earmarkId: earmarkId, categoryId: categoryId, amount: amount.cents)
    } catch {
      logger.error("Failed to update budget item: \(error.localizedDescription)")
      budgetItems = oldItems
      budgetError = error
    }
  }

  func addBudgetItem(
    earmarkId: UUID, categoryId: UUID, amount: MonetaryAmount
  ) async {
    let newItem = EarmarkBudgetItem(categoryId: categoryId, amount: amount)
    let oldItems = budgetItems
    budgetItems.append(newItem)

    do {
      try await repository.setBudget(
        earmarkId: earmarkId, categoryId: categoryId, amount: amount.cents)
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
        earmarkId: earmarkId, categoryId: categoryId, amount: 0)
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
