import Foundation
import Testing

@testable import Moolah

@Suite("EarmarkStore -- Create/Update/Hide")
@MainActor
struct EarmarkStoreMutationTests {
  @Test func testCreateAddsEarmark() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    let earmark = Earmark(name: "New Fund", instrument: .defaultTestInstrument)
    let created = await store.create(earmark)

    #expect(created != nil)
    #expect(created?.name == "New Fund")
    #expect(store.earmarks.count == 1)
    #expect(store.earmarks.first?.name == "New Fund")
  }

  @Test func testCreateReturnsNilOnFailure() async throws {
    let store = EarmarkStore(
      repository: FailingEarmarkRepository(),
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    let result = await store.create(Earmark(name: "Fails", instrument: .defaultTestInstrument))

    #expect(result == nil)
    #expect(store.error != nil)
  }

  @Test func testCreateReloadsAfterSuccess() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    let first = Earmark(name: "First", instrument: .defaultTestInstrument)
    _ = await store.create(first)
    let second = Earmark(name: "Second", instrument: .defaultTestInstrument)
    _ = await store.create(second)

    #expect(store.earmarks.count == 2)
    #expect(store.earmarks.by(id: first.id) != nil)
    #expect(store.earmarks.by(id: second.id) != nil)
  }

  @Test func testUpdateModifiesEarmark() async throws {
    let earmark = Earmark(name: "Holiday Fund", instrument: .defaultTestInstrument)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [earmark], in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
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
      repository: FailingEarmarkRepository(),
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    let result = await store.update(Earmark(name: "Fails", instrument: .defaultTestInstrument))

    #expect(result == nil)
    #expect(store.error != nil)
  }

  @Test func testHideMarksEarmarkHidden() async throws {
    let earmark = Earmark(name: "Vacation", instrument: .defaultTestInstrument)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [earmark], in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    let result = await store.hide(earmark)

    #expect(result?.isHidden == true)
    #expect(store.earmarks.by(id: earmark.id)?.isHidden == true)
    #expect(store.visibleEarmarks.contains(where: { $0.id == earmark.id }) == false)
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
