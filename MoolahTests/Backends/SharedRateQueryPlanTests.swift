// MoolahTests/Backends/SharedRateQueryPlanTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Mirrored plan-pinning tests for the rate-cache tables on the
/// **shared** profile-index DB (added by the
/// `v3_shared_instrument_registry` migration). `loadCache`-shaped
/// queries against the shared tables must use the same primary-key
/// scan as the per-profile equivalents — the per-profile
/// `RateQueryPlanTests` confirms the per-profile shape; this suite
/// confirms the shared shape.
///
/// The per-profile `exchange_rate_lookup` index on `(base, quote, date)`
/// is intentionally **not** carried into the shared DB — `loadCache`
/// fetches `WHERE base = ?` and resolves quote/date in-memory from
/// the loaded `caches[base]` dictionary. This suite asserts the PK is
/// the chosen access path and that no shared `exchange_rate_lookup`
/// index exists.
@Suite("Shared rate cache loadCache query plans")
struct SharedRateQueryPlanTests {

  @Test("WHERE base = ? on shared exchange_rate uses the primary key")
  func exchangeRateLoadCacheUsesPrimaryKey() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    try await database.read { database in
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT * FROM exchange_rate WHERE base = ?
          """,
        arguments: ["AUD"]
      ).map { String(describing: $0["detail"] ?? "") }
      #expect(plan.contains { $0.contains("SEARCH") && $0.contains("PRIMARY KEY") })
      #expect(!plan.contains { $0.contains("SCAN") })
      // The per-profile `exchange_rate_lookup` index is intentionally
      // omitted from the shared DB; assert the planner cannot reach
      // for it because it doesn't exist.
      #expect(!plan.contains { $0.contains("exchange_rate_lookup") })
    }
  }

  @Test("WHERE ticker = ? on shared stock_price uses the primary key")
  func stockPriceLoadCacheUsesPrimaryKey() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    try await database.read { database in
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT * FROM stock_price WHERE ticker = ?
          """,
        arguments: ["BHP.AX"]
      ).map { String(describing: $0["detail"] ?? "") }
      #expect(plan.contains { $0.contains("SEARCH") && $0.contains("PRIMARY KEY") })
      #expect(!plan.contains { $0.contains("SCAN") })
    }
  }

  @Test("WHERE token_id = ? on shared crypto_price uses the primary key")
  func cryptoPriceLoadCacheUsesPrimaryKey() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    try await database.read { database in
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT * FROM crypto_price WHERE token_id = ?
          """,
        arguments: ["1:native"]
      ).map { String(describing: $0["detail"] ?? "") }
      #expect(plan.contains { $0.contains("SEARCH") && $0.contains("PRIMARY KEY") })
      #expect(!plan.contains { $0.contains("SCAN") })
    }
  }

  @Test("WHERE base = ? on shared exchange_rate_meta uses the primary key")
  func exchangeRateMetaLoadUsesPrimaryKey() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    try await database.read { database in
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

  @Test("WHERE ticker = ? on shared stock_ticker_meta uses the primary key")
  func stockTickerMetaLoadUsesPrimaryKey() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    try await database.read { database in
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

  @Test("WHERE token_id = ? on shared crypto_token_meta uses the primary key")
  func cryptoTokenMetaLoadUsesPrimaryKey() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    try await database.read { database in
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT * FROM crypto_token_meta WHERE token_id = ?
          """,
        arguments: ["bitcoin"]
      ).map { String(describing: $0["detail"] ?? "") }
      #expect(plan.contains { $0.contains("SEARCH") && $0.contains("PRIMARY KEY") })
      #expect(!plan.contains { $0.contains("SCAN") })
    }
  }
}
