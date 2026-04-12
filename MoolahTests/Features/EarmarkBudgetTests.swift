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
    let store = EarmarkStore(repository: backend.earmarks)
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
        amount: MonetaryAmount(cents: 80000, currency: Instrument.defaultTestInstrument))
    ]
    let (store, _) = try await makeStore(
      earmarks: [Earmark(id: earmarkId, name: "Holiday")],
      budgetItems: [earmarkId: items]
    )

    await store.loadBudget(earmarkId: earmarkId)

    #expect(store.budgetItems.count == 1)
    #expect(store.budgetItems.first?.categoryId == catId)
    #expect(store.budgetItems.first?.amount.cents == 80000)
  }

  @Test func testLoadBudgetHandlesError() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(repository: backend.earmarks)
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
        Earmark(id: earmark1Id, name: "Holiday"),
        Earmark(id: earmark2Id, name: "Car"),
      ],
      budgetItems: [
        earmark1Id: [
          EarmarkBudgetItem(
            categoryId: cat1Id,
            amount: MonetaryAmount(cents: 80000, currency: Instrument.defaultTestInstrument))
        ],
        earmark2Id: [
          EarmarkBudgetItem(
            categoryId: cat2Id,
            amount: MonetaryAmount(cents: 50000, currency: Instrument.defaultTestInstrument))
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
        amount: MonetaryAmount(cents: 80000, currency: Instrument.defaultTestInstrument))
    ]
    let (store, backend) = try await makeStore(
      earmarks: [Earmark(id: earmarkId, name: "Holiday")],
      budgetItems: [earmarkId: items]
    )
    await store.loadBudget(earmarkId: earmarkId)

    await store.updateBudgetItem(
      earmarkId: earmarkId,
      categoryId: catId,
      amount: MonetaryAmount(cents: 120000, currency: Instrument.defaultTestInstrument)
    )

    #expect(store.budgetItems.first?.amount.cents == 120000)

    // Verify repository state
    let persisted = try await backend.earmarks.fetchBudget(earmarkId: earmarkId)
    #expect(persisted.first?.amount.cents == 120000)
  }

  // MARK: - addBudgetItem

  @Test func testAddBudgetItemAppendsToList() async throws {
    let earmarkId = UUID()
    let catId = UUID()
    let (store, _) = try await makeStore(
      earmarks: [Earmark(id: earmarkId, name: "Holiday")]
    )
    await store.loadBudget(earmarkId: earmarkId)

    await store.addBudgetItem(
      earmarkId: earmarkId,
      categoryId: catId,
      amount: MonetaryAmount(cents: 50000, currency: Instrument.defaultTestInstrument)
    )

    #expect(store.budgetItems.count == 1)
    #expect(store.budgetItems.first?.categoryId == catId)
  }

  @Test func testAddBudgetItemCallsRepositoryWithFullList() async throws {
    let earmarkId = UUID()
    let cat1Id = UUID()
    let cat2Id = UUID()
    let (store, backend) = try await makeStore(
      earmarks: [Earmark(id: earmarkId, name: "Holiday")],
      budgetItems: [
        earmarkId: [
          EarmarkBudgetItem(
            categoryId: cat1Id,
            amount: MonetaryAmount(cents: 50000, currency: Instrument.defaultTestInstrument))
        ]
      ]
    )
    await store.loadBudget(earmarkId: earmarkId)

    await store.addBudgetItem(
      earmarkId: earmarkId,
      categoryId: cat2Id,
      amount: MonetaryAmount(cents: 30000, currency: Instrument.defaultTestInstrument)
    )

    let persisted = try await backend.earmarks.fetchBudget(earmarkId: earmarkId)
    #expect(persisted.count == 2)
  }

  // MARK: - removeBudgetItem

  @Test func testRemoveBudgetItemRemovesFromList() async throws {
    let earmarkId = UUID()
    let catId = UUID()
    let (store, backend) = try await makeStore(
      earmarks: [Earmark(id: earmarkId, name: "Holiday")],
      budgetItems: [
        earmarkId: [
          EarmarkBudgetItem(
            categoryId: catId,
            amount: MonetaryAmount(cents: 50000, currency: Instrument.defaultTestInstrument))
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
        amount: MonetaryAmount(cents: 80000, currency: Instrument.defaultTestInstrument))
    ]
    let categoryBalances: [UUID: InstrumentAmount] = [
      catId: MonetaryAmount(cents: -50000, currency: Instrument.defaultTestInstrument)
    ]

    let result = BudgetLineItem.buildLineItems(
      budgetItems: budgetItems,
      categoryBalances: categoryBalances,
      categories: categories
    )

    #expect(result.count == 1)
    #expect(result.first?.categoryName == "Flights")
    #expect(result.first?.actual.cents == -50000)
    #expect(result.first?.budgeted.cents == 80000)
    #expect(result.first?.remaining.cents == 30000)
  }

  @Test func testMergeIncludesBudgetOnlyCategories() {
    let catId = UUID()
    let categories = Categories(from: [Category(id: catId, name: "Food")])
    let budgetItems = [
      EarmarkBudgetItem(
        categoryId: catId,
        amount: MonetaryAmount(cents: 30000, currency: Instrument.defaultTestInstrument))
    ]
    let categoryBalances: [UUID: InstrumentAmount] = [:]

    let result = BudgetLineItem.buildLineItems(
      budgetItems: budgetItems,
      categoryBalances: categoryBalances,
      categories: categories
    )

    #expect(result.count == 1)
    #expect(result.first?.actual.cents == 0)
    #expect(result.first?.remaining.cents == 30000)
  }

  @Test func testMergeIncludesActualOnlyCategories() {
    let catId = UUID()
    let categories = Categories(from: [Category(id: catId, name: "Transport")])
    let budgetItems: [EarmarkBudgetItem] = []
    let categoryBalances: [UUID: InstrumentAmount] = [
      catId: MonetaryAmount(cents: -20000, currency: Instrument.defaultTestInstrument)
    ]

    let result = BudgetLineItem.buildLineItems(
      budgetItems: budgetItems,
      categoryBalances: categoryBalances,
      categories: categories
    )

    #expect(result.count == 1)
    #expect(result.first?.budgeted.cents == 0)
    #expect(result.first?.remaining.cents == -20000)
  }

  @Test func testMergeCalculatesRemainingCorrectly() {
    let catId = UUID()
    let categories = Categories(from: [Category(id: catId, name: "Accommodation")])
    let budgetItems = [
      EarmarkBudgetItem(
        categoryId: catId,
        amount: MonetaryAmount(cents: 60000, currency: Instrument.defaultTestInstrument))
    ]
    // Spending exceeds budget
    let categoryBalances: [UUID: InstrumentAmount] = [
      catId: MonetaryAmount(cents: -70000, currency: Instrument.defaultTestInstrument)
    ]

    let result = BudgetLineItem.buildLineItems(
      budgetItems: budgetItems,
      categoryBalances: categoryBalances,
      categories: categories
    )

    // remaining = budget + actual = 60000 + (-70000) = -10000 (over budget)
    #expect(result.first?.remaining.cents == -10000)
  }

  @Test func testMergeSortsByCategoryName() {
    let cat1 = Category(id: UUID(), name: "Zebra")
    let cat2 = Category(id: UUID(), name: "Alpha")
    let cat3 = Category(id: UUID(), name: "Middle")
    let categories = Categories(from: [cat1, cat2, cat3])
    let budgetItems = [
      EarmarkBudgetItem(
        categoryId: cat1.id,
        amount: MonetaryAmount(cents: 10000, currency: Instrument.defaultTestInstrument)),
      EarmarkBudgetItem(
        categoryId: cat2.id,
        amount: MonetaryAmount(cents: 20000, currency: Instrument.defaultTestInstrument)),
      EarmarkBudgetItem(
        categoryId: cat3.id,
        amount: MonetaryAmount(cents: 30000, currency: Instrument.defaultTestInstrument)),
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
        amount: MonetaryAmount(cents: 70000, currency: Instrument.defaultTestInstrument))
    ]
    let savingsGoal = MonetaryAmount(cents: 100000, currency: Instrument.defaultTestInstrument)

    let unallocated = BudgetLineItem.unallocatedAmount(
      budgetItems: budgetItems,
      savingsGoal: savingsGoal
    )

    // 100000 - 70000 = 30000
    #expect(unallocated?.cents == 30000)
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
        amount: MonetaryAmount(cents: 120000, currency: Instrument.defaultTestInstrument))
    ]
    let savingsGoal = MonetaryAmount(cents: 100000, currency: Instrument.defaultTestInstrument)

    let unallocated = BudgetLineItem.unallocatedAmount(
      budgetItems: budgetItems,
      savingsGoal: savingsGoal
    )

    // 100000 - 120000 = -20000 (over-allocated)
    #expect(unallocated?.cents == -20000)
  }

  @Test func testUnknownCategoryNameForDeletedCategory() {
    let catId = UUID()
    let categories = Categories(from: [])  // Category not in lookup
    let budgetItems = [
      EarmarkBudgetItem(
        categoryId: catId,
        amount: MonetaryAmount(cents: 50000, currency: Instrument.defaultTestInstrument))
    ]

    let result = BudgetLineItem.buildLineItems(
      budgetItems: budgetItems,
      categoryBalances: [:],
      categories: categories
    )

    #expect(result.first?.categoryName == "Unknown")
  }
}
