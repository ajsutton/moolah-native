import Foundation
import Testing

@testable import Moolah

@Suite("AnalysisStore — categoriesOverTime")
@MainActor
struct AnalysisStoreCategoriesOverTimeTests {

  private func amt(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: .defaultTestInstrument)
  }

  @Test
  func emptyBreakdownReturnsNoEntries() {
    let result = AnalysisStore.buildCategoriesOverTime(
      from: [], categories: Categories(from: []))
    #expect(result.isEmpty)
  }

  @Test
  func singleCategorySingleMonth() {
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202604",
        totalExpenses: amt(Decimal(-100)))
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 1)
    #expect(result[0].categoryId == catId)
    #expect(result[0].points.count == 1)
    #expect(result[0].points[0].actualAmount == Decimal(100))
    #expect(result[0].points[0].percentage == 100.0)
  }

  @Test
  func multipleCategoriesPercentageComputation() {
    let cat1 = UUID()
    let cat2 = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: cat1, month: "202604",
        totalExpenses: amt(Decimal(-750))),
      ExpenseBreakdown(
        categoryId: cat2, month: "202604",
        totalExpenses: amt(Decimal(-250))),
    ]
    let categories = Categories(from: [
      Category(id: cat1, name: "Groceries"),
      Category(id: cat2, name: "Transport"),
    ])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 2)
    #expect(result[0].categoryId == cat1)
    #expect(result[0].points[0].percentage == 75.0)
    #expect(result[1].categoryId == cat2)
    #expect(result[1].points[0].percentage == 25.0)
  }

  @Test
  func subcategoriesRollUpToRootLevel() {
    let rootId = UUID()
    let childId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: rootId, month: "202604",
        totalExpenses: amt(Decimal(-300))),
      ExpenseBreakdown(
        categoryId: childId, month: "202604",
        totalExpenses: amt(Decimal(-200))),
    ]
    let categories = Categories(from: [
      Category(id: rootId, name: "Food"),
      Category(id: childId, name: "Groceries", parentId: rootId),
    ])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 1)
    #expect(result[0].categoryId == rootId)
    #expect(result[0].points[0].actualAmount == Decimal(500))
  }

  @Test
  func multipleMonthsOrdered() {
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202606",
        totalExpenses: amt(Decimal(-100))),
      ExpenseBreakdown(
        categoryId: catId, month: "202604",
        totalExpenses: amt(Decimal(-200))),
      ExpenseBreakdown(
        categoryId: catId, month: "202605",
        totalExpenses: amt(Decimal(-150))),
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 1)
    #expect(result[0].points.count == 3)
    #expect(result[0].points[0].month == "202604")
    #expect(result[0].points[1].month == "202605")
    #expect(result[0].points[2].month == "202606")
  }

  @Test
  func uncategorizedExpensesHandled() {
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202604",
        totalExpenses: amt(Decimal(-600))),
      ExpenseBreakdown(
        categoryId: nil, month: "202604",
        totalExpenses: amt(Decimal(-400))),
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 2)
    let uncategorized = result.first { $0.categoryId == nil }
    #expect(uncategorized != nil)
    #expect(uncategorized?.points[0].actualAmount == Decimal(400))
    #expect(uncategorized?.points[0].percentage == 40.0)
  }

  @Test
  func positiveExpenseValuesClampsToZero() {
    // If server somehow returns positive expenses, they negate to negative
    // and get clamped to 0 (matching web app's Math.max(0, ...) behavior)
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202604",
        totalExpenses: amt(Decimal(100)))
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 1)
    #expect(result[0].points[0].actualAmount == 0)
    #expect(result[0].points[0].percentage == 0.0)
  }

  @Test
  func allZeroMonthsHandled() {
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202604",
        totalExpenses: amt(0))
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 1)
    #expect(result[0].points[0].actualAmount == 0)
    #expect(result[0].points[0].percentage == 0.0)
  }
}
