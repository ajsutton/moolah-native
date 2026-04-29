// Backends/GRDB/ProfileDatabase.swift

import Foundation
import GRDB

/// Factory for the per-profile GRDB `DatabaseQueue`.
///
/// The queue is owned by `ProfileSession` (one per active profile). Connect
/// once at profile activation; let the queue go out of scope on profile
/// switch / sign-out / delete.
///
/// See `guides/DATABASE_SCHEMA_GUIDE.md` §2 (lifecycle) and §5 (PRAGMAs)
/// for the rules this factory enforces.
enum ProfileDatabase {
  /// Open (or create) the profile DB at `url` and apply pending migrations.
  ///
  /// On-disk databases are required to use `journal_mode = WAL` per
  /// `guides/DATABASE_SCHEMA_GUIDE.md` §5. WAL is enabled via
  /// `Configuration.journalMode = .wal` (which triggers GRDB's
  /// `setUpWALMode`) and verified by reading `PRAGMA journal_mode` back
  /// after the queue is constructed.
  static func open(at url: URL) throws -> DatabaseQueue {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let queue = try DatabaseQueue(
      path: url.path,
      configuration: configuration(walMode: true))
    try ProfileSchema.migrator.migrate(queue)
    try assertJournalMode(queue, expected: "wal")
    return queue
  }

  /// In-memory queue for tests and previews. Identical configuration and
  /// schema to a production queue, except WAL is not requested — SQLite
  /// rejects WAL on `:memory:` databases (see sqlite.org WAL docs).
  static func openInMemory() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: configuration(walMode: false))
    try ProfileSchema.migrator.migrate(queue)
    return queue
  }

  // MARK: - Configuration

  private static func configuration(walMode: Bool) -> Configuration {
    var config = Configuration()
    if walMode {
      // Triggers GRDB's `setUpWALMode` on the first connection so the
      // header is rewritten to WAL and inherited by subsequent opens.
      config.journalMode = .wal
    }
    config.prepareDatabase { database in
      try GRDBPragmas.applyDefaults(to: database)
    }
    return config
  }

  /// Reads `PRAGMA journal_mode` back from the live queue and traps if it
  /// does not match the expected mode. WAL is required per
  /// `guides/DATABASE_SCHEMA_GUIDE.md` §5 ("verified on every open"), so a
  /// mismatch means the DB silently fell back to journalled mode and is
  /// running with weaker concurrency / durability guarantees than the
  /// project assumes.
  private static func assertJournalMode(
    _ queue: DatabaseQueue, expected: String
  ) throws {
    let actual = try queue.read { database -> String in
      try String.fetchOne(database, sql: "PRAGMA journal_mode") ?? ""
    }
    precondition(
      actual.lowercased() == expected.lowercased(),
      "Profile DB opened with journal_mode='\(actual)', expected '\(expected)'"
    )
  }
}
