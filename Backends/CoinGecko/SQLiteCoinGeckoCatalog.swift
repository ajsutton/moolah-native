// Backends/CoinGecko/SQLiteCoinGeckoCatalog.swift
import Foundation
import SQLite3
import os

/// Catalogue actor backing `CoinGeckoCatalog` with a local SQLite database
/// at `<directory>/catalog.sqlite`. Public methods are `async`; all SQLite
/// work runs on the actor's serial executor so the connection is never
/// shared across threads. See design §4.1 / §6.
actor SQLiteCoinGeckoCatalog: CoinGeckoCatalog {
  private let directory: URL
  private let session: URLSession
  let log = Logger(subsystem: "moolah.instrument-registry", category: "catalog")
  private(set) var database: OpaquePointer?

  // Note: `log` and `database` are module-internal (no explicit modifier
  // per CODE_GUIDE §7) so the `+Search.swift` extension can read them.
  // Helpers like `prepare`, `bind`, and `readText` below are also
  // module-internal for the same reason.

  init(
    directory: URL,
    session: URLSession = .shared
  ) throws {
    self.directory = directory
    self.session = session
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true
    )
    self.database = try Self.open(dbURL: directory.appendingPathComponent("catalog.sqlite"))
  }

  isolated deinit {
    if let database { sqlite3_close_v2(database) }
  }

  // MARK: - CoinGeckoCatalog
  //
  // `search(query:limit:)` lives in `SQLiteCoinGeckoCatalog+Search.swift`.

  func refreshIfStale() async {
    // Implemented in Task 5.
  }

  // MARK: - Schema bootstrap
  //
  // Bootstrap helpers are `static` so they can run from the actor's
  // nonisolated `init`, before `self.database` is assigned. Once
  // initialisation is complete the live handle is stored on the actor and
  // every subsequent call routes through the actor-isolated wrappers
  // below, which re-use the same nonisolated SQLite helpers by passing
  // `self.database` as a parameter.

  private static func open(dbURL: URL) throws -> OpaquePointer {
    if FileManager.default.fileExists(atPath: dbURL.path) {
      let handle = try connect(dbURL: dbURL)
      var shouldClose = true
      defer { if shouldClose { sqlite3_close_v2(handle) } }

      let storedVersion = try readMeta(database: handle).schemaVersion
      if storedVersion != CoinGeckoCatalogSchema.version {
        // `shouldClose` is true; the defer closes the stale handle before
        // we recreate the file.
        try FileManager.default.removeItem(at: dbURL)
        // SQLite's WAL mode produces `<db>-wal` and `<db>-shm` sidecar
        // files; drop them too so the recreated database starts clean.
        try? FileManager.default.removeItem(
          at: URL(fileURLWithPath: dbURL.path + "-wal"))
        try? FileManager.default.removeItem(
          at: URL(fileURLWithPath: dbURL.path + "-shm"))
        return try createFresh(dbURL: dbURL)
      }
      shouldClose = false  // caller takes ownership
      return handle
    } else {
      return try createFresh(dbURL: dbURL)
    }
  }

  private static func connect(dbURL: URL) throws -> OpaquePointer {
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    let result = sqlite3_open_v2(dbURL.path, &handle, flags, nil)
    guard result == SQLITE_OK, let handle else {
      throw CatalogError.sqlite("open failed: \(result)")
    }
    return handle
  }

  private static func createFresh(dbURL: URL) throws -> OpaquePointer {
    let handle = try connect(dbURL: dbURL)
    for stmt in CoinGeckoCatalogSchema.statements {
      try exec(database: handle, stmt)
    }
    return handle
  }

  // MARK: - Replace-all

  private func replaceAll(coins: [RawCoin], platforms: [RawPlatform]) throws {
    try Self.exec(database: database, "BEGIN IMMEDIATE;")
    do {
      try Self.exec(database: database, "DELETE FROM coin;")
      try Self.exec(database: database, "DELETE FROM platform;")
      try Self.insertCoins(database: database, coins: coins)
      try Self.insertPlatforms(database: database, platforms: platforms)
      try Self.exec(database: database, "COMMIT;")
    } catch {
      try? Self.exec(database: database, "ROLLBACK;")
      throw error
    }
  }

  private static func insertCoins(database: OpaquePointer?, coins: [RawCoin]) throws {
    guard !coins.isEmpty else { return }
    var insertCoin: OpaquePointer?
    try prepare(
      database: database,
      "INSERT INTO coin (coingecko_id, symbol, name) VALUES (?, ?, ?);",
      &insertCoin)
    defer { sqlite3_finalize(insertCoin) }
    var insertCoinPlatform: OpaquePointer?
    try prepare(
      database: database,
      "INSERT INTO coin_platform (coingecko_id, platform_slug, contract_address) "
        + "VALUES (?, ?, ?);",
      &insertCoinPlatform)
    defer { sqlite3_finalize(insertCoinPlatform) }

    for coin in coins {
      try bind(insertCoin, 1, coin.id)
      try bind(insertCoin, 2, coin.symbol)
      try bind(insertCoin, 3, coin.name)
      try step(insertCoin)
      sqlite3_reset(insertCoin)

      for (slug, contract) in coin.platforms where !contract.isEmpty {
        try bind(insertCoinPlatform, 1, coin.id)
        try bind(insertCoinPlatform, 2, slug)
        try bind(insertCoinPlatform, 3, contract.lowercased())
        try step(insertCoinPlatform)
        sqlite3_reset(insertCoinPlatform)
      }
    }
  }

  private static func insertPlatforms(
    database: OpaquePointer?,
    platforms: [RawPlatform]
  ) throws {
    guard !platforms.isEmpty else { return }
    var insertPlatform: OpaquePointer?
    try prepare(
      database: database,
      "INSERT INTO platform (slug, chain_id, name) VALUES (?, ?, ?);",
      &insertPlatform)
    defer { sqlite3_finalize(insertPlatform) }
    for platform in platforms {
      try bind(insertPlatform, 1, platform.slug)
      if let chainId = platform.chainId {
        try bind(insertPlatform, 2, chainId)
      } else {
        sqlite3_bind_null(insertPlatform, 2)
      }
      try bind(insertPlatform, 3, platform.name)
      try step(insertPlatform)
      sqlite3_reset(insertPlatform)
    }
  }

  // MARK: - Meta read / write

  private static func readMeta(database: OpaquePointer?) throws -> MetaSnapshot {
    var statement: OpaquePointer?
    try prepare(
      database: database,
      "SELECT schema_version, last_fetched, coins_etag, platforms_etag FROM meta LIMIT 1;",
      &statement)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw CatalogError.sqlite("meta table empty")
    }
    let version = Int(sqlite3_column_int64(statement, 0))
    let lastFetched: Date? = {
      let raw = sqlite3_column_double(statement, 1)
      if sqlite3_column_type(statement, 1) == SQLITE_NULL { return nil }
      return Date(timeIntervalSince1970: raw)
    }()
    let coinsEtag = readText(statement, column: 2)
    let platformsEtag = readText(statement, column: 3)
    return MetaSnapshot(
      schemaVersion: version,
      lastFetched: lastFetched,
      coinsEtag: coinsEtag,
      platformsEtag: platformsEtag
    )
  }

  // MARK: - Low-level SQLite helpers

  private static func exec(database: OpaquePointer?, _ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &error)
    if result != SQLITE_OK {
      let message = error.map { String(cString: $0) } ?? "code \(result)"
      sqlite3_free(error)
      throw CatalogError.sqlite("exec failed: \(message)")
    }
  }

  static func prepare(
    database: OpaquePointer?,
    _ sql: String,
    _ statement: inout OpaquePointer?
  ) throws {
    let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard result == SQLITE_OK else {
      throw CatalogError.sqlite("prepare failed: \(result) for \(sql)")
    }
  }

  static func bind(
    _ statement: OpaquePointer?,
    _ index: Int32,
    _ value: String
  ) throws {
    let result = sqlite3_bind_text(
      statement,
      index,
      value,
      -1,
      unsafeBitCast(Int(-1), to: sqlite3_destructor_type.self)
    )
    guard result == SQLITE_OK else { throw CatalogError.sqlite("bind text \(result)") }
  }

  static func bind(
    _ statement: OpaquePointer?,
    _ index: Int32,
    _ value: Int
  ) throws {
    let result = sqlite3_bind_int64(statement, index, Int64(value))
    guard result == SQLITE_OK else { throw CatalogError.sqlite("bind int \(result)") }
  }

  private static func step(_ statement: OpaquePointer?) throws {
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE || result == SQLITE_ROW else {
      throw CatalogError.sqlite("step \(result)")
    }
  }

  private static func scalarInt(database: OpaquePointer?, _ sql: String) throws -> Int {
    var statement: OpaquePointer?
    try prepare(database: database, sql, &statement)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw CatalogError.sqlite("scalar empty")
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  static func readText(_ statement: OpaquePointer?, column: Int32) -> String? {
    guard let cString = sqlite3_column_text(statement, column) else { return nil }
    return String(cString: cString)
  }

  enum CatalogError: Error, Equatable {
    case sqlite(String)
  }
}

// MARK: - Test seams
//
// The `RawCoin` / `RawPlatform` / `MetaSnapshot` value types and the
// `*ForTesting` accessors are module-internal so storage tests can
// exercise replace-all and meta read/write without depending on the
// network refresh path (which lands in Task 5). Production callers go
// through `search(query:limit:)` and `refreshIfStale()`. Hosting them in
// an extension keeps the actor body focused on production code paths.

extension SQLiteCoinGeckoCatalog {
  struct RawCoin: Sendable {
    let id: String
    let symbol: String
    let name: String
    /// platform slug → contract address (verbatim, normalised on insert)
    let platforms: [String: String]
  }

  struct RawPlatform: Sendable {
    let slug: String
    let chainId: Int?
    let name: String
  }

  struct MetaSnapshot: Sendable, Equatable {
    let schemaVersion: Int
    let lastFetched: Date?
    let coinsEtag: String?
    let platformsEtag: String?
  }

  func replaceAllForTesting(coins: [RawCoin], platforms: [RawPlatform]) throws {
    try replaceAll(coins: coins, platforms: platforms)
  }

  func readMetaForTesting() throws -> MetaSnapshot {
    try Self.readMeta(database: database)
  }

  func coinCountForTesting() throws -> Int {
    try Self.scalarInt(database: database, "SELECT COUNT(*) FROM coin")
  }

  func platformCountForTesting() throws -> Int {
    try Self.scalarInt(database: database, "SELECT COUNT(*) FROM platform")
  }

  func coinPlatformCountForTesting() throws -> Int {
    try Self.scalarInt(database: database, "SELECT COUNT(*) FROM coin_platform")
  }

  func writeMetaSchemaVersionForTesting(_ version: Int) throws {
    var statement: OpaquePointer?
    try Self.prepare(
      database: database, "UPDATE meta SET schema_version = ?;", &statement)
    defer { sqlite3_finalize(statement) }
    try Self.bind(statement, 1, version)
    try Self.step(statement)
  }
}
