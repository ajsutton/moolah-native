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
      balance: InstrumentAmount(
        quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument))
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
      balance: InstrumentAmount(
        quantity: Decimal(10000) / 100, instrument: Instrument.defaultTestInstrument), position: 2
    )
    let e2 = Earmark(
      name: "E2",
      balance: InstrumentAmount(
        quantity: Decimal(20000) / 100, instrument: Instrument.defaultTestInstrument), position: 1
    )
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
        balance: InstrumentAmount(
          quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument)),
      Earmark(
        name: "Car Repair",
        balance: InstrumentAmount(
          quantity: Decimal(30000) / 100, instrument: Instrument.defaultTestInstrument)),
      Earmark(
        name: "Hidden",
        balance: InstrumentAmount(
          quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument),
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
      store.totalBalance
        == InstrumentAmount(
          quantity: Decimal(80000) / 100, instrument: Instrument.defaultTestInstrument)
    )
  }

  // MARK: - applyDelta (position-based)

  @Test func testApplyDeltaAdjustsPositionsAndBalance() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(
          id: earmarkId, name: "Holiday Fund",
          balance: InstrumentAmount(quantity: 500, instrument: instrument),
          saved: InstrumentAmount(quantity: 500, instrument: instrument),
          spent: InstrumentAmount(quantity: 0, instrument: instrument))
      ], accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()

    // Apply a -100 expense delta
    store.applyDelta(
      earmarkDeltas: [earmarkId: [instrument: -100]],
      savedDeltas: [:],
      spentDeltas: [earmarkId: [instrument: 100]]
    )

    #expect(store.earmarks.by(id: earmarkId)?.balance.quantity == 400)
    #expect(store.earmarks.by(id: earmarkId)?.saved.quantity == 500)
    #expect(store.earmarks.by(id: earmarkId)?.spent.quantity == 100)
  }

  @Test func testApplyDeltaWithSavedIncreasesBalance() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(
          id: earmarkId, name: "Holiday Fund",
          balance: InstrumentAmount(quantity: 500, instrument: instrument),
          saved: InstrumentAmount(quantity: 500, instrument: instrument),
          spent: InstrumentAmount(quantity: 0, instrument: instrument))
      ], accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()

    // Apply a +200 income delta
    store.applyDelta(
      earmarkDeltas: [earmarkId: [instrument: 200]],
      savedDeltas: [earmarkId: [instrument: 200]],
      spentDeltas: [:]
    )

    #expect(store.earmarks.by(id: earmarkId)?.balance.quantity == 700)
    #expect(store.earmarks.by(id: earmarkId)?.saved.quantity == 700)
    #expect(store.earmarks.by(id: earmarkId)?.spent.quantity == 0)
  }

  @Test func testApplyDeltaAffectsMultipleEarmarks() async throws {
    let earmark1Id = UUID()
    let earmark2Id = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(
          id: earmark1Id, name: "Holiday",
          balance: InstrumentAmount(quantity: 500, instrument: instrument),
          saved: InstrumentAmount(quantity: 500, instrument: instrument),
          spent: InstrumentAmount(quantity: 0, instrument: instrument)),
        Earmark(
          id: earmark2Id, name: "Car",
          balance: InstrumentAmount(quantity: 300, instrument: instrument),
          saved: InstrumentAmount(quantity: 300, instrument: instrument),
          spent: InstrumentAmount(quantity: 0, instrument: instrument)),
      ], accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()

    // Apply deltas to both earmarks
    store.applyDelta(
      earmarkDeltas: [
        earmark1Id: [instrument: -100],
        earmark2Id: [instrument: 50],
      ],
      savedDeltas: [earmark2Id: [instrument: 50]],
      spentDeltas: [earmark1Id: [instrument: 100]]
    )

    #expect(store.earmarks.by(id: earmark1Id)?.balance.quantity == 400)
    #expect(store.earmarks.by(id: earmark1Id)?.spent.quantity == 100)
    #expect(store.earmarks.by(id: earmark2Id)?.balance.quantity == 350)
    #expect(store.earmarks.by(id: earmark2Id)?.saved.quantity == 350)
  }

  // MARK: - convertedTotalBalance

  @Test func testConvertedTotalBalanceNilBeforeLoad() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(repository: backend.earmarks)

    #expect(store.convertedTotalBalance == nil)
  }

  @Test func testConvertedTotalBalancePopulatedAfterLoad() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(
          id: earmarkId, name: "Holiday Fund",
          balance: InstrumentAmount(quantity: 500, instrument: instrument),
          saved: InstrumentAmount(quantity: 500, instrument: instrument),
          spent: InstrumentAmount(quantity: 0, instrument: instrument))
      ], accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)

    await store.load()

    // Wait for async conversion task
    try await Task.sleep(for: .milliseconds(50))

    #expect(store.convertedTotalBalance != nil)
    #expect(store.convertedTotalBalance?.quantity == 500)
  }

  @Test func testConvertedTotalBalanceUpdatesAfterApplyDelta() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(
          id: earmarkId, name: "Holiday Fund",
          balance: InstrumentAmount(quantity: 500, instrument: instrument),
          saved: InstrumentAmount(quantity: 500, instrument: instrument),
          spent: InstrumentAmount(quantity: 0, instrument: instrument))
      ], accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()
    try await Task.sleep(for: .milliseconds(50))
    #expect(store.convertedTotalBalance?.quantity == 500)

    store.applyDelta(
      earmarkDeltas: [earmarkId: [instrument: -100]],
      savedDeltas: [:],
      spentDeltas: [earmarkId: [instrument: 100]]
    )
    try await Task.sleep(for: .milliseconds(50))

    #expect(store.convertedTotalBalance?.quantity == 400)
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
      balance: InstrumentAmount(
        quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument))
    let hidden = Earmark(
      name: "Hidden",
      balance: InstrumentAmount(
        quantity: Decimal(30000) / 100, instrument: Instrument.defaultTestInstrument),
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
      balance: InstrumentAmount(
        quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument))
    let hidden = Earmark(
      name: "Hidden",
      balance: InstrumentAmount(
        quantity: Decimal(30000) / 100, instrument: Instrument.defaultTestInstrument),
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

  func setBudget(earmarkId: UUID, categoryId: UUID, amount: InstrumentAmount) async throws {
    throw BackendError.networkUnavailable
  }
}
