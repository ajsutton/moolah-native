// MoolahTests/Backends/GRDB/ProfileIndexPlanPinningTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning tests for the profile-index DB. Per
/// `guides/DATABASE_CODE_GUIDE.md` §6 every perf-critical query gets a
/// paired plan-pinning test so an index regression breaks the build
/// immediately.
///
/// Pinned queries:
///
/// 1. `profile.created_at` ascending — the canonical fetch order used
///    by `GRDBProfileIndexRepository.fetchAll()` and the profile picker.
///    Must hit `profile_by_created_at` and avoid a temp B-tree sort.
@Suite("Profile-index GRDB query plans")
struct ProfileIndexPlanPinningTests {
  /// `PlanPinningTestHelpers.makeDatabase` opens the per-profile
  /// database, but the profile-index DB has its own factory. Open the
  /// in-memory profile-index queue here and reuse the shared `planDetail`
  /// helper for the EXPLAIN-fetch glue.
  private func makeDatabase() throws -> DatabaseQueue {
    try ProfileIndexDatabase.openInMemory()
  }

  @Test("fetchAll ORDER BY created_at uses profile_by_created_at index")
  func profileOrderByCreatedAtUsesIndex() throws {
    let database = try makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT id FROM profile ORDER BY created_at
        """)
    // `GRDBProfileIndexRepository.fetchAll` orders by created_at ASC —
    // pinning the index here prevents a future schema edit from
    // silently regressing fetchAll() to a temp-B-tree sort over the
    // entire table.
    //
    // SQLite emits `SCAN profile USING INDEX profile_by_created_at`
    // for ORDER BY index scans (the table itself is "scanned" via the
    // index in created_at order). A literal `!detail.contains("SCAN
    // profile")` guard would always fail here — the absence of `USE
    // TEMP B-TREE` is the correct regression signal that the planner
    // is using the index for ordering rather than a transient sort.
    #expect(detail.contains("USING INDEX profile_by_created_at"))
    #expect(!detail.contains("USE TEMP B-TREE"))
  }
}
