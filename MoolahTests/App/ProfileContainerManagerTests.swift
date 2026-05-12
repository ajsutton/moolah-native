import Foundation
import GRDB
import Testing

@testable import Moolah

// Serialised because some tests in this suite touch process-wide overrides
// (`URL.moolahApplicationSupportOverride`) and the in-memory queue cache.
@Suite("ProfileContainerManager", .serialized)
struct ProfileContainerManagerTests {
  @Test("forTesting() yields a working in-memory manager")
  @MainActor
  func testForTesting() throws {
    let manager = try ProfileContainerManager.forTesting()
    #expect(manager.inMemory == true)
    // Profile-index repository must round-trip an empty fetch on a
    // fresh manager.
    let queue = manager.profileIndexDatabase
    let rows = try queue.read { database in
      try ProfileRow.fetchAll(database)
    }
    #expect(rows.isEmpty)
  }

  @Test("opens a per-profile data database that is empty by default")
  @MainActor
  func testPerProfileDatabaseEmpty() throws {
    let manager = try ProfileContainerManager.forTesting()
    let profileId = UUID()
    let queue = try manager.database(for: profileId)
    let accountCount = try queue.read { database in
      try AccountRow.fetchCount(database)
    }
    let transactionCount = try queue.read { database in
      try TransactionRow.fetchCount(database)
    }
    #expect(accountCount == 0)
    #expect(transactionCount == 0)
  }

  @Test("returns the same DatabaseQueue for the same profile id (cache hit)")
  @MainActor
  func testDatabaseCaching() throws {
    let manager = try ProfileContainerManager.forTesting()
    let profileId = UUID()
    let queue1 = try manager.database(for: profileId)
    let queue2 = try manager.database(for: profileId)
    #expect(queue1 === queue2)
  }

  @Test("returns different DatabaseQueues for different profile ids")
  @MainActor
  func testDatabaseIsolation() throws {
    let manager = try ProfileContainerManager.forTesting()
    let queue1 = try manager.database(for: UUID())
    let queue2 = try manager.database(for: UUID())
    #expect(queue1 !== queue2)
  }

  @Test("evictCachedStore drops the cached DatabaseQueue so the next open yields a fresh queue")
  @MainActor
  func testEvictCachedStore() throws {
    let manager = try ProfileContainerManager.forTesting()
    let profileId = UUID()
    let queue1 = try manager.database(for: profileId)
    manager.evictCachedStore(for: profileId)
    let queue2 = try manager.database(for: profileId)
    // In-memory manager re-opens a fresh queue every time the cache is
    // empty (`ProfileDatabase.openInMemory()` returns a new instance).
    #expect(queue1 !== queue2)
  }

  @Test("deleteStore is a no-op on an in-memory manager and evicts the cache")
  @MainActor
  func testDeleteStoreInMemory() throws {
    let manager = try ProfileContainerManager.forTesting()
    let profileId = UUID()
    let queue1 = try manager.database(for: profileId)
    // Should not throw and should evict the cache entry.
    manager.deleteStore(for: profileId)
    let queue2 = try manager.database(for: profileId)
    #expect(queue1 !== queue2)
  }

  @Test("exposes a working GRDB profile-index repository wired to its database")
  @MainActor
  func testProfileIndexRepositoryRoundTrip() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let profile = Profile(
      id: UUID(),
      label: "Personal",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    try await manager.profileIndexRepository.upsert(profile)
    let loaded = try await manager.profileIndexRepository.fetchAll()
    #expect(loaded.count == 1)
    #expect(loaded.first?.id == profile.id)
    #expect(loaded.first?.label == "Personal")
  }
}
