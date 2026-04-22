import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("TransactionStore/AccountBalance")
@MainActor
struct TransactionStoreAccountBalanceTests {
  private let accountId = UUID()

  // MARK: - Cross-Store Balance Updates

  @Test func testCreateUpdatesAccountBalance() async throws {
    let account = TransactionStoreTestSupport.acct(id: accountId, name: "Bank", balance: 1000)
    let (backend, container) = try TestBackend.create()
    let stores = await TransactionStoreTestSupport.makeStores(
      backend: backend, container: container, accounts: [account])
    let store = stores.transactions
    let accountStore = stores.accounts

    await store.load(filter: TransactionFilter(accountId: accountId))

    let transaction = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Test",
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

    // Seeded balance is 1000 (from OB tx), create adds -50 expense -> 950
    let balance = try await accountStore.displayBalance(for: accountId)
    #expect(balance.quantity == Decimal(950))
  }

  @Test func testUpdateUpdatesAccountBalance() async throws {
    let account = TransactionStoreTestSupport.acct(id: accountId, name: "Bank", balance: 950)
    let transaction = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Test",
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
    let stores = await TransactionStoreTestSupport.makeStores(
      backend: backend, container: container, accounts: [account])
    let store = stores.transactions
    let accountStore = stores.accounts

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change amount from -50 to -75
    var updated = transaction
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(-7500) / 100,
        type: .expense
      )
    ]
    await store.update(updated)

    // Seeded account OB=950 + seeded tx=-50 gives loaded balance=900
    // Update delta: (-75)-(-50)=-25, so 900-25=875
    let balance = try await accountStore.displayBalance(for: accountId)
    #expect(balance.quantity == Decimal(875))
  }

  @Test func testDeleteUpdatesAccountBalance() async throws {
    let account = TransactionStoreTestSupport.acct(id: accountId, name: "Bank", balance: 950)
    let transaction = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Test",
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
    let stores = await TransactionStoreTestSupport.makeStores(
      backend: backend, container: container, accounts: [account])
    let store = stores.transactions
    let accountStore = stores.accounts

    await store.load(filter: TransactionFilter(accountId: accountId))

    await store.delete(id: transaction.id)

    // Seeded account OB=950 + seeded tx=-50 gives loaded balance=900
    // Deleting the -50 expense adds 50 back: 900+50=950
    let balance = try await accountStore.displayBalance(for: accountId)
    #expect(balance.quantity == Decimal(950))
  }
}
