import Foundation

// Budget CRUD extracted from the main `EarmarkStore` body so it stays under
// SwiftLint's `type_body_length` threshold. All methods use the same
// optimistic-update-then-rollback pattern as the rest of the store.
extension EarmarkStore {

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

    // Setting amount to 0 removes the budget entry on the server. Use the
    // earmark's own instrument so the repository's instrument-parity guard
    // doesn't reject the zero write on a multi-currency profile.
    let zeroInstrument = earmarks.by(id: earmarkId)?.instrument ?? targetInstrument
    do {
      try await repository.setBudget(
        earmarkId: earmarkId, categoryId: categoryId, amount: .zero(instrument: zeroInstrument))
    } catch {
      logger.error("Failed to remove budget item: \(error.localizedDescription)")
      budgetItems = oldItems
      budgetError = error
    }
  }
}
