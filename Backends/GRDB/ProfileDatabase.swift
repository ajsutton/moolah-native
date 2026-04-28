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
  static func open(at url: URL) throws -> DatabaseQueue {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let queue = try DatabaseQueue(
      path: url.path,
      configuration: configuration())
    try ProfileSchema.migrator.migrate(queue)
    return queue
  }

  /// In-memory queue for tests and previews. Identical configuration and
  /// schema to a production queue; differs only in storage location.
  static func openInMemory() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: configuration())
    try ProfileSchema.migrator.migrate(queue)
    return queue
  }

  // MARK: - Configuration

  private static func configuration() -> Configuration {
    var config = Configuration()
    config.prepareDatabase { database in
      // Project PRAGMA defaults — see `guides/DATABASE_SCHEMA_GUIDE.md` §5.
      // `journal_mode = WAL` is set persistently by the first connection
      // that opens a fresh file; subsequent connections inherit it from
      // the file header.
      try database.execute(
        sql: """
          PRAGMA foreign_keys = ON;
          PRAGMA synchronous = NORMAL;
          PRAGMA busy_timeout = 5000;
          PRAGMA temp_store = MEMORY;
          PRAGMA cache_size = -8000;
          PRAGMA mmap_size = 0;
          PRAGMA optimize = 0x10002;
          """)
    }
    return config
  }
}
