import Foundation
import Testing

@testable import Moolah

/// Running-balance update tests for `TransactionStore`.
@Suite("TransactionStore/Running Balances")
@MainActor
struct TransactionStoreRunningBalanceTests {
  private let accountId = UUID()

  @Test
  func testRunningBalancesUpdateAfterCreate() async throws {
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
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: [existing], in: database)
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
    try await store.awaitTransactionCount(2)

    // Newest first: expense (balance 97000), then income (balance 100000)
    #expect(store.transactions.count == 2)
    #expect(store.transactions[0].transaction.payee == "Coffee")
    #expect(store.transactions[0].balance?.quantity == Decimal(97000) / 100)
    #expect(store.transactions[1].transaction.payee == "Initial")
    #expect(store.transactions[1].balance?.quantity == Decimal(100000) / 100)
  }

  @Test
  func testRunningBalancesUpdateAfterDelete() async throws {
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
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: [salary, coffee], in: database)
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
    try await store.awaitTransactionCount(1)
    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].balance?.quantity == Decimal(100000) / 100)  // Only Salary remains
  }

  @Test
  func testRunningBalancesUpdateAfterAmountChange() async throws {
    let salary = try makeIncome(date: "2024-01-01", payee: "Salary", quantity: 1000)
    let coffee = try makeExpense(date: "2024-01-15", payee: "Coffee", quantity: -30)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: [salary, coffee], in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions[0].balance?.quantity == 970)  // After Coffee
    #expect(store.transactions[1].balance?.quantity == 1000)  // After Salary

    var updated = coffee
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: -50,
        type: .expense
      )
    ]
    await store.update(updated)
    try await store.waitForNextEmission(
      matching: { $0.transactions.first?.balance?.quantity == 950 },
      description: "updated balance is observable"
    )
    #expect(store.transactions[0].balance?.quantity == 950)
    #expect(store.transactions[1].balance?.quantity == 1000)
  }

  // MARK: - Helpers

  private func makeIncome(
    date: String, payee: String, quantity: Decimal
  ) throws -> Transaction {
    Transaction(
      date: try TransactionStoreTestSupport.makeDate(date),
      payee: payee,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: quantity,
          type: .income
        )
      ]
    )
  }

  private func makeExpense(
    date: String, payee: String, quantity: Decimal
  ) throws -> Transaction {
    Transaction(
      date: try TransactionStoreTestSupport.makeDate(date),
      payee: payee,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: quantity,
          type: .expense
        )
      ]
    )
  }
}
