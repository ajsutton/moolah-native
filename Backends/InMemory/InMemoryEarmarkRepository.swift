import Foundation

actor InMemoryEarmarkRepository: EarmarkRepository {
  private var earmarks: [UUID: Earmark]
  private var budgets: [UUID: [EarmarkBudgetItem]]
  private let currency: Currency

  init(initialEarmarks: [Earmark] = [], currency: Currency = .AUD) {
    self.earmarks = Dictionary(uniqueKeysWithValues: initialEarmarks.map { ($0.id, $0) })
    self.budgets = [:]
    self.currency = currency
  }

  func fetchAll() async throws -> [Earmark] {
    return Array(earmarks.values).sorted()
  }

  func create(_ earmark: Earmark) async throws -> Earmark {
    earmarks[earmark.id] = earmark
    return earmark
  }

  func update(_ earmark: Earmark) async throws -> Earmark {
    guard earmarks[earmark.id] != nil else {
      throw BackendError.serverError(404)
    }
    earmarks[earmark.id] = earmark
    return earmark
  }

  func fetchBudget(earmarkId: UUID) async throws -> [EarmarkBudgetItem] {
    return budgets[earmarkId] ?? []
  }

  func setBudget(earmarkId: UUID, categoryId: UUID, amount: Int) async throws {
    guard earmarks[earmarkId] != nil else {
      throw BackendError.serverError(404)
    }
    var items = budgets[earmarkId] ?? []
    if amount == 0 {
      items.removeAll { $0.categoryId == categoryId }
    } else if let index = items.firstIndex(where: { $0.categoryId == categoryId }) {
      items[index].amount = MonetaryAmount(cents: amount, currency: currency)
    } else {
      items.append(
        EarmarkBudgetItem(
          categoryId: categoryId,
          amount: MonetaryAmount(cents: amount, currency: currency)
        ))
    }
    budgets[earmarkId] = items
  }

  /// Replace or remove budget items referencing a deleted category.
  /// Matches server behavior: UPDATE IGNORE + DELETE for the old category.
  func replaceCategoryInBudgets(_ oldCategoryId: UUID, with newCategoryId: UUID?) {
    for (earmarkId, var items) in budgets {
      if let newCategoryId {
        // Replace old category with new one, but if new already exists, drop the old entry
        let hasNew = items.contains { $0.categoryId == newCategoryId }
        if hasNew {
          items.removeAll { $0.categoryId == oldCategoryId }
        } else {
          items = items.map { item in
            guard item.categoryId == oldCategoryId else { return item }
            return EarmarkBudgetItem(id: item.id, categoryId: newCategoryId, amount: item.amount)
          }
        }
      } else {
        items.removeAll { $0.categoryId == oldCategoryId }
      }
      budgets[earmarkId] = items
    }
  }

  // For test setup
  func setEarmarks(_ earmarks: [Earmark]) {
    self.earmarks = Dictionary(uniqueKeysWithValues: earmarks.map { ($0.id, $0) })
  }
}
