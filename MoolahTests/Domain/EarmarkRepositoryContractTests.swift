import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("EarmarkRepository Contract")
struct EarmarkRepositoryContractTests {
  @Test("creates earmark")
  func testCreatesEarmark() async throws {
    let repository = makeCloudKitEarmarkRepository()
    let newEarmark = Earmark(name: "Emergency Fund", instrument: .defaultTestInstrument)

    let created = try await repository.create(newEarmark)

    #expect(created.id == newEarmark.id)
    #expect(created.name == "Emergency Fund")

    let all = try await repository.fetchAll()
    #expect(all.count == 1)
    #expect(all[0].name == "Emergency Fund")
  }

  @Test("updates earmark")
  func testUpdatesEarmark() async throws {
    let repository = makeCloudKitEarmarkRepository(initialEarmarks: [
      Earmark(name: "Emergency Fund", instrument: .defaultTestInstrument)
    ])
    let earmarks = try await repository.fetchAll()
    var toUpdate = earmarks[0]
    toUpdate.name = "Rainy Day Fund"
    toUpdate.savingsGoal = InstrumentAmount(
      quantity: Decimal(string: "5000.00")!, instrument: .defaultTestInstrument)

    let updated = try await repository.update(toUpdate)

    #expect(updated.name == "Rainy Day Fund")
    #expect(updated.savingsGoal?.quantity == Decimal(string: "5000.00")!)
  }

  @Test("fetches empty budget for new earmark")
  func testFetchesEmptyBudget() async throws {
    let repository = makeCloudKitEarmarkRepository(initialEarmarks: [
      Earmark(name: "Emergency Fund", instrument: .defaultTestInstrument)
    ])
    let earmarks = try await repository.fetchAll()
    let budget = try await repository.fetchBudget(earmarkId: earmarks[0].id)

    #expect(budget.isEmpty)
  }

  @Test("updates and fetches budget")
  func testUpdatesFetchesBudget() async throws {
    let repository = makeCloudKitEarmarkRepository(initialEarmarks: [
      Earmark(name: "Emergency Fund", instrument: .defaultTestInstrument)
    ])
    let earmarks = try await repository.fetchAll()
    let earmarkId = earmarks[0].id

    let category1 = UUID()
    let category2 = UUID()

    let amount1 = InstrumentAmount(
      quantity: Decimal(string: "100.00")!, instrument: .defaultTestInstrument)
    let amount2 = InstrumentAmount(
      quantity: Decimal(string: "200.00")!, instrument: .defaultTestInstrument)

    try await repository.setBudget(earmarkId: earmarkId, categoryId: category1, amount: amount1)
    try await repository.setBudget(earmarkId: earmarkId, categoryId: category2, amount: amount2)

    let fetchedBudget = try await repository.fetchBudget(earmarkId: earmarkId)
    #expect(fetchedBudget.count == 2)
    #expect(
      fetchedBudget.contains {
        $0.categoryId == category1 && $0.amount.quantity == Decimal(string: "100.00")!
      })
    #expect(
      fetchedBudget.contains {
        $0.categoryId == category2 && $0.amount.quantity == Decimal(string: "200.00")!
      })
  }

  @Test("throws on update non-existent")
  func testThrowsOnUpdateNonExistent() async throws {
    let repository = makeCloudKitEarmarkRepository()
    let nonExistent = Earmark(name: "DoesNotExist", instrument: .defaultTestInstrument)

    await #expect(throws: BackendError.serverError(404)) {
      _ = try await repository.update(nonExistent)
    }
  }

  @Test("throws on budget update for non-existent earmark")
  func testThrowsOnBudgetUpdateNonExistent() async throws {
    let repository = makeCloudKitEarmarkRepository()
    let amount = InstrumentAmount(
      quantity: Decimal(string: "100.00")!, instrument: .defaultTestInstrument)
    await #expect(throws: BackendError.serverError(404)) {
      try await repository.setBudget(earmarkId: UUID(), categoryId: UUID(), amount: amount)
    }
  }

  // MARK: - Multi-instrument persistence

  @Test("round-trips earmark with USD savings goal")
  func testRoundTripEarmarkWithUSDSavingsGoal() async throws {
    let repository = makeCloudKitEarmarkRepository()
    var earmark = Earmark(name: "US Travel Fund", instrument: .USD)
    earmark.savingsGoal = InstrumentAmount(
      quantity: Decimal(string: "5000.00")!, instrument: .USD)

    _ = try await repository.create(earmark)

    let all = try await repository.fetchAll()
    let fetched = try #require(all.first { $0.id == earmark.id })
    #expect(fetched.instrument == .USD)
    #expect(fetched.savingsGoal?.instrument == .USD)
    #expect(fetched.savingsGoal?.quantity == Decimal(string: "5000.00")!)
  }

  @Test("budget items preserve their own instrument distinct from earmark instrument")
  func testBudgetItemsPreserveInstrumentDistinctFromEarmark() async throws {
    let repository = makeCloudKitEarmarkRepository(initialEarmarks: [
      Earmark(name: "Mixed Fund", instrument: .AUD)
    ])
    let earmarks = try await repository.fetchAll()
    let earmarkId = earmarks[0].id
    let audCategory = UUID()
    let usdCategory = UUID()

    let audAmount = InstrumentAmount(
      quantity: Decimal(string: "100.00")!, instrument: .AUD)
    let usdAmount = InstrumentAmount(
      quantity: Decimal(string: "80.00")!, instrument: .USD)

    try await repository.setBudget(
      earmarkId: earmarkId, categoryId: audCategory, amount: audAmount)
    try await repository.setBudget(
      earmarkId: earmarkId, categoryId: usdCategory, amount: usdAmount)

    let fetched = try await repository.fetchBudget(earmarkId: earmarkId)
    #expect(fetched.count == 2)
    let audItem = try #require(fetched.first { $0.categoryId == audCategory })
    let usdItem = try #require(fetched.first { $0.categoryId == usdCategory })
    #expect(audItem.amount.instrument == .AUD)
    #expect(audItem.amount.quantity == Decimal(string: "100.00")!)
    #expect(usdItem.amount.instrument == .USD)
    #expect(usdItem.amount.quantity == Decimal(string: "80.00")!)
  }

  @Test("updating budget item changes amount without changing instrument")
  func testUpdatingBudgetItemPreservesInstrument() async throws {
    let repository = makeCloudKitEarmarkRepository(initialEarmarks: [
      Earmark(name: "Travel", instrument: .AUD)
    ])
    let earmarks = try await repository.fetchAll()
    let earmarkId = earmarks[0].id
    let categoryId = UUID()

    let usdFirst = InstrumentAmount(
      quantity: Decimal(string: "100.00")!, instrument: .USD)
    let usdSecond = InstrumentAmount(
      quantity: Decimal(string: "250.00")!, instrument: .USD)

    try await repository.setBudget(earmarkId: earmarkId, categoryId: categoryId, amount: usdFirst)
    try await repository.setBudget(earmarkId: earmarkId, categoryId: categoryId, amount: usdSecond)

    let fetched = try await repository.fetchBudget(earmarkId: earmarkId)
    let entries = fetched.filter { $0.categoryId == categoryId }
    #expect(entries.count == 1)
    #expect(entries[0].amount.instrument == .USD)
    #expect(entries[0].amount.quantity == Decimal(string: "250.00")!)
  }

  @Test("setBudget twice updates existing entry, not creates duplicate")
  func testBudgetUpsertSemantics() async throws {
    let repository = makeCloudKitEarmarkRepository(initialEarmarks: [
      Earmark(name: "Savings", instrument: .defaultTestInstrument)
    ])
    let earmarks = try await repository.fetchAll()
    let earmarkId = earmarks[0].id
    let categoryId = UUID()

    let amount1 = InstrumentAmount(
      quantity: Decimal(string: "100.00")!, instrument: .defaultTestInstrument)
    let amount2 = InstrumentAmount(
      quantity: Decimal(string: "250.00")!, instrument: .defaultTestInstrument)

    // Set budget first time
    try await repository.setBudget(earmarkId: earmarkId, categoryId: categoryId, amount: amount1)

    // Set budget again with different amount (should update, not duplicate)
    try await repository.setBudget(earmarkId: earmarkId, categoryId: categoryId, amount: amount2)

    let budget = try await repository.fetchBudget(earmarkId: earmarkId)

    // Should have exactly one entry for this category, not two
    let entries = budget.filter { $0.categoryId == categoryId }
    #expect(entries.count == 1, "setBudget should update, not create duplicate")
    #expect(
      entries[0].amount.quantity == Decimal(string: "250.00")!,
      "Amount should reflect the latest setBudget call")
  }
}

private func makeCloudKitEarmarkRepository(
  initialEarmarks: [Earmark] = [],
  instrument: Instrument = .defaultTestInstrument
) -> CloudKitEarmarkRepository {
  let container = try! TestModelContainer.create()
  let repo = CloudKitEarmarkRepository(
    modelContainer: container, instrument: instrument)

  if !initialEarmarks.isEmpty {
    let context = ModelContext(container)
    for earmark in initialEarmarks {
      context.insert(EarmarkRecord.from(earmark))
    }
    try! context.save()
  }

  return repo
}
