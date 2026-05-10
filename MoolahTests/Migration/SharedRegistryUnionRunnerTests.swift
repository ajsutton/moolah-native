// MoolahTests/Migration/SharedRegistryUnionRunnerTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Confirms the shared-registry union runner walks every per-profile
/// DB, merges instrument + price-cache rows into the shared DB, and
/// gates re-runs via the UserDefaults flag.
@MainActor
@Suite("SharedRegistryUnionRunner", .serialized)
struct SharedRegistryUnionRunnerTests {

  // MARK: - Fixtures

  // `UserDefaults` is thread-safe but not declared `Sendable` in
  // Foundation, so opt out of the auto-derived check. The fixture
  // itself escapes to `nonisolated SharedRegistryUnionRunner.run` and
  // we touch `fixture.defaults` again on the main actor afterwards;
  // the underlying Obj-C class handles concurrent access internally.
  private struct Fixture: @unchecked Sendable {
    let sharedQueue: DatabaseQueue
    let profileQueues: [UUID: DatabaseQueue]
    let defaults: UserDefaults

    init(perProfileSeeds: [(UUID, (Database) throws -> Void)]) throws {
      self.sharedQueue = try ProfileIndexDatabase.openInMemory()
      var queues: [UUID: DatabaseQueue] = [:]
      for (id, seed) in perProfileSeeds {
        let queue = try ProfileDatabase.openInMemory()
        try queue.write { database in try seed(database) }
        queues[id] = queue
      }
      self.profileQueues = queues
      let suite = "shared-registry-union-tests-\(UUID().uuidString)"
      // `UserDefaults(suiteName:)` returns nil only for the reserved
      // names `kCFPreferencesCurrentApplication` and an empty string;
      // the unique suite generated above guarantees neither.
      // swiftlint:disable:next force_unwrapping
      self.defaults = UserDefaults(suiteName: suite)!
    }

  }

  /// Builds a `@Sendable` closure that opens a fixture's per-profile
  /// `DatabaseQueue`. Captures only the queues dictionary (a value-
  /// type `Dictionary` of `Sendable` `DatabaseQueue` references), not
  /// the `~Copyable` `Fixture`.
  private static func makeOpener(
    profileQueues: [UUID: DatabaseQueue]
  ) -> @Sendable (UUID) throws -> DatabaseQueue {
    let queues = profileQueues
    return { id in
      guard let queue = queues[id] else {
        struct MissingFixture: Error {}
        throw MissingFixture()
      }
      return queue
    }
  }

  /// `FileManager` stand-in that always reports the per-profile DB
  /// exists. Tests use in-memory queues so the real path doesn't.
  private final class AlwaysExistsFileManager: FileManager, @unchecked Sendable {
    override func fileExists(atPath _: String) -> Bool { true }
  }

  private static func seedInstrument(
    _ database: Database,
    id: String,
    coingeckoId: String,
    pricingStatus: String = "priced"
  ) throws {
    try database.execute(
      sql: """
        INSERT INTO instrument
        (id, record_name, kind, name, decimals, coingecko_id, pricing_status)
        VALUES (?, ?, 'cryptoToken', ?, 18, ?, ?)
        """,
      arguments: [id, id, "Token \(id)", coingeckoId, pricingStatus])
  }

  // MARK: - Tests

  @Test("union merges instrument rows from every profile DB into the shared registry")
  func unionMergesInstrumentRows() async throws {
    let profileA = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000a"))
    let profileB = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000b"))
    let fixture = try Fixture(perProfileSeeds: [
      (profileA, { try Self.seedInstrument($0, id: "1:0xaaa", coingeckoId: "aaa") }),
      (profileB, { try Self.seedInstrument($0, id: "1:0xbbb", coingeckoId: "bbb") }),
    ])

    await SharedRegistryUnionRunner.run(
      sharedQueue: fixture.sharedQueue,
      profileIds: [profileA, profileB],
      perProfileDatabase: Self.makeOpener(profileQueues: fixture.profileQueues),
      perProfileDatabaseURL: { _ in URL(fileURLWithPath: "/tmp/fake.sqlite") },
      fileManager: AlwaysExistsFileManager(),
      defaults: fixture.defaults)

    let ids: Set<String> = try await fixture.sharedQueue.read { database in
      Set(try String.fetchAll(database, sql: "SELECT id FROM instrument"))
    }
    #expect(ids.contains("1:0xaaa"))
    #expect(ids.contains("1:0xbbb"))
  }

  @Test("union applies spam-wins merge across profiles")
  func unionAppliesSpamWinsAcrossProfiles() async throws {
    // Profile A has bitcoin priced; profile B has bitcoin spam.
    // Result: spam wins regardless of iteration order.
    let profileA = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000a"))
    let profileB = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000b"))
    let fixture = try Fixture(perProfileSeeds: [
      (profileA, { try Self.seedInstrument($0, id: "bitcoin", coingeckoId: "bitcoin") }),
      (
        profileB,
        {
          try Self.seedInstrument(
            $0, id: "bitcoin", coingeckoId: "bitcoin", pricingStatus: "spam")
        }
      ),
    ])

    await SharedRegistryUnionRunner.run(
      sharedQueue: fixture.sharedQueue,
      profileIds: [profileA, profileB],
      perProfileDatabase: Self.makeOpener(profileQueues: fixture.profileQueues),
      perProfileDatabaseURL: { _ in URL(fileURLWithPath: "/tmp/fake.sqlite") },
      fileManager: AlwaysExistsFileManager(),
      defaults: fixture.defaults)

    let status: String? = try await fixture.sharedQueue.read { database in
      try String.fetchOne(
        database,
        sql: "SELECT pricing_status FROM instrument WHERE id = 'bitcoin'")
    }
    #expect(status == "spam")
  }

  @Test("re-running with the flag set is a no-op")
  func reRunningIsNoOpWhenFlagAlreadySet() async throws {
    let profileA = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000a"))
    let fixture = try Fixture(perProfileSeeds: [
      (profileA, { try Self.seedInstrument($0, id: "1:0xaaa", coingeckoId: "aaa") })
    ])
    fixture.defaults.set(true, forKey: SharedRegistryUnionRunner.unionFlagKey)

    await SharedRegistryUnionRunner.run(
      sharedQueue: fixture.sharedQueue,
      profileIds: [profileA],
      perProfileDatabase: Self.makeOpener(profileQueues: fixture.profileQueues),
      perProfileDatabaseURL: { _ in URL(fileURLWithPath: "/tmp/fake.sqlite") },
      fileManager: AlwaysExistsFileManager(),
      defaults: fixture.defaults)

    let count: Int? = try await fixture.sharedQueue.read { database in
      try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM instrument")
    }
    #expect(count == 0, "instrument table should still be empty when flag pre-set")
  }

  @Test("flag is set after run completes so subsequent runs are no-ops")
  func flagIsSetAfterRun() async throws {
    let profileA = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000a"))
    let fixture = try Fixture(perProfileSeeds: [
      (profileA, { try Self.seedInstrument($0, id: "1:0xaaa", coingeckoId: "aaa") })
    ])
    #expect(fixture.defaults.bool(forKey: SharedRegistryUnionRunner.unionFlagKey) == false)

    await SharedRegistryUnionRunner.run(
      sharedQueue: fixture.sharedQueue,
      profileIds: [profileA],
      perProfileDatabase: Self.makeOpener(profileQueues: fixture.profileQueues),
      perProfileDatabaseURL: { _ in URL(fileURLWithPath: "/tmp/fake.sqlite") },
      fileManager: AlwaysExistsFileManager(),
      defaults: fixture.defaults)

    #expect(fixture.defaults.bool(forKey: SharedRegistryUnionRunner.unionFlagKey))
  }

  @Test("a profile DB that fails to open is skipped without losing other profiles")
  func failingProfileIsSkippedAndOthersStillMerge() async throws {
    let profileA = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000a"))
    let profileFail = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000f"))
    let fixture = try Fixture(perProfileSeeds: [
      (profileA, { try Self.seedInstrument($0, id: "1:0xaaa", coingeckoId: "aaa") })
      // profileFail is intentionally not registered → throws on open
    ])

    await SharedRegistryUnionRunner.run(
      sharedQueue: fixture.sharedQueue,
      profileIds: [profileA, profileFail],
      perProfileDatabase: Self.makeOpener(profileQueues: fixture.profileQueues),
      perProfileDatabaseURL: { _ in URL(fileURLWithPath: "/tmp/fake.sqlite") },
      fileManager: AlwaysExistsFileManager(),
      defaults: fixture.defaults)

    let count: Int? = try await fixture.sharedQueue.read { database in
      try Int.fetchOne(
        database, sql: "SELECT COUNT(*) FROM instrument WHERE id = '1:0xaaa'")
    }
    #expect(count == 1, "profile A's row should still be merged despite profile-F failing")
    #expect(fixture.defaults.bool(forKey: SharedRegistryUnionRunner.unionFlagKey))
  }
}
