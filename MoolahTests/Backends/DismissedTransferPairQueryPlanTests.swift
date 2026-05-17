// MoolahTests/Backends/DismissedTransferPairQueryPlanTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning test for `pairs(touching:)`. Per
/// `guides/DATABASE_CODE_GUIDE.md` §6 the hot detection-time lookup
/// `WHERE transaction_id_a = ? OR transaction_id_b = ?` must resolve via
/// the two single-column indexes (`dismissed_pair_by_tx_a` /
/// `dismissed_pair_by_tx_b`), not a full-table scan. SQLite plans an
/// OR-of-two-indexed-columns as a two-search union, so the plan must
/// reference `dismissed_pair_by_tx_` and must not contain
/// `SCAN dismissed_transfer_pair`.
@Suite("DismissedTransferPair query plan")
struct DismissedTransferPairQueryPlanTests {
  @Test
  func pairsTouchingUsesIndexNotScan() async throws {
    let database = try ProfileDatabase.openInMemory()
    let txId = UUID()
    try await database.read { database in
      // `SELECT *` here is wrapped in `EXPLAIN QUERY PLAN`; the planner
      // never expands the column list, so the star is fine.
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT * FROM dismissed_transfer_pair
          WHERE transaction_id_a = ? OR transaction_id_b = ?
          """,
        arguments: [txId, txId]
      ).map { String(describing: $0["detail"] ?? "") }
      #expect(
        plan.contains { $0.contains("USING INDEX dismissed_pair_by_tx_") },
        "pairs(touching:) must resolve via dismissed_pair_by_tx_* indexes")
      #expect(
        !plan.contains { $0.contains("SCAN dismissed_transfer_pair") },
        "pairs(touching:) must not full-table scan dismissed_transfer_pair")
    }
  }
}
