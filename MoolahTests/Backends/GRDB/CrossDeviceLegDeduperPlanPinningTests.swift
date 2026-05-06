// MoolahTests/Backends/GRDB/CrossDeviceLegDeduperPlanPinningTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning tests for the GRDB query that backs
/// `CrossDeviceLegDeduper`'s touched-set sweep. Per
/// `guides/DATABASE_CODE_GUIDE.md` §6 every perf-critical query must
/// have a paired plan-pinning test so an index regression breaks the
/// build immediately.
///
/// Pinned: the leg-side `IN`-predicate on `external_id` used by
/// `GRDBTransactionRepository.transactions(touchingExternalIds:)`. Must
/// hit the partial unique index `leg_dedup_by_account_external` (the
/// same index `WalletApplyEngine` reads through).
@Suite("CrossDeviceLegDeduper GRDB query plan")
struct CrossDeviceLegDeduperPlanPinningTests {
  @Test
  func touchedExternalIdLookupUsesPartialIndex() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    // Single-arg form is the cheap canary: `IN (?)` resolves to the
    // same index walk as the multi-arg form, and SQLite reports the
    // index in the plan either way.
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT transaction_id FROM transaction_leg
        WHERE external_id IN (?)
        """,
      arguments: ["0xseed"])
    #expect(detail.contains("USING INDEX leg_dedup_by_account_external"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "transaction_leg"))
  }
}
