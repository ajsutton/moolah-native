// MoolahTests/Backends/RateQueryPlanTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning tests for the three rate-cache hydration
/// queries. Per `guides/DATABASE_CODE_GUIDE.md` §6 every perf-critical
/// query must have a paired plan-pinning test so an index regression
/// (e.g. a rename, an accidentally-dropped index, or a column-order
/// change in the PK) breaks the build immediately rather than slipping
/// through to production as a full-table scan.
///
/// All three `loadCache` queries filter on the leading column of the
/// table's primary key (`base`, `ticker`, `token_id`) so the planner is
/// expected to choose `SEARCH USING PRIMARY KEY`. Anything else
/// (including `SCAN <table>`) is a regression.
///
/// The rate caches now live on the shared profile-index DB
/// (`ProfileIndexSchema`); the per-profile copies were dropped by
/// `v10_drop_shared_instrument_legacy`. The plan is pinned against the
/// shared schema because that is what production reads.
@Suite("Rate cache loadCache query plans")
struct RateQueryPlanTests {
  @Test
  func exchangeRateLoadCacheUsesPrimaryKey() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    try await database.read { database in
      // `SELECT *` here is wrapped in `EXPLAIN QUERY PLAN`; the planner
      // never expands the column list, so the star is fine.
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT * FROM exchange_rate WHERE base = ? ORDER BY "date"
          """,
        arguments: ["AUD"]
      ).map { String(describing: $0["detail"] ?? "") }
      #expect(plan.contains { $0.contains("SEARCH") && $0.contains("PRIMARY KEY") })
      #expect(!plan.contains { $0.contains("SCAN") })
      // `WHERE base = ? ORDER BY date` is a PK-prefix scan (PK is
      // `(base, date, quote)`), so the planner satisfies the order
      // directly from the index — no sort buffer.
      #expect(!plan.contains { $0.contains("USE TEMP B-TREE") })
    }
  }

  @Test
  func stockPriceLoadCacheUsesPrimaryKey() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    try await database.read { database in
      // `SELECT *` here is wrapped in `EXPLAIN QUERY PLAN`; the planner
      // never expands the column list, so the star is fine.
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT * FROM stock_price WHERE ticker = ? ORDER BY "date"
          """,
        arguments: ["BHP.AX"]
      ).map { String(describing: $0["detail"] ?? "") }
      #expect(plan.contains { $0.contains("SEARCH") && $0.contains("PRIMARY KEY") })
      #expect(!plan.contains { $0.contains("SCAN") })
      // `WHERE ticker = ? ORDER BY date` is a PK-prefix scan (PK is
      // `(ticker, date)`), so the planner satisfies the order directly
      // from the index — no sort buffer.
      #expect(!plan.contains { $0.contains("USE TEMP B-TREE") })
    }
  }

  @Test
  func cryptoPriceLoadCacheUsesPrimaryKey() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    try await database.read { database in
      // `SELECT *` here is wrapped in `EXPLAIN QUERY PLAN`; the planner
      // never expands the column list, so the star is fine.
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT * FROM crypto_price WHERE token_id = ? ORDER BY "date"
          """,
        arguments: ["1:native"]
      ).map { String(describing: $0["detail"] ?? "") }
      #expect(plan.contains { $0.contains("SEARCH") && $0.contains("PRIMARY KEY") })
      #expect(!plan.contains { $0.contains("SCAN") })
      // `WHERE token_id = ? ORDER BY date` is a PK-prefix scan (PK is
      // `(token_id, date)`), so the planner satisfies the order directly
      // from the index — no sort buffer.
      #expect(!plan.contains { $0.contains("USE TEMP B-TREE") })
    }
  }

  @Test
  func exchangeRateMetaLoadUsesPrimaryKey() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    try await database.read { database in
      // `SELECT *` here is wrapped in `EXPLAIN QUERY PLAN`; the planner
      // never expands the column list, so the star is fine.
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT * FROM exchange_rate_meta WHERE base = ?
          """,
        arguments: ["AUD"]
      ).map { String(describing: $0["detail"] ?? "") }
      #expect(plan.contains { $0.contains("SEARCH") && $0.contains("PRIMARY KEY") })
      #expect(!plan.contains { $0.contains("SCAN") })
    }
  }

  @Test
  func stockTickerMetaLoadUsesPrimaryKey() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    try await database.read { database in
      // `SELECT *` here is wrapped in `EXPLAIN QUERY PLAN`; the planner
      // never expands the column list, so the star is fine.
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT * FROM stock_ticker_meta WHERE ticker = ?
          """,
        arguments: ["BHP.AX"]
      ).map { String(describing: $0["detail"] ?? "") }
      #expect(plan.contains { $0.contains("SEARCH") && $0.contains("PRIMARY KEY") })
      #expect(!plan.contains { $0.contains("SCAN") })
    }
  }

  @Test
  func cryptoTokenMetaLoadUsesPrimaryKey() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    try await database.read { database in
      // `SELECT *` here is wrapped in `EXPLAIN QUERY PLAN`; the planner
      // never expands the column list, so the star is fine.
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT * FROM crypto_token_meta WHERE token_id = ?
          """,
        arguments: ["1:native"]
      ).map { String(describing: $0["detail"] ?? "") }
      #expect(plan.contains { $0.contains("SEARCH") && $0.contains("PRIMARY KEY") })
      #expect(!plan.contains { $0.contains("SCAN") })
    }
  }
}
