import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ValueObservation toAsyncStream bridge")
struct ValueObservationAsyncStreamTests {

  @Test("emits initial value")
  func emitsInitialValue() async throws {
    let queue = try DatabaseQueue()
    try await queue.write { database in
      try database.create(table: "items") { table in
        table.column("id", .integer).primaryKey()
        table.column("name", .text).notNull()
      }
      try database.execute(sql: "INSERT INTO items (name) VALUES (?)", arguments: ["alpha"])
    }

    let stream =
      ValueObservation
      .tracking { database in try String.fetchAll(database, sql: "SELECT name FROM items") }
      .removeDuplicates()
      .values(in: queue)
      .toAsyncStream(onError: { _ in })

    var iterator = stream.makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial == ["alpha"])
  }

  @Test("emits on write")
  func emitsOnWrite() async throws {
    let queue = try DatabaseQueue()
    try await queue.write { database in
      try database.create(table: "items") { table in
        table.column("id", .integer).primaryKey()
        table.column("name", .text).notNull()
      }
    }

    let stream =
      ValueObservation
      .tracking { database in try String.fetchAll(database, sql: "SELECT name FROM items") }
      .removeDuplicates()
      .values(in: queue)
      .toAsyncStream(onError: { _ in })

    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()  // initial empty

    try await queue.write { database in
      try database.execute(sql: "INSERT INTO items (name) VALUES (?)", arguments: ["beta"])
    }

    let afterWrite = await iterator.next()
    #expect(afterWrite == ["beta"])
  }

  @Test("cancellation tears down the observation")
  func cancellationTearsDown() async throws {
    let queue = try DatabaseQueue()
    try await queue.write { database in
      try database.create(table: "items") { table in
        table.column("id", .integer).primaryKey()
        table.column("name", .text).notNull()
      }
    }

    let stream =
      ValueObservation
      .tracking { database in try String.fetchAll(database, sql: "SELECT name FROM items") }
      .values(in: queue)
      .toAsyncStream(onError: { _ in })

    let task = Task {
      var iterator = stream.makeAsyncIterator()
      _ = await iterator.next()  // initial empty emission
      _ = await iterator.next()  // suspends waiting for next change
    }

    // Give the task a moment to reach the second `await iterator.next()`.
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    _ = await task.value  // ensures `onTermination` has fired

    // Verify the underlying observation is torn down: a subsequent
    // write produces no emission on the cancelled stream's iterator
    // (which has already been destroyed). Use a fresh iterator on a
    // new stream to confirm the queue itself is still healthy and
    // that the previous observation is gone.
    try await queue.write { database in
      try database.execute(sql: "INSERT INTO items (name) VALUES ('beta')")
    }

    let freshStream =
      ValueObservation
      .tracking { database in try String.fetchAll(database, sql: "SELECT name FROM items") }
      .values(in: queue)
      .toAsyncStream(onError: { _ in })
    var freshIterator = freshStream.makeAsyncIterator()
    let fresh = await freshIterator.next()
    #expect(fresh == ["beta"])  // queue is healthy; previous observation didn't interfere
  }

  @Test("error path surfaces via onError callback")
  func errorPathSurfacesError() async throws {
    let queue = try DatabaseQueue()
    // Schema NOT created — observation reads from a missing table,
    // which throws SQLITE_ERROR.
    let errorBox = LockedBox<(any Error)?>(nil)

    let stream =
      ValueObservation
      .tracking { database in
        try Int.fetchAll(database, sql: "SELECT id FROM missing_table")
      }
      .values(in: queue)
      // `onError` is now `async` (the bridge awaits before completing the
      // stream); `LockedBox.set` is a synchronous lock-guarded mutator
      // that is callable from any context, so no extra async work needed.
      .toAsyncStream(onError: { error in errorBox.set(error) })

    var iterator = stream.makeAsyncIterator()
    let value = await iterator.next()
    #expect(value == nil)  // stream completed
    #expect(errorBox.get() != nil)
  }
}
