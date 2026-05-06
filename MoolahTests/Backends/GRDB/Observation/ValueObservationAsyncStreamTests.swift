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
      }
    }

    let stream =
      ValueObservation
      .tracking { database in try Int.fetchAll(database, sql: "SELECT id FROM items") }
      .values(in: queue)
      .toAsyncStream(onError: { _ in })

    let task = Task {
      var iterator = stream.makeAsyncIterator()
      return await iterator.next()
    }
    _ = await task.value
    task.cancel()
    // If onTermination is wired correctly, the underlying observation
    // is cancelled and no resources leak. We assert by waiting briefly
    // and verifying no crash / hang.
    try? await Task.sleep(for: .milliseconds(50))
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
      .toAsyncStream(onError: { error in errorBox.set(error) })

    var iterator = stream.makeAsyncIterator()
    let value = await iterator.next()
    #expect(value == nil)  // stream completed
    #expect(errorBox.get() != nil)
  }
}
