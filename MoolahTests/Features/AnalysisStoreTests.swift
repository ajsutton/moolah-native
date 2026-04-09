import Foundation
import Testing

@testable import Moolah

@Suite("AnalysisStore — categoriesOverTime")
@MainActor
struct AnalysisStoreCategoriesOverTimeTests {

  @Test func emptyBreakdownReturnsNoEntries() {
    let result = AnalysisStore.buildCategoriesOverTime(
      from: [], categories: Categories(from: []))
    #expect(result.isEmpty)
  }

  @Test func singleCategorySingleMonth() {
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202604",
        totalExpenses: MonetaryAmount(cents: -10000, currency: .defaultCurrency))
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 1)
    #expect(result[0].categoryId == catId)
    #expect(result[0].points.count == 1)
    #expect(result[0].points[0].actualCents == 10000)
    #expect(result[0].points[0].percentage == 100.0)
  }

  @Test func multipleCategoriesPercentageComputation() {
    let cat1 = UUID()
    let cat2 = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: cat1, month: "202604",
        totalExpenses: MonetaryAmount(cents: -75000, currency: .defaultCurrency)),
      ExpenseBreakdown(
        categoryId: cat2, month: "202604",
        totalExpenses: MonetaryAmount(cents: -25000, currency: .defaultCurrency)),
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

  @Test func subcategoriesRollUpToRootLevel() {
    let rootId = UUID()
    let childId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: rootId, month: "202604",
        totalExpenses: MonetaryAmount(cents: -30000, currency: .defaultCurrency)),
      ExpenseBreakdown(
        categoryId: childId, month: "202604",
        totalExpenses: MonetaryAmount(cents: -20000, currency: .defaultCurrency)),
    ]
    let categories = Categories(from: [
      Category(id: rootId, name: "Food"),
      Category(id: childId, name: "Groceries", parentId: rootId),
    ])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 1)
    #expect(result[0].categoryId == rootId)
    #expect(result[0].points[0].actualCents == 50000)
  }

  @Test func multipleMonthsOrdered() {
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202606",
        totalExpenses: MonetaryAmount(cents: -10000, currency: .defaultCurrency)),
      ExpenseBreakdown(
        categoryId: catId, month: "202604",
        totalExpenses: MonetaryAmount(cents: -20000, currency: .defaultCurrency)),
      ExpenseBreakdown(
        categoryId: catId, month: "202605",
        totalExpenses: MonetaryAmount(cents: -15000, currency: .defaultCurrency)),
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

  @Test func uncategorizedExpensesHandled() {
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202604",
        totalExpenses: MonetaryAmount(cents: -60000, currency: .defaultCurrency)),
      ExpenseBreakdown(
        categoryId: nil, month: "202604",
        totalExpenses: MonetaryAmount(cents: -40000, currency: .defaultCurrency)),
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 2)
    let uncategorized = result.first { $0.categoryId == nil }
    #expect(uncategorized != nil)
    #expect(uncategorized?.points[0].actualCents == 40000)
    #expect(uncategorized?.points[0].percentage == 40.0)
  }

  @Test func positiveExpenseValuesClampsToZero() {
    // If server somehow returns positive expenses, they negate to negative
    // and get clamped to 0 (matching web app's Math.max(0, ...) behavior)
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202604",
        totalExpenses: MonetaryAmount(cents: 10000, currency: .defaultCurrency))
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 1)
    #expect(result[0].points[0].actualCents == 0)
    #expect(result[0].points[0].percentage == 0.0)
  }

  @Test func allZeroMonthsHandled() {
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202604",
        totalExpenses: MonetaryAmount(cents: 0, currency: .defaultCurrency))
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 1)
    #expect(result[0].points[0].actualCents == 0)
    #expect(result[0].points[0].percentage == 0.0)
  }
}
