import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("CategoryRepository observation contract")
struct CategoryRepoObservationContractTests {

  // MARK: - observeAll()

  @Test("initial emission reflects current DB state")
  func initialEmission() async throws {
    let (backend, _) = try TestBackend.create()
    var iterator = backend.categories.observeAll().makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial?.isEmpty == true)
  }

  @Test("create emits new value")
  func createEmits() async throws {
    let (backend, _) = try TestBackend.create()
    var iterator = backend.categories.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // initial empty

    _ = try await backend.categories.create(
      Moolah.Category(name: "Groceries")
    )

    let afterCreate = await iterator.next()
    #expect(afterCreate?.count == 1)
    #expect(afterCreate?.first?.name == "Groceries")
  }

  @Test("update emits new value")
  func updateEmits() async throws {
    let (backend, _) = try TestBackend.create()
    let created = try await backend.categories.create(
      Moolah.Category(name: "Groceries")
    )
    var iterator = backend.categories.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // initial — single category
    var updated = created
    updated.name = "Food"
    _ = try await backend.categories.update(updated)
    let after = await iterator.next()
    #expect(after?.first?.name == "Food")
  }

  @Test("no-op update does not re-emit (removeDuplicates works)")
  func noOpUpdateDoesNotReEmit() async throws {
    let (backend, _) = try TestBackend.create()
    let created = try await backend.categories.create(
      Moolah.Category(name: "Groceries")
    )

    var iterator = backend.categories.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // discard initial emission (already-created category)

    // No-op update — same fields as the existing record.
    _ = try await backend.categories.update(created)

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
    let stream = backend.categories.observeErrors()
    let pollTask = Task<(any Error)?, Never> {
      var iterator = stream.makeAsyncIterator()
      return await iterator.next()
    }
    try await Task.sleep(for: .milliseconds(100))
    pollTask.cancel()
    let surfaced = await pollTask.value
    #expect(surfaced == nil)
  }
}
