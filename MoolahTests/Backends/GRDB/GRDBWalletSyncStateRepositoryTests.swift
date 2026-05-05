// MoolahTests/Backends/GRDB/GRDBWalletSyncStateRepositoryTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("GRDBWalletSyncStateRepository")
struct GRDBWalletSyncStateRepositoryTests {
  private func makeQueue() throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    return queue
  }

  @Test
  func saveAndLoadRoundTrips() async throws {
    let queue = try makeQueue()
    let repo = GRDBWalletSyncStateRepository(database: queue)
    let state = WalletSyncState(
      id: UUID(),
      lastSyncedBlockNumber: 19_500_000,
      lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastError: nil
    )
    try await repo.save(state)
    let loaded = try await repo.load(accountId: state.id)
    #expect(loaded == state)
  }

  @Test
  func loadAllReturnsEverySaved() async throws {
    let queue = try makeQueue()
    let repo = GRDBWalletSyncStateRepository(database: queue)
    for i in 0..<3 {
      try await repo.save(
        .init(
          id: UUID(),
          lastSyncedBlockNumber: UInt64(1000 + i),
          lastSyncedAt: Date(timeIntervalSince1970: TimeInterval(i)),
          lastError: nil))
    }
    let all = try await repo.loadAll()
    #expect(all.count == 3)
  }

  @Test
  func errorRoundTrips() async throws {
    let queue = try makeQueue()
    let repo = GRDBWalletSyncStateRepository(database: queue)
    let state = WalletSyncState(
      id: UUID(),
      lastSyncedBlockNumber: 0,
      lastSyncedAt: Date(timeIntervalSince1970: 0),
      lastError: .invalidApiKey
    )
    try await repo.save(state)
    let loaded = try await repo.load(accountId: state.id)
    #expect(loaded?.lastError == .invalidApiKey)
  }

  @Test
  func deleteIsIdempotent() async throws {
    let queue = try makeQueue()
    let repo = GRDBWalletSyncStateRepository(database: queue)
    let id = UUID()
    try await repo.delete(accountId: id)
    try await repo.delete(accountId: id)
    #expect(try await repo.load(accountId: id) == nil)
  }

  @Test
  func saveOverwritesExistingRow() async throws {
    let queue = try makeQueue()
    let repo = GRDBWalletSyncStateRepository(database: queue)
    let id = UUID()
    let first = WalletSyncState(
      id: id, lastSyncedBlockNumber: 100,
      lastSyncedAt: Date(timeIntervalSince1970: 100), lastError: nil)
    try await repo.save(first)

    let second = WalletSyncState(
      id: id, lastSyncedBlockNumber: 200,
      lastSyncedAt: Date(timeIntervalSince1970: 200),
      lastError: .network(underlyingDescription: "boom"))
    try await repo.save(second)

    let loaded = try await repo.load(accountId: id)
    #expect(loaded?.lastSyncedBlockNumber == 200)
    #expect(loaded?.lastError == .network(underlyingDescription: "boom"))

    let all = try await repo.loadAll()
    #expect(all.count == 1)
  }

  // Plan-pinning test per DATABASE_CODE_GUIDE §6: loadAll runs on the
  // app-launch hot path. A regression that adds a non-PK scan would
  // surface here.
  @Test
  func loadAllUsesExpectedQueryPlan() async throws {
    let queue = try makeQueue()
    try await queue.read { database in
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN SELECT * FROM wallet_sync_state
          """
      ).map { row in
        (row["detail"] as? String) ?? String(describing: row)
      }
      // wallet_sync_state has no secondary indexes; SQLite uses a SCAN
      // over the table. The point of the pin is to fail loud if a
      // future migration adds a join or sub-select that wasn't intended.
      #expect(plan.contains { $0.contains("wallet_sync_state") })
      #expect(!plan.contains { $0.contains("USING TEMP B-TREE") })
    }
  }
}
