import Foundation
import Testing

@testable import Moolah

// MARK: - BudgetLineItem Merge Logic

@Suite("BudgetLineItem Merge")
struct BudgetLineItemMergeTests {
  @Test
  func testMergeCombinesBudgetAndActuals() {
    let catId = UUID()
    let categories = Categories(from: [Category(id: catId, name: "Flights")])
    let budgetItems = [
      EarmarkBudgetItem(
        categoryId: catId,
        amount: InstrumentAmount(
          quantity: Decimal(80000) / 100, instrument: Instrument.defaultTestInstrument))
    ]
    let categoryBalances: [UUID: InstrumentAmount] = [
      catId: InstrumentAmount(
        quantity: Decimal(-50000) / 100, instrument: Instrument.defaultTestInstrument)
    ]

    let result = BudgetLineItem.buildLineItems(
      budgetItems: budgetItems,
      categoryBalances: categoryBalances,
      categories: categories,
      earmarkInstrument: .defaultTestInstrument
    )

    #expect(result.count == 1)
    #expect(result.first?.categoryPath == "Flights")
    #expect(result.first?.actual.quantity == Decimal(-50000) / 100)
    #expect(result.first?.budgeted.quantity == Decimal(80000) / 100)
    #expect(result.first?.remaining.quantity == Decimal(30000) / 100)
  }

  @Test
  func testMergeIncludesBudgetOnlyCategories() {
    let catId = UUID()
    let categories = Categories(from: [Category(id: catId, name: "Food")])
    let budgetItems = [
      EarmarkBudgetItem(
        categoryId: catId,
        amount: InstrumentAmount(
          quantity: Decimal(30000) / 100, instrument: Instrument.defaultTestInstrument))
    ]
    let categoryBalances: [UUID: InstrumentAmount] = [:]

    let result = BudgetLineItem.buildLineItems(
      budgetItems: budgetItems,
      categoryBalances: categoryBalances,
      categories: categories,
      earmarkInstrument: .defaultTestInstrument
    )

    #expect(result.count == 1)
    #expect(result.first?.actual.quantity == Decimal(0))
    #expect(result.first?.remaining.quantity == Decimal(30000) / 100)
  }

  @Test
  func testMergeIncludesActualOnlyCategories() {
    let catId = UUID()
    let categories = Categories(from: [Category(id: catId, name: "Transport")])
    let budgetItems: [EarmarkBudgetItem] = []
    let categoryBalances: [UUID: InstrumentAmount] = [
      catId: InstrumentAmount(
        quantity: Decimal(-20000) / 100, instrument: Instrument.defaultTestInstrument)
    ]

    let result = BudgetLineItem.buildLineItems(
      budgetItems: budgetItems,
      categoryBalances: categoryBalances,
      categories: categories,
      earmarkInstrument: .defaultTestInstrument
    )

    #expect(result.count == 1)
    #expect(result.first?.budgeted.quantity == Decimal(0))
    #expect(result.first?.remaining.quantity == Decimal(-20000) / 100)
  }

  @Test
  func testMergeCalculatesRemainingCorrectly() {
    let catId = UUID()
    let categories = Categories(from: [Category(id: catId, name: "Accommodation")])
    let budgetItems = [
      EarmarkBudgetItem(
        categoryId: catId,
        amount: InstrumentAmount(
          quantity: Decimal(60000) / 100, instrument: Instrument.defaultTestInstrument))
    ]
    // Spending exceeds budget
    let categoryBalances: [UUID: InstrumentAmount] = [
      catId: InstrumentAmount(
        quantity: Decimal(-70000) / 100, instrument: Instrument.defaultTestInstrument)
    ]

    let result = BudgetLineItem.buildLineItems(
      budgetItems: budgetItems,
      categoryBalances: categoryBalances,
      categories: categories,
      earmarkInstrument: .defaultTestInstrument
    )

    // remaining = budget + actual = 60000 + (-70000) = -10000 (over budget)
    #expect(result.first?.remaining.quantity == Decimal(-10000) / 100)
  }

  @Test
  func testMergeSortsByCategoryPath() {
    let cat1 = Category(id: UUID(), name: "Zebra")
    let cat2 = Category(id: UUID(), name: "Alpha")
    let cat3 = Category(id: UUID(), name: "Middle")
    let categories = Categories(from: [cat1, cat2, cat3])
    let budgetItems = [
      EarmarkBudgetItem(
        categoryId: cat1.id,
        amount: InstrumentAmount(
          quantity: Decimal(10000) / 100, instrument: Instrument.defaultTestInstrument)),
      EarmarkBudgetItem(
        categoryId: cat2.id,
        amount: InstrumentAmount(
          quantity: Decimal(20000) / 100, instrument: Instrument.defaultTestInstrument)),
      EarmarkBudgetItem(
        categoryId: cat3.id,
        amount: InstrumentAmount(
          quantity: Decimal(30000) / 100, instrument: Instrument.defaultTestInstrument)),
    ]

    let result = BudgetLineItem.buildLineItems(
      budgetItems: budgetItems,
      categoryBalances: [:],
      categories: categories,
      earmarkInstrument: .defaultTestInstrument
    )

    #expect(result.map(\.categoryPath) == ["Alpha", "Middle", "Zebra"])
  }

  @Test
  func testUnallocatedBudgetCalculation() {
    let catId = UUID()
    let budgetItems = [
      EarmarkBudgetItem(
        categoryId: catId,
        amount: InstrumentAmount(
          quantity: Decimal(70000) / 100, instrument: Instrument.defaultTestInstrument))
    ]
    let savingsGoal = InstrumentAmount(
      quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument)

    let unallocated = BudgetLineItem.unallocatedAmount(
      budgetItems: budgetItems,
      savingsGoal: savingsGoal
    )

    // 100000 - 70000 = 30000
    #expect(unallocated?.quantity == Decimal(30000) / 100)
  }

  @Test
  func testUnallocatedNilWhenNoSavingsGoal() {
    let unallocated = BudgetLineItem.unallocatedAmount(
      budgetItems: [],
      savingsGoal: nil
    )
    #expect(unallocated == nil)
  }

  @Test
  func testUnallocatedNegativeWhenOverAllocated() {
    let catId = UUID()
    let budgetItems = [
      EarmarkBudgetItem(
        categoryId: catId,
        amount: InstrumentAmount(
          quantity: Decimal(120000) / 100, instrument: Instrument.defaultTestInstrument))
    ]
    let savingsGoal = InstrumentAmount(
      quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument)

    let unallocated = BudgetLineItem.unallocatedAmount(
      budgetItems: budgetItems,
      savingsGoal: savingsGoal
    )

    // 100000 - 120000 = -20000 (over-allocated)
    #expect(unallocated?.quantity == Decimal(-20000) / 100)
  }

  @Test
  func testUnknownCategoryNameForDeletedCategory() {
    let catId = UUID()
    let categories = Categories(from: [])  // Category not in lookup
    let budgetItems = [
      EarmarkBudgetItem(
        categoryId: catId,
        amount: InstrumentAmount(
          quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument))
    ]

    let result = BudgetLineItem.buildLineItems(
      budgetItems: budgetItems,
      categoryBalances: [:],
      categories: categories,
      earmarkInstrument: .defaultTestInstrument
    )

    #expect(result.first?.categoryPath == "Unknown")
  }

  @Test
  func testLineItemUsesFullCategoryPath() {
    let parentId = UUID()
    let childId = UUID()
    let categories = Categories(from: [
      Category(id: parentId, name: "Income"),
      Category(id: childId, name: "Salary", parentId: parentId),
    ])
    let budgetItems = [
      EarmarkBudgetItem(
        categoryId: childId,
        amount: InstrumentAmount(
          quantity: Decimal(10000) / 100, instrument: Instrument.defaultTestInstrument))
    ]

    let result = BudgetLineItem.buildLineItems(
      budgetItems: budgetItems,
      categoryBalances: [:],
      categories: categories,
      earmarkInstrument: .defaultTestInstrument
    )

    #expect(result.first?.categoryPath == "Income:Salary")
  }

  // MARK: - Budget item instrument parity

  @Test
  func budgetItemIsCoercedToEarmarkInstrumentInLineItem() {
    // Budget items stored with a mismatched instrument label (e.g. from stale
    // CloudKit data) are re-expressed in the earmark's instrument so sums
    // across the list are instrument-safe.
    let catId = UUID()
    let categories = Categories(from: [Category(id: catId, name: "Travel")])
    let budgetItems = [
      EarmarkBudgetItem(
        categoryId: catId,
        amount: InstrumentAmount(quantity: Decimal(500), instrument: .USD))
    ]

    let result = BudgetLineItem.buildLineItems(
      budgetItems: budgetItems,
      categoryBalances: [:],
      categories: categories,
      earmarkInstrument: .AUD
    )

    #expect(result.count == 1)
    #expect(result[0].budgeted.instrument == .AUD)
    #expect(result[0].budgeted.quantity == Decimal(500))
  }

  @Test
  func allLineItemsShareEarmarkInstrument() {
    let audCat = UUID()
    let usdCat = UUID()
    let categories = Categories(from: [
      Category(id: audCat, name: "Groceries"),
      Category(id: usdCat, name: "Subscriptions"),
    ])
    // Both budget items should land in the earmark's instrument even if the
    // records drifted in storage.
    let budgetItems = [
      EarmarkBudgetItem(
        categoryId: audCat,
        amount: InstrumentAmount(quantity: Decimal(200), instrument: .AUD)),
      EarmarkBudgetItem(
        categoryId: usdCat,
        amount: InstrumentAmount(quantity: Decimal(50), instrument: .USD)),
    ]

    let result = BudgetLineItem.buildLineItems(
      budgetItems: budgetItems,
      categoryBalances: [:],
      categories: categories,
      earmarkInstrument: .AUD
    )

    #expect(result.count == 2)
    let audLine = result.first { $0.id == audCat }
    let usdLine = result.first { $0.id == usdCat }
    #expect(audLine?.budgeted.instrument == .AUD)
    #expect(usdLine?.budgeted.instrument == .AUD)
  }
}
