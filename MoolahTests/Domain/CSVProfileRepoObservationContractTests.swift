import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("CSVImportProfileRepository observation contract")
struct CSVProfileRepoObservationContractTests {

  // MARK: - observeAll()

  @Test("initial emission reflects current DB state")
  func initialEmission() async throws {
    let (backend, _) = try TestBackend.create()
    var iterator = backend.csvImportProfiles.observeAll().makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial?.isEmpty == true)
  }

  @Test("create emits new value")
  func createEmits() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank, instrument: .AUD,
        positions: [], position: 0, isHidden: false), openingBalance: nil)
    var iterator = backend.csvImportProfiles.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // initial empty

    _ = try await backend.csvImportProfiles.create(
      CSVImportProfile(
        accountId: accountId,
        parserIdentifier: "generic-bank",
        headerSignature: ["date", "amount", "description"]))

    let afterCreate = await iterator.next()
    #expect(afterCreate?.count == 1)
    #expect(afterCreate?.first?.parserIdentifier == "generic-bank")
  }

  @Test("update emits new value")
  func updateEmits() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank, instrument: .AUD,
        positions: [], position: 0, isHidden: false), openingBalance: nil)
    let created = try await backend.csvImportProfiles.create(
      CSVImportProfile(
        accountId: accountId,
        parserIdentifier: "generic-bank",
        headerSignature: ["date", "amount", "description"]))

    var iterator = backend.csvImportProfiles.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // initial — single profile

    var updated = created
    updated.filenamePattern = "cba-*.csv"
    _ = try await backend.csvImportProfiles.update(updated)

    let after = await iterator.next()
    #expect(after?.first?.filenamePattern == "cba-*.csv")
  }

  @Test("no-op update does not re-emit (removeDuplicates works)")
  func noOpUpdateDoesNotReEmit() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank, instrument: .AUD,
        positions: [], position: 0, isHidden: false), openingBalance: nil)
    let created = try await backend.csvImportProfiles.create(
      CSVImportProfile(
        accountId: accountId,
        parserIdentifier: "generic-bank",
        headerSignature: ["date", "amount", "description"]))

    var iterator = backend.csvImportProfiles.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // discard initial emission (already-created profile)

    // No-op update — same fields as the existing record.
    _ = try await backend.csvImportProfiles.update(created)

    // Wait briefly; if a duplicate emission would arrive, it would
    // arrive within this window. The semantic is: no second emission.
    // We track receipt via a `Bool` rather than capturing the value
    // into an optional collection (SwiftLint's
    // `discouraged_optional_collection`).
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
    let stream = backend.csvImportProfiles.observeErrors()
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
