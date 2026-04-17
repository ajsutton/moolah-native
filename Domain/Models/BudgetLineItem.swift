import Foundation

struct BudgetLineItem: Identifiable, Sendable {
  let id: UUID
  let categoryName: String
  let actual: InstrumentAmount
  let budgeted: InstrumentAmount

  var remaining: InstrumentAmount { budgeted + actual }

  /// Merges budget items with category expense balances into a sorted list of line items.
  ///
  /// All amounts must be expressed in `earmarkInstrument`. `buildLineItems` enforces
  /// this by coercing budget items and category balances onto the earmark's instrument,
  /// which is the required common denominator for sums across the list (see
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 1/2).
  static func buildLineItems(
    budgetItems: [EarmarkBudgetItem],
    categoryBalances: [UUID: InstrumentAmount],
    categories: Categories,
    earmarkInstrument: Instrument
  ) -> [BudgetLineItem] {
    var seen = Set<UUID>()
    var result: [BudgetLineItem] = []
    let zero = InstrumentAmount.zero(instrument: earmarkInstrument)

    // Add all budgeted categories
    for item in budgetItems {
      seen.insert(item.categoryId)
      let name = categories.by(id: item.categoryId)?.name ?? "Unknown"
      let budgeted = item.inInstrument(earmarkInstrument).amount
      let actual = categoryBalances[item.categoryId] ?? zero
      result.append(
        BudgetLineItem(
          id: item.categoryId,
          categoryName: name,
          actual: actual,
          budgeted: budgeted
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
          budgeted: zero
        ))
    }

    return result.sorted { $0.categoryName < $1.categoryName }
  }

  /// Calculates the unallocated portion of a savings goal.
  /// Returns nil if there is no savings goal.
  ///
  /// `Earmark.init` guarantees `savingsGoal.instrument == earmark.instrument`, and every
  /// `EarmarkBudgetItem` is stored in the earmark's instrument. Those invariants keep the
  /// reduction below instrument-safe (see `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 1/2).
  static func unallocatedAmount(
    budgetItems: [EarmarkBudgetItem],
    savingsGoal: InstrumentAmount?
  ) -> InstrumentAmount? {
    guard let goal = savingsGoal, goal.isPositive else { return nil }
    let totalBudget =
      budgetItems
      .map { $0.inInstrument(goal.instrument).amount }
      .reduce(InstrumentAmount.zero(instrument: goal.instrument)) { $0 + $1 }
    return goal - totalBudget
  }
}
