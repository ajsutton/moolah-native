// Backends/CoinGecko/SQLiteCoinGeckoCatalog+Search.swift
import Foundation
import SQLite3

/// FTS5 search path for `SQLiteCoinGeckoCatalog`. Hosted in a separate file
/// so the actor's primary body stays focused on schema bootstrap and
/// replace-all writes (see CLAUDE.md and `guides/CODE_GUIDE.md` §7 on
/// extension grouping).
extension SQLiteCoinGeckoCatalog {
  func search(query: String, limit: Int) async -> [CatalogEntry] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, limit > 0 else { return [] }

    do {
      let ranked = try Self.fetchRankedCoins(
        database: database, query: trimmed, limit: limit)
      guard !ranked.isEmpty else { return [] }
      let bindings = try Self.fetchPlatformBindings(
        database: database, coingeckoIds: ranked.map(\.id))
      return ranked.map { row in
        CatalogEntry(
          coingeckoId: row.id,
          symbol: row.symbol,
          name: row.name,
          platforms: Self.orderedPlatforms(for: row.id, bindings: bindings)
        )
      }
    } catch {
      log.error("search failed: \(String(describing: error), privacy: .public)")
      return []
    }
  }
}

extension SQLiteCoinGeckoCatalog {
  private struct RankedCoin: Sendable {
    let id: String
    let symbol: String
    let name: String
  }

  private static func fetchRankedCoins(
    database: OpaquePointer?,
    query: String,
    limit: Int
  ) throws -> [RankedCoin] {
    let ftsQuery = ftsQueryString(for: query)
    var statement: OpaquePointer?
    try prepare(
      database: database,
      """
      SELECT c.coingecko_id, c.symbol, c.name
      FROM coin_fts JOIN coin c ON c.rowid = coin_fts.rowid
      WHERE coin_fts MATCH ?
      ORDER BY rank
      LIMIT ?;
      """,
      &statement
    )
    defer { sqlite3_finalize(statement) }
    try bind(statement, 1, ftsQuery)
    try bind(statement, 2, limit)
    var rows: [RankedCoin] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let id = readText(statement, column: 0) ?? ""
      let symbol = readText(statement, column: 1) ?? ""
      let name = readText(statement, column: 2) ?? ""
      rows.append(RankedCoin(id: id, symbol: symbol, name: name))
    }
    return rows
  }

  private static func fetchPlatformBindings(
    database: OpaquePointer?,
    coingeckoIds: [String]
  ) throws -> [String: [PlatformBinding]] {
    guard !coingeckoIds.isEmpty else { return [:] }
    let placeholders = Array(repeating: "?", count: coingeckoIds.count)
      .joined(separator: ", ")
    var statement: OpaquePointer?
    try prepare(
      database: database,
      """
      SELECT cp.coingecko_id, cp.platform_slug, cp.contract_address, p.chain_id
      FROM coin_platform cp
      LEFT JOIN platform p ON p.slug = cp.platform_slug
      WHERE cp.coingecko_id IN (\(placeholders));
      """,
      &statement
    )
    defer { sqlite3_finalize(statement) }
    for (offset, id) in coingeckoIds.enumerated() {
      try bind(statement, Int32(offset + 1), id)
    }
    var bindingsById: [String: [PlatformBinding]] = [:]
    while sqlite3_step(statement) == SQLITE_ROW {
      let coingeckoId = readText(statement, column: 0) ?? ""
      let slug = readText(statement, column: 1) ?? ""
      let contract = readText(statement, column: 2) ?? ""
      let chainId: Int? =
        sqlite3_column_type(statement, 3) == SQLITE_NULL
        ? nil : Int(sqlite3_column_int64(statement, 3))
      bindingsById[coingeckoId, default: []].append(
        PlatformBinding(slug: slug, chainId: chainId, contractAddress: contract)
      )
    }
    return bindingsById
  }

  private static func orderedPlatforms(
    for coingeckoId: String,
    bindings: [String: [PlatformBinding]]
  ) -> [PlatformBinding] {
    let raw = bindings[coingeckoId] ?? []
    let priority = CoinGeckoCatalogSchema.platformPriority
    return raw.sorted { lhs, rhs in
      let lhsRank = priority.firstIndex(of: lhs.slug) ?? Int.max
      let rhsRank = priority.firstIndex(of: rhs.slug) ?? Int.max
      if lhsRank != rhsRank { return lhsRank < rhsRank }
      return lhs.slug < rhs.slug
    }
  }

  private static func ftsQueryString(for query: String) -> String {
    let tokens =
      query
      .components(separatedBy: .whitespaces)
      .filter { !$0.isEmpty }
      .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
    return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
  }
}
