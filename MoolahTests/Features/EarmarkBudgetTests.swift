import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("EarmarkStore Budget")
@MainActor
struct EarmarkBudgetTests {
  private func makeStore(
    earmarks: [Earmark] = [],
    budgetItems: [UUID: [EarmarkBudgetItem]] = [:]
  ) async throws -> (EarmarkStore, CloudKitBackend) {
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: earmarks, in: container)
    for (earmarkId, items) in budgetItems {
      TestBackend.seedBudget(
        earmarkId: earmarkId, items: items, in: container)
    }
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)
    await store.load()
    return (store, backend)
  }

  // MARK: - loadBudget

  @Test func testLoadBudgetPopulatesBudgetItems() async throws {
    let earmarkId = UUID()
    let catId = UUID()
    let items = [
      EarmarkBudgetItem(
        categoryId: catId,
        amount: InstrumentAmount(
          quantity: Decimal(80000) / 100, instrument: Instrument.defaultTestInstrument))
    ]
    let (store, _) = try await makeStore(
      earmarks: [Earmark(id: earmarkId, name: "Holiday", instrument: .defaultTestInstrument)],
      budgetItems: [earmarkId: items]
    )

    await store.loadBudget(earmarkId: earmarkId)

    #expect(store.budgetItems.count == 1)
    #expect(store.budgetItems.first?.categoryId == catId)
    #expect(store.budgetItems.first?.amount.quantity == Decimal(80000) / 100)
  }

  @Test func testLoadBudgetHandlesError() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)
    // Loading budget for nonexistent earmark still returns empty
    await store.loadBudget(earmarkId: UUID())
    #expect(store.budgetItems.isEmpty)
  }

  @Test func testLoadBudgetClearsPreviousItems() async throws {
    let earmark1Id = UUID()
    let earmark2Id = UUID()
    let cat1Id = UUID()
    let cat2Id = UUID()
    let (store, _) = try await makeStore(
      earmarks: [
        Earmark(id: earmark1Id, name: "Holiday", instrument: .defaultTestInstrument),
        Earmark(id: earmark2Id, name: "Car", instrument: .defaultTestInstrument),
      ],
      budgetItems: [
        earmark1Id: [
          EarmarkBudgetItem(
            categoryId: cat1Id,
            amount: InstrumentAmount(
              quantity: Decimal(80000) / 100, instrument: Instrument.defaultTestInstrument))
        ],
        earmark2Id: [
          EarmarkBudgetItem(
            categoryId: cat2Id,
            amount: InstrumentAmount(
              quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument))
        ],
      ]
    )

    await store.loadBudget(earmarkId: earmark1Id)
    #expect(store.budgetItems.count == 1)
    #expect(store.budgetItems.first?.categoryId == cat1Id)

    await store.loadBudget(earmarkId: earmark2Id)
    #expect(store.budgetItems.count == 1)
    #expect(store.budgetItems.first?.categoryId == cat2Id)
  }

  // MARK: - updateBudgetItem

  @Test func testUpdateBudgetItemModifiesExistingItem() async throws {
    let earmarkId = UUID()
    let catId = UUID()
    let items = [
      EarmarkBudgetItem(
        categoryId: catId,
        amount: InstrumentAmount(
          quantity: Decimal(80000) / 100, instrument: Instrument.defaultTestInstrument))
    ]
    let (store, backend) = try await makeStore(
      earmarks: [Earmark(id: earmarkId, name: "Holiday", instrument: .defaultTestInstrument)],
      budgetItems: [earmarkId: items]
    )
    await store.loadBudget(earmarkId: earmarkId)

    await store.updateBudgetItem(
      earmarkId: earmarkId,
      categoryId: catId,
      amount: InstrumentAmount(
        quantity: Decimal(120000) / 100, instrument: Instrument.defaultTestInstrument)
    )

    #expect(store.budgetItems.first?.amount.quantity == Decimal(120000) / 100)

    // Verify repository state
    let persisted = try await backend.earmarks.fetchBudget(earmarkId: earmarkId)
    #expect(persisted.first?.amount.quantity == Decimal(120000) / 100)
  }

  // MARK: - addBudgetItem

  @Test func testAddBudgetItemAppendsToList() async throws {
    let earmarkId = UUID()
    let catId = UUID()
    let (store, _) = try await makeStore(
      earmarks: [Earmark(id: earmarkId, name: "Holiday", instrument: .defaultTestInstrument)]
    )
    await store.loadBudget(earmarkId: earmarkId)

    await store.addBudgetItem(
      earmarkId: earmarkId,
      categoryId: catId,
      amount: InstrumentAmount(
        quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument)
    )

    #expect(store.budgetItems.count == 1)
    #expect(store.budgetItems.first?.categoryId == catId)
  }

  @Test func testAddBudgetItemCallsRepositoryWithFullList() async throws {
    let earmarkId = UUID()
    let cat1Id = UUID()
    let cat2Id = UUID()
    let (store, backend) = try await makeStore(
      earmarks: [Earmark(id: earmarkId, name: "Holiday", instrument: .defaultTestInstrument)],
      budgetItems: [
        earmarkId: [
          EarmarkBudgetItem(
            categoryId: cat1Id,
            amount: InstrumentAmount(
              quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument))
        ]
      ]
    )
    await store.loadBudget(earmarkId: earmarkId)

    await store.addBudgetItem(
      earmarkId: earmarkId,
      categoryId: cat2Id,
      amount: InstrumentAmount(
        quantity: Decimal(30000) / 100, instrument: Instrument.defaultTestInstrument)
    )

    let persisted = try await backend.earmarks.fetchBudget(earmarkId: earmarkId)
    #expect(persisted.count == 2)
  }

  // MARK: - removeBudgetItem

  @Test func testRemoveBudgetItemRemovesFromList() async throws {
    let earmarkId = UUID()
    let catId = UUID()
    let (store, backend) = try await makeStore(
      earmarks: [Earmark(id: earmarkId, name: "Holiday", instrument: .defaultTestInstrument)],
      budgetItems: [
        earmarkId: [
          EarmarkBudgetItem(
            categoryId: catId,
            amount: InstrumentAmount(
              quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument))
        ]
      ]
    )
    await store.loadBudget(earmarkId: earmarkId)

    await store.removeBudgetItem(earmarkId: earmarkId, categoryId: catId)

    #expect(store.budgetItems.isEmpty)
    let persisted = try await backend.earmarks.fetchBudget(earmarkId: earmarkId)
    #expect(persisted.isEmpty)
  }
}

// MARK: - BudgetLineItem Merge Logic

@Suite("BudgetLineItem Merge")
struct BudgetLineItemMergeTests {
  @Test func testMergeCombinesBudgetAndActuals() {
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
      categories: categories
    )

    #expect(result.count == 1)
    #expect(result.first?.categoryName == "Flights")
    #expect(result.first?.actual.quantity == Decimal(-50000) / 100)
    #expect(result.first?.budgeted.quantity == Decimal(80000) / 100)
    #expect(result.first?.remaining.quantity == Decimal(30000) / 100)
  }

  @Test func testMergeIncludesBudgetOnlyCategories() {
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
      categories: categories
    )

    #expect(result.count == 1)
    #expect(result.first?.actual.quantity == Decimal(0))
    #expect(result.first?.remaining.quantity == Decimal(30000) / 100)
  }

  @Test func testMergeIncludesActualOnlyCategories() {
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
      categories: categories
    )

    #expect(result.count == 1)
    #expect(result.first?.budgeted.quantity == Decimal(0))
    #expect(result.first?.remaining.quantity == Decimal(-20000) / 100)
  }

  @Test func testMergeCalculatesRemainingCorrectly() {
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
      categories: categories
    )

    // remaining = budget + actual = 60000 + (-70000) = -10000 (over budget)
    #expect(result.first?.remaining.quantity == Decimal(-10000) / 100)
  }

  @Test func testMergeSortsByCategoryName() {
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
      categories: categories
    )

    #expect(result.map(\.categoryName) == ["Alpha", "Middle", "Zebra"])
  }

  @Test func testUnallocatedBudgetCalculation() {
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

  @Test func testUnallocatedNilWhenNoSavingsGoal() {
    let unallocated = BudgetLineItem.unallocatedAmount(
      budgetItems: [],
      savingsGoal: nil
    )
    #expect(unallocated == nil)
  }

  @Test func testUnallocatedNegativeWhenOverAllocated() {
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

  @Test func testUnknownCategoryNameForDeletedCategory() {
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
      categories: categories
    )

    #expect(result.first?.categoryName == "Unknown")
  }
}
