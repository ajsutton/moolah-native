import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("AccountRepository observation contract")
struct AccountRepoObservationContractTests {

  @Test("initial emission reflects current DB state")
  func initialEmission() async throws {
    let (backend, _) = try TestBackend.create()
    var iterator = backend.accounts.observeAll().makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial?.isEmpty == true)
  }

  @Test("create emits new value")
  func createEmits() async throws {
    let (backend, _) = try TestBackend.create()
    var iterator = backend.accounts.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // initial empty

    _ = try await backend.accounts.create(
      Account(name: "A", type: .bank, instrument: .defaultTestInstrument),
      openingBalance: nil
    )

    let afterCreate = await iterator.next()
    #expect(afterCreate?.count == 1)
    #expect(afterCreate?.first?.name == "A")
  }

  @Test("update emits new value")
  func updateEmits() async throws {
    let (backend, _) = try TestBackend.create()
    let created = try await backend.accounts.create(
      Account(name: "A", type: .bank, instrument: .defaultTestInstrument),
      openingBalance: nil
    )
    var iterator = backend.accounts.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // initial — single account
    var updated = created
    updated.name = "Renamed"
    _ = try await backend.accounts.update(updated)
    let after = await iterator.next()
    #expect(after?.first?.name == "Renamed")
  }

  @Test("no-op update does not re-emit (removeDuplicates works)")
  func noOpUpdateDoesNotReEmit() async throws {
    let (backend, _) = try TestBackend.create()
    let created = try await backend.accounts.create(
      Account(name: "A", type: .bank, instrument: .defaultTestInstrument),
      openingBalance: nil
    )

    var iterator = backend.accounts.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // discard initial emission (already-created account)

    // No-op update — same fields as the existing record.
    _ = try await backend.accounts.update(created)

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
    // We don't have a clean way to inject a programmer-bug error into
    // the live repository. This test is a placeholder for the wiring;
    // the bridge unit test in Stage 1 covers the actual error
    // propagation. Asserting only that observeErrors() is callable
    // and that, on a healthy repo, the stream stays quiet for at least
    // a short grace window.
    let (backend, _) = try TestBackend.create()
    let stream = backend.accounts.observeErrors()
    let pollTask = Task<(any Error)?, Never> {
      var iterator = stream.makeAsyncIterator()
      return await iterator.next()
    }
    try await Task.sleep(for: .milliseconds(100))
    pollTask.cancel()
    // After cancellation the iterator returns nil promptly because the
    // AsyncStream's onTermination handler tears down the underlying
    // observation. A non-nil result here would mean the repository
    // surfaced an unexpected error to the channel.
    let surfaced = await pollTask.value
    #expect(surfaced == nil)
  }

  // MARK: - Error categorisation
  //
  // We can't drive a live repository through SQLITE_FULL or SQLITE_ERROR
  // without poking SQLite VFS internals, so the categorisation contract
  // is verified two ways: a direct unit test of the predicate here, and
  // a synthetic-stream test of the retry loop in
  // `RetryingAsyncStreamTests`.

  @Test("isProgrammerBugError categorises SQLITE_ERROR as a programmer bug")
  func categorisationProgrammerBug() {
    let error = DatabaseError(resultCode: .SQLITE_ERROR, message: "no such table")
    #expect(isProgrammerBugError(error))
  }

  @Test("isProgrammerBugError categorises transient I/O errors as recoverable")
  func categorisationTransient() {
    let full = DatabaseError(resultCode: .SQLITE_FULL, message: "disk full")
    let ioerr = DatabaseError(resultCode: .SQLITE_IOERR, message: "io error")
    #expect(isProgrammerBugError(full) == false)
    #expect(isProgrammerBugError(ioerr) == false)
  }

  @Test("isProgrammerBugError treats non-DatabaseError as recoverable")
  func categorisationNonDatabaseError() {
    struct OtherError: Error {}
    #expect(isProgrammerBugError(OtherError()) == false)
  }
}
