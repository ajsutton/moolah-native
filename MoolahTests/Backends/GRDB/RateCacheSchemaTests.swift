// MoolahTests/Backends/GRDB/RateCacheSchemaTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Schema-introspection tests for the three rate-cache `*_meta` tables.
///
/// `guides/DATABASE_SCHEMA_GUIDE.md` §3 requires single-TEXT-PK lookup
/// tables to be `WITHOUT ROWID` for the smaller storage footprint and
/// faster point lookups. These tests pin the invariant so that a
/// future migration can't silently regress to a rowid table (which
/// would also reintroduce the `RETURNING "rowid"` upsert hazard
/// described in #582).
///
/// Pinned to the v9 era: `v10_drop_shared_instrument_legacy` drops the
/// six rate-cache tables (incl. all three `*_meta` tables) from the
/// per-profile schema, so a full migration leaves them absent. The
/// WITHOUT-ROWID contract is only observable while the tables exist,
/// so the migrator is run `upTo:` the last migration that still has
/// them — each shipped migration keeps its own era's contract.
@Suite("Rate cache *_meta table schema")
struct RateCacheSchemaTests {
  @Test
  func exchangeRateMetaIsWithoutRowid() async throws {
    try await assertWithoutRowid(table: "exchange_rate_meta")
  }

  @Test
  func stockTickerMetaIsWithoutRowid() async throws {
    try await assertWithoutRowid(table: "stock_ticker_meta")
  }

  @Test
  func cryptoTokenMetaIsWithoutRowid() async throws {
    try await assertWithoutRowid(table: "crypto_token_meta")
  }

  private func assertWithoutRowid(table: String) async throws {
    let database = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(database, upTo: "v9_add_counterparty_address")
    let createSQL = try await database.read { database in
      try String.fetchOne(
        database,
        sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
        arguments: [table])
    }
    let sql = try #require(createSQL)
    #expect(
      sql.uppercased().contains("WITHOUT ROWID"),
      "Expected \(table) to be WITHOUT ROWID; got: \(sql)")
  }
}
