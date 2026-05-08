// Backends/CoinGecko/SQLiteCoinGeckoCatalog+SQLite.swift
import Foundation
import SQLite3

/// Thin SQLite C-API wrappers used by `SQLiteCoinGeckoCatalog`'s schema
/// bootstrap, replace-all, and search/refresh extensions. All helpers are
/// `static` (no actor state) so they compose cleanly from the actor's
/// nonisolated `init` bootstrap and from actor-isolated runtime methods —
/// see `SQLiteCoinGeckoCatalog.swift` for the closed-surface comment that
/// pins which symbols leak across extension files.
///
/// Throw sites embed `sqlite3_errmsg(_:)` (resolved via `sqlite3_db_handle`
/// for statement-only call sites) so logs read e.g.
/// `step 2067: UNIQUE constraint failed: coin.coingecko_id` rather than
/// bare `step 19`. Extended result codes are enabled in
/// `SQLiteCoinGeckoCatalog.connect(_:)`.
extension SQLiteCoinGeckoCatalog {
  static func exec(database: OpaquePointer?, _ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &error)
    if result != SQLITE_OK {
      let message = error.map { String(cString: $0) } ?? "(no errmsg)"
      sqlite3_free(error)
      throw CatalogError.sqlite("exec \(result): \(message)")
    }
  }

  static func prepare(
    database: OpaquePointer?,
    sql: String,
    into statement: inout OpaquePointer?
  ) throws {
    let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard result == SQLITE_OK else {
      throw CatalogError.sqlite(
        "prepare \(result): \(errorMessage(database: database)) — \(sql)")
    }
  }

  static func bind(
    _ statement: OpaquePointer?,
    at index: Int32,
    to value: String
  ) throws {
    let result = sqlite3_bind_text(
      statement,
      index,
      value,
      -1,
      unsafeBitCast(Int(-1), to: sqlite3_destructor_type.self)
    )
    guard result == SQLITE_OK else {
      throw CatalogError.sqlite(
        "bind text \(result): \(errorMessage(statement: statement))")
    }
  }

  static func bind(
    _ statement: OpaquePointer?,
    at index: Int32,
    to value: Int
  ) throws {
    let result = sqlite3_bind_int64(statement, index, Int64(value))
    guard result == SQLITE_OK else {
      throw CatalogError.sqlite(
        "bind int \(result): \(errorMessage(statement: statement))")
    }
  }

  static func step(_ statement: OpaquePointer?) throws {
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE || result == SQLITE_ROW else {
      throw CatalogError.sqlite(
        "step \(result): \(errorMessage(statement: statement))")
    }
  }

  /// Issues `ROLLBACK;` and logs (rather than rethrows) any failure. A
  /// failed rollback indicates the connection is already in an undefined
  /// transaction state — every subsequent write will fail anyway, so
  /// surfacing the rollback error would mask the original cause; logging
  /// it is the right balance per CODE_GUIDE §8 (no silent `try?`). Callers
  /// must rethrow the original error after invoking this helper.
  static func rollback(database: OpaquePointer?) {
    do {
      try exec(database: database, "ROLLBACK;")
    } catch {
      Self.log.error(
        """
        ROLLBACK failed: \(String(describing: error), privacy: .public) — \
        connection may be in undefined transaction state
        """
      )
    }
  }

  static func readText(_ statement: OpaquePointer?, column: Int32) -> String? {
    guard let cString = sqlite3_column_text(statement, column) else { return nil }
    return String(cString: cString)
  }

  /// Reads `sqlite3_errmsg(_:)` for the connection backing `statement`.
  /// Empty/missing handle paths fall back to a sentinel so a throw site is
  /// never silent — even a degraded message beats `step 19` alone.
  private static func errorMessage(statement: OpaquePointer?) -> String {
    errorMessage(database: statement.flatMap { sqlite3_db_handle($0) })
  }

  private static func errorMessage(database: OpaquePointer?) -> String {
    guard let database, let cString = sqlite3_errmsg(database) else {
      return "(no errmsg)"
    }
    return String(cString: cString)
  }

  static func scalarInt(database: OpaquePointer?, _ sql: String) throws -> Int {
    var statement: OpaquePointer?
    try prepare(database: database, sql: sql, into: &statement)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw CatalogError.sqlite("scalar empty")
    }
    return Int(sqlite3_column_int64(statement, 0))
  }
}
