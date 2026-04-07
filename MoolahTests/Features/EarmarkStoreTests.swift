import Foundation
import Testing

@testable import Moolah

@Suite("EarmarkStore")
@MainActor
struct EarmarkStoreTests {
  @Test func testPopulatesFromRepository() async throws {
    let earmark = Earmark(
      name: "Holiday Fund",
      balance: MonetaryAmount(cents: 50000, currency: Currency.defaultCurrency))
    let repository = InMemoryEarmarkRepository(initialEarmarks: [earmark])
    let store = EarmarkStore(repository: repository)

    await store.load()

    #expect(store.earmarks.count == 1)
    #expect(store.earmarks.first?.name == "Holiday Fund")
  }

  @Test func testSortingByPosition() async throws {
    let e1 = Earmark(
      name: "E1",
      balance: MonetaryAmount(cents: 10000, currency: Currency.defaultCurrency), position: 2)
    let e2 = Earmark(
      name: "E2",
      balance: MonetaryAmount(cents: 20000, currency: Currency.defaultCurrency), position: 1)
    let repository = InMemoryEarmarkRepository(initialEarmarks: [e1, e2])
    let store = EarmarkStore(repository: repository)

    await store.load()

    #expect(store.earmarks.count == 2)
    #expect(store.earmarks[0].name == "E2")
    #expect(store.earmarks[1].name == "E1")
  }

  @Test func testCalculatesTotalBalance() async throws {
    let earmarks = [
      Earmark(
        name: "Holiday",
        balance: MonetaryAmount(cents: 50000, currency: Currency.defaultCurrency)),
      Earmark(
        name: "Car Repair",
        balance: MonetaryAmount(cents: 30000, currency: Currency.defaultCurrency)),
      Earmark(
        name: "Hidden",
        balance: MonetaryAmount(cents: 100000, currency: Currency.defaultCurrency),
        isHidden: true),
    ]
    let repository = InMemoryEarmarkRepository(initialEarmarks: earmarks)
    let store = EarmarkStore(repository: repository)

    await store.load()

    // Total should only include visible earmarks
    #expect(store.totalBalance == MonetaryAmount(cents: 80000, currency: Currency.defaultCurrency))
  }

  // MARK: - applyTransactionDelta

  @Test func testCreateExpenseToEarmarkIncreasesSpentAndDecreasesBalance() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let repository = InMemoryEarmarkRepository(initialEarmarks: [
      Earmark(
        id: earmarkId, name: "Holiday Fund",
        balance: MonetaryAmount(cents: 50000, currency: Currency.defaultCurrency),
        saved: MonetaryAmount(cents: 50000, currency: Currency.defaultCurrency),
        spent: MonetaryAmount(cents: 0, currency: Currency.defaultCurrency))
    ])
    let store = EarmarkStore(repository: repository)
    await store.load()

    // Spend $100 from the earmark
    let tx = Transaction(
      type: .expense, date: Date(), accountId: accountId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultCurrency),
      payee: "Flight Tickets",
      earmarkId: earmarkId
    )
    store.applyTransactionDelta(old: nil, new: tx)

    #expect(store.earmarks.by(id: earmarkId)?.balance.cents == 40000)  // 50000 - 10000
    #expect(store.earmarks.by(id: earmarkId)?.saved.cents == 50000)  // Unchanged
    #expect(store.earmarks.by(id: earmarkId)?.spent.cents == 10000)  // 0 + 10000
  }

  @Test func testCreateIncomeToEarmarkIncreasesSavedAndBalance() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let repository = InMemoryEarmarkRepository(initialEarmarks: [
      Earmark(
        id: earmarkId, name: "Holiday Fund",
        balance: MonetaryAmount(cents: 50000, currency: Currency.defaultCurrency),
        saved: MonetaryAmount(cents: 50000, currency: Currency.defaultCurrency),
        spent: MonetaryAmount(cents: 0, currency: Currency.defaultCurrency))
    ])
    let store = EarmarkStore(repository: repository)
    await store.load()

    // Add $200 to the earmark
    let tx = Transaction(
      type: .income, date: Date(), accountId: accountId,
      amount: MonetaryAmount(cents: 20000, currency: Currency.defaultCurrency),
      payee: "Bonus",
      earmarkId: earmarkId
    )
    store.applyTransactionDelta(old: nil, new: tx)

    #expect(store.earmarks.by(id: earmarkId)?.balance.cents == 70000)  // 50000 + 20000
    #expect(store.earmarks.by(id: earmarkId)?.saved.cents == 70000)  // 50000 + 20000
    #expect(store.earmarks.by(id: earmarkId)?.spent.cents == 0)  // Unchanged
  }

  @Test func testDeleteRevertsEarmarkBalance() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let repository = InMemoryEarmarkRepository(initialEarmarks: [
      Earmark(
        id: earmarkId, name: "Holiday Fund",
        balance: MonetaryAmount(cents: 40000, currency: Currency.defaultCurrency),
        saved: MonetaryAmount(cents: 50000, currency: Currency.defaultCurrency),
        spent: MonetaryAmount(cents: 10000, currency: Currency.defaultCurrency))
    ])
    let store = EarmarkStore(repository: repository)
    await store.load()

    // Remove a $100 expense from the earmark
    let tx = Transaction(
      type: .expense, date: Date(), accountId: accountId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultCurrency),
      payee: "Flight Tickets",
      earmarkId: earmarkId
    )
    store.applyTransactionDelta(old: tx, new: nil)

    // Removing -10000 expense should add 10000 back to balance and remove from spent
    #expect(store.earmarks.by(id: earmarkId)?.balance.cents == 50000)  // 40000 + 10000
    #expect(store.earmarks.by(id: earmarkId)?.saved.cents == 50000)  // Unchanged
    #expect(store.earmarks.by(id: earmarkId)?.spent.cents == 0)  // 10000 - 10000
  }

  @Test func testUpdateAdjustsEarmarkBalance() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let repository = InMemoryEarmarkRepository(initialEarmarks: [
      Earmark(
        id: earmarkId, name: "Holiday Fund",
        balance: MonetaryAmount(cents: 40000, currency: Currency.defaultCurrency),
        saved: MonetaryAmount(cents: 50000, currency: Currency.defaultCurrency),
        spent: MonetaryAmount(cents: 10000, currency: Currency.defaultCurrency))
    ])
    let store = EarmarkStore(repository: repository)
    await store.load()

    let oldTx = Transaction(
      type: .expense, date: Date(), accountId: accountId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultCurrency),
      payee: "Flight Tickets",
      earmarkId: earmarkId
    )
    var newTx = oldTx
    newTx.amount = MonetaryAmount(cents: -15000, currency: Currency.defaultCurrency)

    store.applyTransactionDelta(old: oldTx, new: newTx)

    // Was 40000 (after -10000 expense). Remove old (+10000 → 50000), apply new (-15000 → 35000)
    #expect(store.earmarks.by(id: earmarkId)?.balance.cents == 35000)
    #expect(store.earmarks.by(id: earmarkId)?.saved.cents == 50000)  // Unchanged
    #expect(store.earmarks.by(id: earmarkId)?.spent.cents == 15000)  // 10000 - 10000 + 15000
  }

  @Test func testChangingEarmarkIdUpdatesBothEarmarks() async throws {
    let earmark1Id = UUID()
    let earmark2Id = UUID()
    let accountId = UUID()
    let repository = InMemoryEarmarkRepository(initialEarmarks: [
      Earmark(
        id: earmark1Id, name: "Holiday Fund",
        balance: MonetaryAmount(cents: 40000, currency: Currency.defaultCurrency),
        saved: MonetaryAmount(cents: 50000, currency: Currency.defaultCurrency),
        spent: MonetaryAmount(cents: 10000, currency: Currency.defaultCurrency)),
      Earmark(
        id: earmark2Id, name: "Car Repair",
        balance: MonetaryAmount(cents: 30000, currency: Currency.defaultCurrency),
        saved: MonetaryAmount(cents: 30000, currency: Currency.defaultCurrency),
        spent: MonetaryAmount(cents: 0, currency: Currency.defaultCurrency)),
    ])
    let store = EarmarkStore(repository: repository)
    await store.load()

    // Original transaction was to earmark1
    let oldTx = Transaction(
      type: .expense, date: Date(), accountId: accountId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultCurrency),
      payee: "Flight Tickets",
      earmarkId: earmark1Id
    )
    // Change to earmark2
    var newTx = oldTx
    newTx.earmarkId = earmark2Id

    store.applyTransactionDelta(old: oldTx, new: newTx)

    // Earmark1 should have the expense removed (+10000)
    #expect(store.earmarks.by(id: earmark1Id)?.balance.cents == 50000)
    #expect(store.earmarks.by(id: earmark1Id)?.spent.cents == 0)

    // Earmark2 should have the expense added (-10000)
    #expect(store.earmarks.by(id: earmark2Id)?.balance.cents == 20000)
    #expect(store.earmarks.by(id: earmark2Id)?.spent.cents == 10000)
  }

  @Test func testAddingEarmarkToTransaction() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let repository = InMemoryEarmarkRepository(initialEarmarks: [
      Earmark(
        id: earmarkId, name: "Holiday Fund",
        balance: MonetaryAmount(cents: 50000, currency: Currency.defaultCurrency),
        saved: MonetaryAmount(cents: 50000, currency: Currency.defaultCurrency),
        spent: MonetaryAmount(cents: 0, currency: Currency.defaultCurrency))
    ])
    let store = EarmarkStore(repository: repository)
    await store.load()

    // Original transaction had no earmark
    let oldTx = Transaction(
      type: .expense, date: Date(), accountId: accountId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultCurrency),
      payee: "Flight Tickets"
    )
    // Add earmark to it
    var newTx = oldTx
    newTx.earmarkId = earmarkId

    store.applyTransactionDelta(old: oldTx, new: newTx)

    #expect(store.earmarks.by(id: earmarkId)?.balance.cents == 40000)
    #expect(store.earmarks.by(id: earmarkId)?.spent.cents == 10000)
  }

  @Test func testRemovingEarmarkFromTransaction() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let repository = InMemoryEarmarkRepository(initialEarmarks: [
      Earmark(
        id: earmarkId, name: "Holiday Fund",
        balance: MonetaryAmount(cents: 40000, currency: Currency.defaultCurrency),
        saved: MonetaryAmount(cents: 50000, currency: Currency.defaultCurrency),
        spent: MonetaryAmount(cents: 10000, currency: Currency.defaultCurrency))
    ])
    let store = EarmarkStore(repository: repository)
    await store.load()

    // Original transaction had an earmark
    let oldTx = Transaction(
      type: .expense, date: Date(), accountId: accountId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultCurrency),
      payee: "Flight Tickets",
      earmarkId: earmarkId
    )
    // Remove the earmark
    var newTx = oldTx
    newTx.earmarkId = nil

    store.applyTransactionDelta(old: oldTx, new: newTx)

    #expect(store.earmarks.by(id: earmarkId)?.balance.cents == 50000)
    #expect(store.earmarks.by(id: earmarkId)?.spent.cents == 0)
  }

  @Test func testTotalBalanceUpdatesAfterDelta() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let repository = InMemoryEarmarkRepository(initialEarmarks: [
      Earmark(
        id: earmarkId, name: "Holiday Fund",
        balance: MonetaryAmount(cents: 50000, currency: Currency.defaultCurrency),
        saved: MonetaryAmount(cents: 50000, currency: Currency.defaultCurrency),
        spent: MonetaryAmount(cents: 0, currency: Currency.defaultCurrency))
    ])
    let store = EarmarkStore(repository: repository)
    await store.load()

    #expect(store.totalBalance.cents == 50000)

    let tx = Transaction(
      type: .expense, date: Date(), accountId: accountId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultCurrency),
      payee: "Flight Tickets",
      earmarkId: earmarkId
    )
    store.applyTransactionDelta(old: nil, new: tx)

    #expect(store.totalBalance.cents == 40000)
  }
}
