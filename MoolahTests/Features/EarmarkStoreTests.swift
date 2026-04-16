import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("EarmarkStore")
@MainActor
struct EarmarkStoreTests {
  @Test func testPopulatesFromRepository() async throws {
    let earmark = Earmark(name: "Holiday Fund", instrument: Instrument.defaultTestInstrument)
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seedWithTransactions(
      earmarks: [earmark],
      amounts: [earmark.id: (saved: 500, spent: 0)],
      accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)

    await store.load()

    #expect(store.earmarks.count == 1)
    #expect(store.earmarks.first?.name == "Holiday Fund")
  }

  @Test func testSortingByPosition() async throws {
    let e1 = Earmark(name: "E1", instrument: Instrument.defaultTestInstrument, position: 2)
    let e2 = Earmark(name: "E2", instrument: Instrument.defaultTestInstrument, position: 1)
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seedWithTransactions(
      earmarks: [e1, e2],
      amounts: [
        e1.id: (saved: 100, spent: 0),
        e2.id: (saved: 200, spent: 0),
      ],
      accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)

    await store.load()

    #expect(store.earmarks.count == 2)
    #expect(store.earmarks[0].name == "E2")
    #expect(store.earmarks[1].name == "E1")
  }

  @Test func testEarmarkInstrumentSetCorrectly() async throws {
    let e1 = Earmark(name: "Holiday", instrument: Instrument.defaultTestInstrument)
    let e2 = Earmark(name: "Car Repair", instrument: Instrument.defaultTestInstrument)
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank,
          balance: .zero(instrument: .defaultTestInstrument))
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [e1, e2],
      amounts: [
        e1.id: (saved: 500, spent: 0),
        e2.id: (saved: 300, spent: 0),
      ],
      accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)

    await store.load()

    #expect(store.earmarks.count == 2)
    #expect(store.earmarks[0].instrument == Instrument.defaultTestInstrument)
    #expect(store.earmarks[1].instrument == Instrument.defaultTestInstrument)
  }

  // MARK: - applyDelta (position-based)

  @Test func testApplyDeltaAdjustsPositionsAndBalance() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank,
          balance: .zero(instrument: .defaultTestInstrument))
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "Holiday Fund", instrument: instrument)],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)
    await store.load()

    store.applyDelta(
      earmarkDeltas: [earmarkId: [instrument: -100]],
      savedDeltas: [:],
      spentDeltas: [earmarkId: [instrument: 100]]
    )

    #expect(store.earmarks.by(id: earmarkId)?.positions.first?.quantity == 400)
    #expect(store.earmarks.by(id: earmarkId)?.savedPositions.first?.quantity == 500)
    #expect(store.earmarks.by(id: earmarkId)?.spentPositions.first?.quantity == 100)
  }

  @Test func testApplyDeltaWithSavedIncreasesBalance() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank,
          balance: .zero(instrument: .defaultTestInstrument))
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "Holiday Fund", instrument: instrument)],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)
    await store.load()

    store.applyDelta(
      earmarkDeltas: [earmarkId: [instrument: 200]],
      savedDeltas: [earmarkId: [instrument: 200]],
      spentDeltas: [:]
    )

    #expect(store.earmarks.by(id: earmarkId)?.positions.first?.quantity == 700)
    #expect(store.earmarks.by(id: earmarkId)?.savedPositions.first?.quantity == 700)
  }

  @Test func testApplyDeltaAffectsMultipleEarmarks() async throws {
    let earmark1Id = UUID()
    let earmark2Id = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank,
          balance: .zero(instrument: .defaultTestInstrument))
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(id: earmark1Id, name: "Holiday", instrument: instrument),
        Earmark(id: earmark2Id, name: "Car", instrument: instrument),
      ],
      amounts: [
        earmark1Id: (saved: 500, spent: 0),
        earmark2Id: (saved: 300, spent: 0),
      ],
      accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)
    await store.load()

    store.applyDelta(
      earmarkDeltas: [
        earmark1Id: [instrument: -100],
        earmark2Id: [instrument: 50],
      ],
      savedDeltas: [earmark2Id: [instrument: 50]],
      spentDeltas: [earmark1Id: [instrument: 100]]
    )

    #expect(store.earmarks.by(id: earmark1Id)?.positions.first?.quantity == 400)
    #expect(store.earmarks.by(id: earmark1Id)?.spentPositions.first?.quantity == 100)
    #expect(store.earmarks.by(id: earmark2Id)?.positions.first?.quantity == 350)
    #expect(store.earmarks.by(id: earmark2Id)?.savedPositions.first?.quantity == 350)
  }

  // MARK: - convertedTotalBalance

  @Test func testConvertedTotalBalanceNilBeforeLoad() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)

    #expect(store.convertedTotalBalance == nil)
  }

  @Test func testConvertedTotalBalancePopulatedAfterLoad() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank,
          balance: .zero(instrument: .defaultTestInstrument))
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "Holiday Fund", instrument: instrument)],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)

    await store.load()
    try await Task.sleep(for: .milliseconds(50))

    #expect(store.convertedTotalBalance != nil)
    #expect(store.convertedTotalBalance?.quantity == 500)
  }

  @Test func testConvertedTotalBalanceExcludesNegativeEarmarks() async throws {
    let positiveId = UUID()
    let negativeId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank,
          balance: .zero(instrument: .defaultTestInstrument))
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(id: positiveId, name: "Holiday Fund", instrument: instrument),
        Earmark(id: negativeId, name: "Investments", instrument: instrument),
      ],
      amounts: [
        positiveId: (saved: 500, spent: 0),
        negativeId: (saved: -18950, spent: 0),
      ],
      accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)

    await store.load()
    try await Task.sleep(for: .milliseconds(50))

    // Individual balances should reflect true values
    #expect(store.convertedBalance(for: positiveId)?.quantity == 500)
    #expect(store.convertedBalance(for: negativeId)?.quantity == -18950)

    // Total should clamp negative earmarks to 0, so total = 500 (not 500 - 18950)
    #expect(store.convertedTotalBalance?.quantity == 500)
  }

  @Test func testConvertedTotalBalanceUpdatesAfterApplyDelta() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank,
          balance: .zero(instrument: .defaultTestInstrument))
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "Holiday Fund", instrument: instrument)],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)
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

  // MARK: - Per-earmark converted amounts

  @Test func testConvertedBalancePerEarmarkPopulatedAfterLoad() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank,
          balance: .zero(instrument: .defaultTestInstrument))
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "Holiday Fund", instrument: instrument)],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)

    await store.load()
    try await Task.sleep(for: .milliseconds(50))

    #expect(store.convertedBalance(for: earmarkId)?.quantity == 500)
    #expect(store.convertedSaved(for: earmarkId)?.quantity == 500)
    #expect(store.convertedSpent(for: earmarkId)?.quantity == 0)
  }

  @Test func testConvertedBalancePerEarmarkUpdatesAfterDelta() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank,
          balance: .zero(instrument: .defaultTestInstrument))
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "Holiday Fund", instrument: instrument)],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)
    await store.load()
    try await Task.sleep(for: .milliseconds(50))

    store.applyDelta(
      earmarkDeltas: [earmarkId: [instrument: -100]],
      savedDeltas: [:],
      spentDeltas: [earmarkId: [instrument: 100]]
    )
    try await Task.sleep(for: .milliseconds(50))

    #expect(store.convertedBalance(for: earmarkId)?.quantity == 400)
    #expect(store.convertedSpent(for: earmarkId)?.quantity == 100)
  }

  // MARK: - reorderEarmarks

  @Test func testReorderEarmarksUpdatesPositions() async throws {
    let e0 = Earmark(name: "First", instrument: .defaultTestInstrument, position: 0)
    let e1 = Earmark(name: "Second", instrument: .defaultTestInstrument, position: 1)
    let e2 = Earmark(name: "Third", instrument: .defaultTestInstrument, position: 2)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [e0, e1, e2], in: container)
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)
    await store.load()

    await store.reorderEarmarks(from: IndexSet(integer: 2), to: 0)

    #expect(store.visibleEarmarks[0].name == "Third")
    #expect(store.visibleEarmarks[1].name == "First")
    #expect(store.visibleEarmarks[2].name == "Second")
    #expect(store.visibleEarmarks[0].position == 0)
    #expect(store.visibleEarmarks[1].position == 1)
    #expect(store.visibleEarmarks[2].position == 2)
  }

  @Test func testReorderEarmarksSkipsHiddenEarmarks() async throws {
    let e0 = Earmark(name: "Visible1", instrument: .defaultTestInstrument, position: 0)
    let e1 = Earmark(
      name: "Hidden", instrument: .defaultTestInstrument, isHidden: true, position: 1)
    let e2 = Earmark(name: "Visible2", instrument: .defaultTestInstrument, position: 2)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [e0, e1, e2], in: container)
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)
    await store.load()

    await store.reorderEarmarks(from: IndexSet(integer: 1), to: 0)

    #expect(store.visibleEarmarks[0].name == "Visible2")
    #expect(store.visibleEarmarks[1].name == "Visible1")
    let hidden = store.earmarks.ordered.first { $0.isHidden }
    #expect(hidden?.position == 1)
  }

  @Test func testReorderSingleEarmarkIsNoOp() async throws {
    let e0 = Earmark(name: "Only", instrument: .defaultTestInstrument, position: 0)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [e0], in: container)
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)
    await store.load()

    await store.reorderEarmarks(from: IndexSet(integer: 0), to: 0)

    #expect(store.visibleEarmarks.count == 1)
    #expect(store.visibleEarmarks[0].position == 0)
  }

  @Test func testReorderEmptyListIsNoOp() async throws {
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [], in: container)
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)
    await store.load()

    await store.reorderEarmarks(from: IndexSet(integer: 0), to: 0)

    #expect(store.visibleEarmarks.isEmpty)
  }

  @Test func testReorderPersistsToRepository() async throws {
    let e0 = Earmark(name: "First", instrument: .defaultTestInstrument, position: 0)
    let e1 = Earmark(name: "Second", instrument: .defaultTestInstrument, position: 1)
    let e2 = Earmark(name: "Third", instrument: .defaultTestInstrument, position: 2)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [e0, e1, e2], in: container)
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)
    await store.load()

    await store.reorderEarmarks(from: IndexSet(integer: 2), to: 0)

    let persisted = try await backend.earmarks.fetchAll().sorted { $0.position < $1.position }
    #expect(persisted[0].name == "Third")
    #expect(persisted[1].name == "First")
    #expect(persisted[2].name == "Second")
    #expect(persisted[0].position == 0)
    #expect(persisted[1].position == 1)
    #expect(persisted[2].position == 2)
  }

  // MARK: - create / update

  @Test func testCreateAddsEarmark() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)

    let earmark = Earmark(name: "New Fund", instrument: .defaultTestInstrument)
    let created = await store.create(earmark)

    #expect(created != nil)
    #expect(created?.name == "New Fund")
    #expect(store.earmarks.count == 1)
    #expect(store.earmarks.first?.name == "New Fund")
  }

  @Test func testCreateReturnsNilOnFailure() async throws {
    let store = EarmarkStore(
      repository: FailingEarmarkRepository(), targetInstrument: .defaultTestInstrument)

    let result = await store.create(Earmark(name: "Fails", instrument: .defaultTestInstrument))

    #expect(result == nil)
    #expect(store.error != nil)
  }

  @Test func testCreateReloadsAfterSuccess() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)

    let e1 = Earmark(name: "First", instrument: .defaultTestInstrument)
    _ = await store.create(e1)
    let e2 = Earmark(name: "Second", instrument: .defaultTestInstrument)
    _ = await store.create(e2)

    #expect(store.earmarks.count == 2)
    #expect(store.earmarks.by(id: e1.id) != nil)
    #expect(store.earmarks.by(id: e2.id) != nil)
  }

  @Test func testUpdateModifiesEarmark() async throws {
    let earmark = Earmark(name: "Holiday Fund", instrument: .defaultTestInstrument)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [earmark], in: container)
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)
    await store.load()

    var modified = earmark
    modified.name = "Vacation Fund"
    let updated = await store.update(modified)

    #expect(updated != nil)
    #expect(updated?.name == "Vacation Fund")
    #expect(store.earmarks.by(id: earmark.id)?.name == "Vacation Fund")
  }

  @Test func testUpdateReturnsNilOnFailure() async throws {
    let store = EarmarkStore(
      repository: FailingEarmarkRepository(), targetInstrument: .defaultTestInstrument)

    let result = await store.update(Earmark(name: "Fails", instrument: .defaultTestInstrument))

    #expect(result == nil)
    #expect(store.error != nil)
  }

  // MARK: - Show Hidden

  @Test("visibleEarmarks excludes hidden earmarks by default")
  func hiddenEarmarksExcluded() async throws {
    let visible = Earmark(name: "Visible", instrument: Instrument.defaultTestInstrument)
    let hidden = Earmark(
      name: "Hidden", instrument: Instrument.defaultTestInstrument, isHidden: true)
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank,
          balance: .zero(instrument: .defaultTestInstrument))
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [visible, hidden],
      amounts: [
        visible.id: (saved: 500, spent: 0),
        hidden.id: (saved: 300, spent: 0),
      ],
      accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)

    await store.load()

    #expect(store.visibleEarmarks.count == 1)
    #expect(store.visibleEarmarks[0].name == "Visible")
  }

  @Test("visibleEarmarks includes hidden earmarks when showHidden is true")
  func hiddenEarmarksIncluded() async throws {
    let visible = Earmark(name: "Visible", instrument: Instrument.defaultTestInstrument)
    let hidden = Earmark(
      name: "Hidden", instrument: Instrument.defaultTestInstrument, isHidden: true)
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank,
          balance: .zero(instrument: .defaultTestInstrument))
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [visible, hidden],
      amounts: [
        visible.id: (saved: 500, spent: 0),
        hidden.id: (saved: 300, spent: 0),
      ],
      accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks, targetInstrument: .defaultTestInstrument)

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
