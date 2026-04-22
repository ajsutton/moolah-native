import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("TransactionStore/CRUD")
@MainActor
struct TransactionStoreCRUDTests {
  private let accountId = UUID()

  // MARK: - CRUD

  @Test func testCreateAddsTransaction() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.isEmpty)

    let transaction = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Coffee Shop",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense
        )
      ]
    )
    _ = await store.create(transaction)

    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].transaction.payee == "Coffee Shop")
    #expect(store.error == nil)
  }

  /// The placeholder-pass-through pattern in `TransactionListView.createNewTransaction`
  /// (and the upcoming-view equivalent) relies on `store.create(placeholder)`
  /// returning a transaction with the same UUID the caller passed in. The
  /// inspector's `.id(selected.id)` otherwise forces a view recreation on
  /// every create, which would drop focus state. See
  /// `plans/2026-04-21-transaction-detail-focus-design.md`.
  @Test func testCreatePreservesInputUUID() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )
    await store.load(filter: TransactionFilter(accountId: accountId))

    let placeholderId = UUID()
    let placeholder = Transaction(
      id: placeholderId,
      date: try TransactionStoreTestSupport.makeDate("2024-02-01"),
      payee: "",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: 0,
          type: .expense
        )
      ]
    )

    let created = await store.create(placeholder)

    #expect(created?.id == placeholderId)
    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].transaction.id == placeholderId)
  }

  @Test func testUpdateModifiesTransaction() async throws {
    let transaction = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Coffee Shop",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [transaction], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 1)

    var updated = transaction
    updated.payee = "Fancy Coffee"
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(-7500) / 100,
        type: .expense
      )
    ]
    await store.update(updated)

    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].transaction.payee == "Fancy Coffee")
    #expect(store.transactions[0].displayAmount?.quantity == Decimal(-7500) / 100)
    #expect(store.error == nil)
  }

  @Test func testDeleteRemovesTransaction() async throws {
    let transaction = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Coffee Shop",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [transaction], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 1)

    await store.delete(id: transaction.id)

    #expect(store.transactions.isEmpty)
    #expect(store.error == nil)
  }

  @Test func testCreateUpdateDeleteCycle() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Create
    let transaction = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-10"),
      payee: "Salary",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(100000) / 100,
          type: .income
        )
      ]
    )
    _ = await store.create(transaction)
    #expect(store.transactions.count == 1)

    // Update
    var modified = transaction
    modified.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(110000) / 100,
        type: .income
      )
    ]
    await store.update(modified)
    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].displayAmount?.quantity == Decimal(110000) / 100)

    // Delete
    await store.delete(id: transaction.id)
    #expect(store.transactions.isEmpty)
  }

  @Test func testRunningBalancesUpdateAfterCreate() async throws {
    let existing = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-01"),
      payee: "Initial",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(100000) / 100,
          type: .income
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [existing], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions[0].balance?.quantity == Decimal(100000) / 100)

    // Add a newer expense
    let expense = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-3000) / 100,
          type: .expense
        )
      ]
    )
    _ = await store.create(expense)

    // Newest first: expense (balance 97000), then income (balance 100000)
    #expect(store.transactions.count == 2)
    #expect(store.transactions[0].transaction.payee == "Coffee")
    #expect(store.transactions[0].balance?.quantity == Decimal(97000) / 100)
    #expect(store.transactions[1].transaction.payee == "Initial")
    #expect(store.transactions[1].balance?.quantity == Decimal(100000) / 100)
  }

  @Test func testRunningBalancesUpdateAfterDelete() async throws {
    let salary = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-01"),
      payee: "Salary",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(100000) / 100,
          type: .income
        )
      ]
    )
    let coffee = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-3000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [salary, coffee], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 2)
    #expect(store.transactions[0].balance?.quantity == Decimal(97000) / 100)  // After Coffee

    // Delete the expense — balance should revert
    await store.delete(id: coffee.id)
    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].balance?.quantity == Decimal(100000) / 100)  // Only Salary remains
  }

}
