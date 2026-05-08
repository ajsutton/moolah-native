import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("EarmarkRepository observation contract")
struct EarmarkRepoObservationContractTests {

  // MARK: - observeAll()

  @Test("initial emission reflects current DB state")
  func initialEmission() async throws {
    let (backend, _) = try TestBackend.create()
    var iterator = backend.earmarks.observeAll().makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial?.isEmpty == true)
  }

  @Test("create emits new value")
  func createEmits() async throws {
    let (backend, _) = try TestBackend.create()
    var iterator = backend.earmarks.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // initial empty

    _ = try await backend.earmarks.create(
      Earmark(name: "Test", instrument: .defaultTestInstrument)
    )

    let afterCreate = await iterator.next()
    #expect(afterCreate?.count == 1)
    #expect(afterCreate?.first?.name == "Test")
  }

  @Test("update emits new value")
  func updateEmits() async throws {
    let (backend, _) = try TestBackend.create()
    let created = try await backend.earmarks.create(
      Earmark(name: "Test", instrument: .defaultTestInstrument)
    )
    var iterator = backend.earmarks.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // initial — single earmark
    var updated = created
    updated.name = "Renamed"
    _ = try await backend.earmarks.update(updated)
    let after = await iterator.next()
    #expect(after?.first?.name == "Renamed")
  }

  @Test("no-op update does not re-emit (removeDuplicates works)")
  func noOpUpdateDoesNotReEmit() async throws {
    let (backend, _) = try TestBackend.create()
    let created = try await backend.earmarks.create(
      Earmark(name: "Test", instrument: .defaultTestInstrument)
    )

    var iterator = backend.earmarks.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // discard initial emission (already-created earmark)

    // No-op update — same fields as the existing record.
    _ = try await backend.earmarks.update(created)

    // Wait briefly; if a duplicate emission would arrive, it would
    // arrive within this window. The semantic is: no second emission.
    // We track receipt via a `Bool` rather than capturing the value into
    // an optional collection (SwiftLint's `discouraged_optional_collection`).
    let receivedBox = LockedBox<Bool>(false)
    let pollTask = Task<Void, Never> { [receivedBox] in
      var localIterator = iterator
      if await localIterator.next() != nil {
        receivedBox.set(true)
      }
    }
    try? await Task.sleep(for: .milliseconds(200))
    pollTask.cancel()
    _ = await pollTask.value
    #expect(
      receivedBox.get() == false,
      "removeDuplicates failed: a no-op update produced a re-emission")
  }

  @Test("observeErrors stays quiet on a healthy repository")
  func observeErrorsOnHealthyRepository() async throws {
    let (backend, _) = try TestBackend.create()
    let stream = backend.earmarks.observeErrors()
    let pollTask = Task<(any Error)?, Never> {
      var iterator = stream.makeAsyncIterator()
      return await iterator.next()
    }
    try await Task.sleep(for: .milliseconds(100))
    pollTask.cancel()
    let surfaced = await pollTask.value
    #expect(surfaced == nil)
  }

  // MARK: - observeBudget(earmarkId:)

  @Test("observeBudget initial emission reflects current DB state")
  func observeBudgetInitialEmission() async throws {
    let (backend, _) = try TestBackend.create()
    let earmark = try await backend.earmarks.create(
      Earmark(name: "Test", instrument: .defaultTestInstrument)
    )
    var iterator = backend.earmarks.observeBudget(earmarkId: earmark.id).makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial?.isEmpty == true)
  }

  @Test("budget item insert emits")
  func observeBudgetEmitsOnInsert() async throws {
    let (backend, _) = try TestBackend.create()
    let earmark = try await backend.earmarks.create(
      Earmark(name: "Test", instrument: .defaultTestInstrument)
    )
    var iterator = backend.earmarks.observeBudget(earmarkId: earmark.id).makeAsyncIterator()
    _ = await iterator.next()  // initial empty

    let categoryId = UUID()
    let amount = InstrumentAmount(quantity: dec("100.00"), instrument: .defaultTestInstrument)
    try await backend.earmarks.setBudget(
      earmarkId: earmark.id, categoryId: categoryId, amount: amount)

    let afterInsert = await iterator.next()
    #expect(afterInsert?.count == 1)
    #expect(afterInsert?.first?.categoryId == categoryId)
    #expect(afterInsert?.first?.amount.quantity == dec("100.00"))
  }
}
