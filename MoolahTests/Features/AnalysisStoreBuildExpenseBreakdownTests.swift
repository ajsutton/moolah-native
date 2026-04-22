import Foundation
import Testing

@testable import Moolah

@Suite("AnalysisStore — buildExpenseBreakdown")
@MainActor
struct AnalysisStoreBuildExpenseBreakdownTests {

  private func amt(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: .defaultTestInstrument)
  }

  @Test func emptyBreakdownReturnsNoEntries() {
    let result = AnalysisStore.buildExpenseBreakdown(
      from: [], categories: Categories(from: []), selectedCategoryId: nil)
    #expect(result.isEmpty)
  }

  @Test func topLevelRollsUpChildIntoRoot() {
    // Repro: user reports a root category total does not include descendants.
    let foodId = UUID()
    let groceriesId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: foodId, month: "202604",
        totalExpenses: amt(Decimal(-100))),
      ExpenseBreakdown(
        categoryId: groceriesId, month: "202604",
        totalExpenses: amt(Decimal(-300))),
    ]
    let categories = Categories(from: [
      Category(id: foodId, name: "Food"),
      Category(id: groceriesId, name: "Groceries", parentId: foodId),
    ])

    let result = AnalysisStore.buildExpenseBreakdown(
      from: breakdown, categories: categories, selectedCategoryId: nil)

    #expect(result.count == 1)
    #expect(result[0].categoryId == foodId)
    #expect(result[0].totalExpenses.quantity == Decimal(400))
    #expect(result[0].percentage == 100.0)
  }

  @Test func topLevelRollsUpMultipleLevelsOfDescendants() {
    let foodId = UUID()
    let groceriesId = UUID()
    let organicId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: foodId, month: "202604",
        totalExpenses: amt(Decimal(-10))),
      ExpenseBreakdown(
        categoryId: groceriesId, month: "202604",
        totalExpenses: amt(Decimal(-20))),
      ExpenseBreakdown(
        categoryId: organicId, month: "202604",
        totalExpenses: amt(Decimal(-30))),
    ]
    let categories = Categories(from: [
      Category(id: foodId, name: "Food"),
      Category(id: groceriesId, name: "Groceries", parentId: foodId),
      Category(id: organicId, name: "Organic", parentId: groceriesId),
    ])

    let result = AnalysisStore.buildExpenseBreakdown(
      from: breakdown, categories: categories, selectedCategoryId: nil)

    #expect(result.count == 1)
    #expect(result[0].categoryId == foodId)
    #expect(result[0].totalExpenses.quantity == Decimal(60))
  }

  @Test func topLevelSortsByTotalDescending() {
    let foodId = UUID()
    let transportId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: foodId, month: "202604",
        totalExpenses: amt(Decimal(-200))),
      ExpenseBreakdown(
        categoryId: transportId, month: "202604",
        totalExpenses: amt(Decimal(-600))),
    ]
    let categories = Categories(from: [
      Category(id: foodId, name: "Food"),
      Category(id: transportId, name: "Transport"),
    ])

    let result = AnalysisStore.buildExpenseBreakdown(
      from: breakdown, categories: categories, selectedCategoryId: nil)

    #expect(result.count == 2)
    #expect(result[0].categoryId == transportId)
    #expect(result[0].percentage == 75.0)
    #expect(result[1].categoryId == foodId)
    #expect(result[1].percentage == 25.0)
  }

  @Test func topLevelIncludesUncategorized() {
    let foodId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: foodId, month: "202604",
        totalExpenses: amt(Decimal(-300))),
      ExpenseBreakdown(
        categoryId: nil, month: "202604",
        totalExpenses: amt(Decimal(-100))),
    ]
    let categories = Categories(from: [Category(id: foodId, name: "Food")])

    let result = AnalysisStore.buildExpenseBreakdown(
      from: breakdown, categories: categories, selectedCategoryId: nil)

    #expect(result.count == 2)
    let food = result.first { $0.categoryId == foodId }
    #expect(food?.totalExpenses.quantity == Decimal(300))
    let uncategorized = result.first { $0.categoryId == nil }
    #expect(uncategorized?.totalExpenses.quantity == Decimal(100))
  }

  @Test func drilledInShowsChildrenWithDescendantsRolledUp() {
    let foodId = UUID()
    let groceriesId = UUID()
    let organicId = UUID()
    let restaurantsId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: foodId, month: "202604",
        totalExpenses: amt(Decimal(-10))),
      ExpenseBreakdown(
        categoryId: groceriesId, month: "202604",
        totalExpenses: amt(Decimal(-20))),
      ExpenseBreakdown(
        categoryId: organicId, month: "202604",
        totalExpenses: amt(Decimal(-30))),
      ExpenseBreakdown(
        categoryId: restaurantsId, month: "202604",
        totalExpenses: amt(Decimal(-40))),
    ]
    let categories = Categories(from: [
      Category(id: foodId, name: "Food"),
      Category(id: groceriesId, name: "Groceries", parentId: foodId),
      Category(id: organicId, name: "Organic", parentId: groceriesId),
      Category(id: restaurantsId, name: "Restaurants", parentId: foodId),
    ])

    let result = AnalysisStore.buildExpenseBreakdown(
      from: breakdown, categories: categories, selectedCategoryId: foodId)

    // Groceries direct (20) + Organic (30) = 50; Restaurants = 40. Food-direct (10) excluded.
    #expect(result.count == 2)
    let groceries = result.first { $0.categoryId == groceriesId }
    #expect(groceries?.totalExpenses.quantity == Decimal(50))
    let restaurants = result.first { $0.categoryId == restaurantsId }
    #expect(restaurants?.totalExpenses.quantity == Decimal(40))
  }

  @Test func drilledInExcludesItemsOutsideSubtree() {
    let foodId = UUID()
    let groceriesId = UUID()
    let transportId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: groceriesId, month: "202604",
        totalExpenses: amt(Decimal(-100))),
      ExpenseBreakdown(
        categoryId: transportId, month: "202604",
        totalExpenses: amt(Decimal(-200))),
    ]
    let categories = Categories(from: [
      Category(id: foodId, name: "Food"),
      Category(id: groceriesId, name: "Groceries", parentId: foodId),
      Category(id: transportId, name: "Transport"),
    ])

    let result = AnalysisStore.buildExpenseBreakdown(
      from: breakdown, categories: categories, selectedCategoryId: foodId)

    #expect(result.count == 1)
    #expect(result[0].categoryId == groceriesId)
    #expect(result[0].totalExpenses.quantity == Decimal(100))
    #expect(result[0].percentage == 100.0)
  }

  @Test func multipleMonthsAccumulateIntoSameRollupTarget() {
    let foodId = UUID()
    let groceriesId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: groceriesId, month: "202604",
        totalExpenses: amt(Decimal(-100))),
      ExpenseBreakdown(
        categoryId: groceriesId, month: "202605",
        totalExpenses: amt(Decimal(-200))),
      ExpenseBreakdown(
        categoryId: foodId, month: "202605",
        totalExpenses: amt(Decimal(-50))),
    ]
    let categories = Categories(from: [
      Category(id: foodId, name: "Food"),
      Category(id: groceriesId, name: "Groceries", parentId: foodId),
    ])

    let result = AnalysisStore.buildExpenseBreakdown(
      from: breakdown, categories: categories, selectedCategoryId: nil)

    #expect(result.count == 1)
    #expect(result[0].categoryId == foodId)
    #expect(result[0].totalExpenses.quantity == Decimal(350))
  }

  @Test func positiveExpensesClampToZero() {
    // Server returns negative for expenses; positive values are refunds.
    // Matching web app's Math.max(0, ...) behavior, net-positive rollups clamp to zero.
    let foodId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: foodId, month: "202604",
        totalExpenses: amt(Decimal(100)))
    ]
    let categories = Categories(from: [Category(id: foodId, name: "Food")])

    let result = AnalysisStore.buildExpenseBreakdown(
      from: breakdown, categories: categories, selectedCategoryId: nil)

    #expect(result.count == 1)
    #expect(result[0].totalExpenses.quantity == 0)
    #expect(result[0].percentage == 0)
  }
}
