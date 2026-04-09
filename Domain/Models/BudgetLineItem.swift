import Foundation

struct BudgetLineItem: Identifiable, Sendable {
  let id: UUID
  let categoryName: String
  let actual: MonetaryAmount
  let budgeted: MonetaryAmount

  var remaining: MonetaryAmount { budgeted + actual }

  /// Merges budget items with category expense balances into a sorted list of line items.
  static func buildLineItems(
    budgetItems: [EarmarkBudgetItem],
    categoryBalances: [UUID: MonetaryAmount],
    categories: Categories
  ) -> [BudgetLineItem] {
    var seen = Set<UUID>()
    var result: [BudgetLineItem] = []

    // Add all budgeted categories
    for item in budgetItems {
      seen.insert(item.categoryId)
      let name = categories.by(id: item.categoryId)?.name ?? "Unknown"
      let actual = categoryBalances[item.categoryId] ?? .zero(currency: item.amount.currency)
      result.append(
        BudgetLineItem(
          id: item.categoryId,
          categoryName: name,
          actual: actual,
          budgeted: item.amount
        ))
    }

    // Add categories with spending but no budget
    for (categoryId, actual) in categoryBalances where !seen.contains(categoryId) {
      let name = categories.by(id: categoryId)?.name ?? "Unknown"
      result.append(
        BudgetLineItem(
          id: categoryId,
          categoryName: name,
          actual: actual,
          budgeted: .zero(currency: actual.currency)
        ))
    }

    return result.sorted { $0.categoryName < $1.categoryName }
  }

  /// Calculates the unallocated portion of a savings goal.
  /// Returns nil if there is no savings goal.
  static func unallocatedAmount(
    budgetItems: [EarmarkBudgetItem],
    savingsGoal: MonetaryAmount?
  ) -> MonetaryAmount? {
    guard let goal = savingsGoal, goal.isPositive else { return nil }
    let totalBudget = budgetItems.reduce(MonetaryAmount.zero(currency: goal.currency)) {
      $0 + $1.amount
    }
    return goal - totalBudget
  }
}
