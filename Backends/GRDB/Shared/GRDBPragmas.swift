// Backends/GRDB/Shared/GRDBPragmas.swift

import GRDB

/// Shared PRAGMA defaults applied to every on-disk and in-memory
/// `DatabaseQueue` in the GRDB backend. Centralised so every factory
/// (e.g. `ProfileDatabase`, `ProfileIndexDatabase`) stays in lock-step
/// with one another — duplicating the PRAGMA block per factory makes it
/// trivially easy for one to drift.
///
/// Called from each factory's `prepareDatabase` closure inside its
/// `Configuration` setup. The `journalMode = .wal` setting stays
/// per-factory in `Configuration` (only the project-PRAGMA block is
/// shared) because in-memory queues must skip WAL.
///
/// See `guides/DATABASE_SCHEMA_GUIDE.md` §5 for the rationale behind
/// each PRAGMA.
enum GRDBPragmas {
  /// Apply the project-standard PRAGMA defaults to `database`.
  static func applyDefaults(to database: Database) throws {
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
}
