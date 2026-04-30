// Backends/GRDB/ProfileIndexDatabase.swift

import Foundation
import GRDB

/// Factory for the app-scoped profile-index `DatabaseQueue`.
///
/// One database per app install — independent of any per-profile
/// `data.sqlite`. Holds one row per CloudKit profile so the profile
/// picker can list profiles before any of them is activated. Lives at
/// `<URL.moolahScopedApplicationSupport>/Moolah/profile-index.sqlite`.
///
/// The factory mirrors `ProfileDatabase` so the PRAGMA configuration
/// stays in lock-step. See `guides/DATABASE_SCHEMA_GUIDE.md` §2
/// (lifecycle) and §5 (PRAGMAs) for the rules this factory enforces.
enum ProfileIndexDatabase {
  /// Open (or create) the profile-index DB at `url` and apply pending
  /// migrations.
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
    try ProfileIndexSchema.migrator.migrate(queue)
    try assertJournalMode(queue, expected: "wal")
    return queue
  }

  /// In-memory queue for tests and previews. Identical configuration and
  /// schema to a production queue, except WAL is not requested — SQLite
  /// rejects WAL on `:memory:` databases (see sqlite.org WAL docs).
  static func openInMemory() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: configuration(walMode: false))
    try ProfileIndexSchema.migrator.migrate(queue)
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
      "Profile-index DB opened with journal_mode='\(actual)', expected '\(expected)'"
    )
  }
}
