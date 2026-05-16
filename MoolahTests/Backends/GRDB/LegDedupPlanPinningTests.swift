// MoolahTests/Backends/GRDB/LegDedupPlanPinningTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning test for the per-account external-id
/// lookup used by `GRDBTransactionRepository.legExists(accountId:externalId:)`.
/// Per `guides/DATABASE_CODE_GUIDE.md` §6, every perf-critical query must
/// have a paired plan-pinning test so an index regression breaks the build.
///
/// Pinned: the `(account_id, external_id)` predicate hits the partial
/// unique index `leg_dedup_by_account_external` defined in v8.
@Suite("Leg dedup per-account external-id lookup plan pinning")
struct LegDedupPlanPinningTests {
  @Test
  func legDedupByAccountExternalUsesIndex() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT id FROM transaction_leg
        WHERE account_id = ? AND external_id = ?
        """,
      arguments: [Data(repeating: 1, count: 16), "0xabc"])
    #expect(detail.contains("leg_dedup_by_account_external"))
    #expect(
      !PlanPinningTestHelpers.planHasFullTableScanOf(
        detail, alias: "transaction_leg"))
  }
}
