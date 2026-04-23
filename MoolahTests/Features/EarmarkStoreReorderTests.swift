import Foundation
import Testing

@testable import Moolah

@Suite("EarmarkStore -- Reorder")
@MainActor
struct EarmarkStoreReorderTests {
  @Test
  func testReorderEarmarksUpdatesPositions() async throws {
    let first = Earmark(name: "First", instrument: .defaultTestInstrument, position: 0)
    let second = Earmark(name: "Second", instrument: .defaultTestInstrument, position: 1)
    let third = Earmark(name: "Third", instrument: .defaultTestInstrument, position: 2)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [first, second, third], in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    await store.reorderEarmarks(from: IndexSet(integer: 2), to: 0)

    #expect(store.visibleEarmarks[0].name == "Third")
    #expect(store.visibleEarmarks[1].name == "First")
    #expect(store.visibleEarmarks[2].name == "Second")
    #expect(store.visibleEarmarks[0].position == 0)
    #expect(store.visibleEarmarks[1].position == 1)
    #expect(store.visibleEarmarks[2].position == 2)
  }

  @Test
  func testReorderEarmarksSkipsHiddenEarmarks() async throws {
    let firstVisible = Earmark(name: "Visible1", instrument: .defaultTestInstrument, position: 0)
    let hidden = Earmark(
      name: "Hidden", instrument: .defaultTestInstrument, isHidden: true, position: 1)
    let secondVisible = Earmark(name: "Visible2", instrument: .defaultTestInstrument, position: 2)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [firstVisible, hidden, secondVisible], in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    await store.reorderEarmarks(from: IndexSet(integer: 1), to: 0)

    #expect(store.visibleEarmarks[0].name == "Visible2")
    #expect(store.visibleEarmarks[1].name == "Visible1")
    let hiddenAfter = store.earmarks.ordered.first { $0.isHidden }
    #expect(hiddenAfter?.position == 1)
  }

  @Test
  func testReorderSingleEarmarkIsNoOp() async throws {
    let only = Earmark(name: "Only", instrument: .defaultTestInstrument, position: 0)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [only], in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    await store.reorderEarmarks(from: IndexSet(integer: 0), to: 0)

    #expect(store.visibleEarmarks.count == 1)
    #expect(store.visibleEarmarks[0].position == 0)
  }

  @Test
  func testReorderEmptyListIsNoOp() async throws {
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [], in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    await store.reorderEarmarks(from: IndexSet(integer: 0), to: 0)

    #expect(store.visibleEarmarks.isEmpty)
  }

  @Test
  func testReorderPersistsToRepository() async throws {
    let first = Earmark(name: "First", instrument: .defaultTestInstrument, position: 0)
    let second = Earmark(name: "Second", instrument: .defaultTestInstrument, position: 1)
    let third = Earmark(name: "Third", instrument: .defaultTestInstrument, position: 2)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [first, second, third], in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
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

  @Test
  func testReorderSurfacesErrorOnFailure() async throws {
    let first = Earmark(name: "First", instrument: .defaultTestInstrument, position: 0)
    let second = Earmark(name: "Second", instrument: .defaultTestInstrument, position: 1)
    let third = Earmark(name: "Third", instrument: .defaultTestInstrument, position: 2)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [first, second, third], in: container)
    let failing = UpdateFailingEarmarkRepository(wrapping: backend.earmarks)
    let store = EarmarkStore(
      repository: failing, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    failing.failUpdates = true
    await store.reorderEarmarks(from: IndexSet(integer: 2), to: 0)

    #expect(store.error != nil)
  }

  @Test
  func testReorderRollsBackOnFailure() async throws {
    let first = Earmark(name: "First", instrument: .defaultTestInstrument, position: 0)
    let second = Earmark(name: "Second", instrument: .defaultTestInstrument, position: 1)
    let third = Earmark(name: "Third", instrument: .defaultTestInstrument, position: 2)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [first, second, third], in: container)
    let failing = UpdateFailingEarmarkRepository(wrapping: backend.earmarks)
    let store = EarmarkStore(
      repository: failing, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    // First update succeeds (persists partial reorder on the server), second
    // update throws — exercises the reconcile-after-partial-write path.
    failing.failAfter = 1
    await store.reorderEarmarks(from: IndexSet(integer: 2), to: 0)

    // Local store state is reconciled with the repository (not the stale
    // pre-reorder snapshot, since one write landed).
    let persisted = try await backend.earmarks.fetchAll().sorted { $0.position < $1.position }
    let storeOrdered = store.earmarks.ordered.sorted { $0.position < $1.position }
    #expect(storeOrdered.map(\.id) == persisted.map(\.id))
    #expect(storeOrdered.map(\.position) == persisted.map(\.position))
    #expect(store.error != nil)
  }
}

// MARK: - Test helpers

/// Wraps a real repository but can be configured to fail `update` calls so
/// tests can exercise error paths without mocking.
@MainActor
private final class UpdateFailingEarmarkRepository: EarmarkRepository {
  private let wrapped: any EarmarkRepository
  /// When `true`, every `update` call throws immediately.
  var failUpdates: Bool = false
  /// When non-nil, the first `failAfter` calls succeed; subsequent calls
  /// throw. Useful for simulating partial writes.
  var failAfter: Int?
  private var updateCount: Int = 0

  init(wrapping repository: any EarmarkRepository) {
    self.wrapped = repository
  }

  func fetchAll() async throws -> [Earmark] {
    try await wrapped.fetchAll()
  }

  func create(_ earmark: Earmark) async throws -> Earmark {
    try await wrapped.create(earmark)
  }

  func update(_ earmark: Earmark) async throws -> Earmark {
    if failUpdates {
      throw BackendError.networkUnavailable
    }
    if let threshold = failAfter, updateCount >= threshold {
      throw BackendError.networkUnavailable
    }
    updateCount += 1
    return try await wrapped.update(earmark)
  }

  func fetchBudget(earmarkId: UUID) async throws -> [EarmarkBudgetItem] {
    try await wrapped.fetchBudget(earmarkId: earmarkId)
  }

  func setBudget(earmarkId: UUID, categoryId: UUID, amount: InstrumentAmount) async throws {
    try await wrapped.setBudget(earmarkId: earmarkId, categoryId: categoryId, amount: amount)
  }
}
