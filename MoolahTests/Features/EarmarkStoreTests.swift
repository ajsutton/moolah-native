import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("EarmarkStore")
@MainActor
struct EarmarkStoreTests {
  @Test func testPopulatesFromRepository() async throws {
    let earmark = Earmark(
      name: "Holiday Fund",
      balance: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency))
    let (backend, container) = try TestBackend.create()
    TestBackend.seedWithTransactions(
      earmarks: [earmark], accountId: UUID(), in: container)
    let store = EarmarkStore(repository: backend.earmarks)

    await store.load()

    #expect(store.earmarks.count == 1)
    #expect(store.earmarks.first?.name == "Holiday Fund")
  }

  @Test func testSortingByPosition() async throws {
    let e1 = Earmark(
      name: "E1",
      balance: MonetaryAmount(cents: 10000, currency: Currency.defaultTestCurrency), position: 2)
    let e2 = Earmark(
      name: "E2",
      balance: MonetaryAmount(cents: 20000, currency: Currency.defaultTestCurrency), position: 1)
    let (backend, container) = try TestBackend.create()
    TestBackend.seedWithTransactions(
      earmarks: [e1, e2], accountId: UUID(), in: container)
    let store = EarmarkStore(repository: backend.earmarks)

    await store.load()

    #expect(store.earmarks.count == 2)
    #expect(store.earmarks[0].name == "E2")
    #expect(store.earmarks[1].name == "E1")
  }

  @Test func testCalculatesTotalBalance() async throws {
    let earmarks = [
      Earmark(
        name: "Holiday",
        balance: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency)),
      Earmark(
        name: "Car Repair",
        balance: MonetaryAmount(cents: 30000, currency: Currency.defaultTestCurrency)),
      Earmark(
        name: "Hidden",
        balance: MonetaryAmount(cents: 100000, currency: Currency.defaultTestCurrency),
        isHidden: true),
    ]
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container,
    )
    TestBackend.seedWithTransactions(
      earmarks: earmarks, accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)

    await store.load()

    // Total should only include visible earmarks
    #expect(
      store.totalBalance == MonetaryAmount(cents: 80000, currency: Currency.defaultTestCurrency))
  }

  // MARK: - applyTransactionDelta

  @Test func testCreateExpenseToEarmarkIncreasesSpentAndDecreasesBalance() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container,
    )
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(
          id: earmarkId, name: "Holiday Fund",
          balance: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency),
          saved: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency),
          spent: MonetaryAmount(cents: 0, currency: Currency.defaultTestCurrency))
      ], accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()

    // Spend $100 from the earmark
    let tx = Transaction(
      type: .expense, date: Date(), accountId: accountId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultTestCurrency),
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
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container,
    )
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(
          id: earmarkId, name: "Holiday Fund",
          balance: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency),
          saved: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency),
          spent: MonetaryAmount(cents: 0, currency: Currency.defaultTestCurrency))
      ], accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()

    // Add $200 to the earmark
    let tx = Transaction(
      type: .income, date: Date(), accountId: accountId,
      amount: MonetaryAmount(cents: 20000, currency: Currency.defaultTestCurrency),
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
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container,
    )
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(
          id: earmarkId, name: "Holiday Fund",
          balance: MonetaryAmount(cents: 40000, currency: Currency.defaultTestCurrency),
          saved: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency),
          spent: MonetaryAmount(cents: 10000, currency: Currency.defaultTestCurrency))
      ], accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()

    // Remove a $100 expense from the earmark
    let tx = Transaction(
      type: .expense, date: Date(), accountId: accountId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultTestCurrency),
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
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container,
    )
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(
          id: earmarkId, name: "Holiday Fund",
          balance: MonetaryAmount(cents: 40000, currency: Currency.defaultTestCurrency),
          saved: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency),
          spent: MonetaryAmount(cents: 10000, currency: Currency.defaultTestCurrency))
      ], accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()

    let oldTx = Transaction(
      type: .expense, date: Date(), accountId: accountId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultTestCurrency),
      payee: "Flight Tickets",
      earmarkId: earmarkId
    )
    var newTx = oldTx
    newTx.amount = MonetaryAmount(cents: -15000, currency: Currency.defaultTestCurrency)

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
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container,
    )
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(
          id: earmark1Id, name: "Holiday Fund",
          balance: MonetaryAmount(cents: 40000, currency: Currency.defaultTestCurrency),
          saved: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency),
          spent: MonetaryAmount(cents: 10000, currency: Currency.defaultTestCurrency)),
        Earmark(
          id: earmark2Id, name: "Car Repair",
          balance: MonetaryAmount(cents: 30000, currency: Currency.defaultTestCurrency),
          saved: MonetaryAmount(cents: 30000, currency: Currency.defaultTestCurrency),
          spent: MonetaryAmount(cents: 0, currency: Currency.defaultTestCurrency)),
      ], accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()

    // Original transaction was to earmark1
    let oldTx = Transaction(
      type: .expense, date: Date(), accountId: accountId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultTestCurrency),
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
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container,
    )
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(
          id: earmarkId, name: "Holiday Fund",
          balance: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency),
          saved: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency),
          spent: MonetaryAmount(cents: 0, currency: Currency.defaultTestCurrency))
      ], accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()

    // Original transaction had no earmark
    let oldTx = Transaction(
      type: .expense, date: Date(), accountId: accountId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultTestCurrency),
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
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container,
    )
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(
          id: earmarkId, name: "Holiday Fund",
          balance: MonetaryAmount(cents: 40000, currency: Currency.defaultTestCurrency),
          saved: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency),
          spent: MonetaryAmount(cents: 10000, currency: Currency.defaultTestCurrency))
      ], accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()

    // Original transaction had an earmark
    let oldTx = Transaction(
      type: .expense, date: Date(), accountId: accountId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultTestCurrency),
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
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container,
    )
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(
          id: earmarkId, name: "Holiday Fund",
          balance: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency),
          saved: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency),
          spent: MonetaryAmount(cents: 0, currency: Currency.defaultTestCurrency))
      ], accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()

    #expect(store.totalBalance.cents == 50000)

    let tx = Transaction(
      type: .expense, date: Date(), accountId: accountId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultTestCurrency),
      payee: "Flight Tickets",
      earmarkId: earmarkId
    )
    store.applyTransactionDelta(old: nil, new: tx)

    #expect(store.totalBalance.cents == 40000)
  }

  @Test func testScheduledTransactionDoesNotAffectEarmarkBalance() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(
          id: earmarkId, name: "Holiday Fund",
          balance: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency),
          saved: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency),
          spent: MonetaryAmount(cents: 0, currency: Currency.defaultTestCurrency))
      ], accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()

    let scheduledTx = Transaction(
      type: .expense, date: Date(), accountId: accountId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultTestCurrency),
      payee: "Scheduled Bill",
      earmarkId: earmarkId,
      recurPeriod: .month, recurEvery: 1
    )
    store.applyTransactionDelta(old: nil, new: scheduledTx)

    // Scheduled transactions should not change earmark balance
    #expect(store.earmarks.by(id: earmarkId)?.balance.cents == 50000)
    #expect(store.earmarks.by(id: earmarkId)?.spent.cents == 0)
  }

  // MARK: - reorderEarmarks

  @Test func testReorderEarmarksUpdatesPositions() async throws {
    let e0 = Earmark(name: "First", position: 0)
    let e1 = Earmark(name: "Second", position: 1)
    let e2 = Earmark(name: "Third", position: 2)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [e0, e1, e2], in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()

    // Move last to first
    await store.reorderEarmarks(from: IndexSet(integer: 2), to: 0)

    #expect(store.visibleEarmarks[0].name == "Third")
    #expect(store.visibleEarmarks[1].name == "First")
    #expect(store.visibleEarmarks[2].name == "Second")
    #expect(store.visibleEarmarks[0].position == 0)
    #expect(store.visibleEarmarks[1].position == 1)
    #expect(store.visibleEarmarks[2].position == 2)
  }

  @Test func testReorderEarmarksSkipsHiddenEarmarks() async throws {
    let e0 = Earmark(name: "Visible1", position: 0)
    let e1 = Earmark(name: "Hidden", isHidden: true, position: 1)
    let e2 = Earmark(name: "Visible2", position: 2)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [e0, e1, e2], in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()

    // Swap the two visible earmarks
    await store.reorderEarmarks(from: IndexSet(integer: 1), to: 0)

    #expect(store.visibleEarmarks[0].name == "Visible2")
    #expect(store.visibleEarmarks[1].name == "Visible1")
    // Hidden earmark position unchanged
    let hidden = store.earmarks.ordered.first { $0.isHidden }
    #expect(hidden?.position == 1)
  }

  @Test func testReorderSingleEarmarkIsNoOp() async throws {
    let e0 = Earmark(name: "Only", position: 0)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [e0], in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()

    await store.reorderEarmarks(from: IndexSet(integer: 0), to: 0)

    #expect(store.visibleEarmarks.count == 1)
    #expect(store.visibleEarmarks[0].position == 0)
  }

  @Test func testReorderEmptyListIsNoOp() async throws {
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [], in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()

    await store.reorderEarmarks(from: IndexSet(integer: 0), to: 0)

    #expect(store.visibleEarmarks.isEmpty)
  }

  @Test func testReorderPersistsToRepository() async throws {
    let e0 = Earmark(name: "First", position: 0)
    let e1 = Earmark(name: "Second", position: 1)
    let e2 = Earmark(name: "Third", position: 2)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [e0, e1, e2], in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()

    // Move last to first
    await store.reorderEarmarks(from: IndexSet(integer: 2), to: 0)

    // Verify repository has updated positions
    let persisted = try await backend.earmarks.fetchAll().sorted { $0.position < $1.position }
    #expect(persisted[0].name == "Third")
    #expect(persisted[1].name == "First")
    #expect(persisted[2].name == "Second")
    #expect(persisted[0].position == 0)
    #expect(persisted[1].position == 1)
    #expect(persisted[2].position == 2)
  }

  // MARK: - Show Hidden

  // MARK: - create / update

  @Test func testCreateAddsEarmark() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(repository: backend.earmarks)

    let earmark = Earmark(name: "New Fund")
    let created = await store.create(earmark)

    #expect(created != nil)
    #expect(created?.name == "New Fund")
    #expect(store.earmarks.count == 1)
    #expect(store.earmarks.first?.name == "New Fund")
  }

  @Test func testCreateReturnsNilOnFailure() async throws {
    let store = EarmarkStore(repository: FailingEarmarkRepository())

    let result = await store.create(Earmark(name: "Fails"))

    #expect(result == nil)
    #expect(store.error != nil)
  }

  @Test func testCreateReloadsAfterSuccess() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(repository: backend.earmarks)

    let e1 = Earmark(name: "First")
    _ = await store.create(e1)
    let e2 = Earmark(name: "Second")
    _ = await store.create(e2)

    #expect(store.earmarks.count == 2)
    #expect(store.earmarks.by(id: e1.id) != nil)
    #expect(store.earmarks.by(id: e2.id) != nil)
  }

  @Test func testUpdateModifiesEarmark() async throws {
    let earmark = Earmark(name: "Holiday Fund")
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [earmark], in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()

    var modified = earmark
    modified.name = "Vacation Fund"
    let updated = await store.update(modified)

    #expect(updated != nil)
    #expect(updated?.name == "Vacation Fund")
    #expect(store.earmarks.by(id: earmark.id)?.name == "Vacation Fund")
  }

  @Test func testUpdateReturnsNilOnFailure() async throws {
    let store = EarmarkStore(repository: FailingEarmarkRepository())

    let result = await store.update(Earmark(name: "Fails"))

    #expect(result == nil)
    #expect(store.error != nil)
  }

  // MARK: - Show Hidden

  @Test("visibleEarmarks excludes hidden earmarks by default")
  func hiddenEarmarksExcluded() async throws {
    let visible = Earmark(
      name: "Visible",
      balance: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency))
    let hidden = Earmark(
      name: "Hidden",
      balance: MonetaryAmount(cents: 30000, currency: Currency.defaultTestCurrency),
      isHidden: true)
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container,
    )
    TestBackend.seedWithTransactions(
      earmarks: [visible, hidden], accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)

    await store.load()

    #expect(store.visibleEarmarks.count == 1)
    #expect(store.visibleEarmarks[0].name == "Visible")
  }

  @Test("visibleEarmarks includes hidden earmarks when showHidden is true")
  func hiddenEarmarksIncluded() async throws {
    let visible = Earmark(
      name: "Visible",
      balance: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency))
    let hidden = Earmark(
      name: "Hidden",
      balance: MonetaryAmount(cents: 30000, currency: Currency.defaultTestCurrency),
      isHidden: true)
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container,
    )
    TestBackend.seedWithTransactions(
      earmarks: [visible, hidden], accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)

    await store.load()
    store.showHidden = true

    #expect(store.visibleEarmarks.count == 2)
  }
}

// MARK: - Test helpers

private struct FailingEarmarkRepository: EarmarkRepository {
  func fetchAll() async throws -> [Earmark] {
    throw BackendError.networkUnavailable
  }

  func create(_ earmark: Earmark) async throws -> Earmark {
    throw BackendError.networkUnavailable
  }

  func update(_ earmark: Earmark) async throws -> Earmark {
    throw BackendError.networkUnavailable
  }

  func fetchBudget(earmarkId: UUID) async throws -> [EarmarkBudgetItem] {
    throw BackendError.networkUnavailable
  }

  func setBudget(earmarkId: UUID, categoryId: UUID, amount: Int) async throws {
    throw BackendError.networkUnavailable
  }
}
