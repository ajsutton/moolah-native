// MoolahTests/Backends/GRDB/CSVImportPlanPinningTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning tests for the hot lookup queries on the
/// two tables introduced by `v2_csv_import_and_rules`. Per
/// `guides/DATABASE_CODE_GUIDE.md` §6 every perf-critical query must
/// have a paired plan-pinning test so an index regression breaks the
/// build immediately.
///
/// Pinned queries:
///
/// 1. `import_rule.position` ascending — the canonical fetch order used
///    by `GRDBImportRuleRepository.fetchAll()` and the rule-evaluation
///    pipeline. Must hit the partial index `import_rule_position`.
/// 2. `csv_import_profile.id` lookup — primary-key search used by
///    `GRDBCSVImportProfileRepository.update`/`delete` (and the
///    sync-side single-record fetcher). Must use the table's primary
///    key.
@Suite("CSV-import GRDB query plans")
struct CSVImportPlanPinningTests {
  @Test
  func importRuleOrderByPositionUsesIndex() async throws {
    let database = try ProfileDatabase.openInMemory()
    try await database.read { database in
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT * FROM import_rule ORDER BY position
          """
      ).map { String(describing: $0["detail"] ?? "") }
      #expect(plan.contains { $0.contains("USING INDEX import_rule_position") })
      #expect(!plan.contains { $0.contains("USE TEMP B-TREE") })
    }
  }

  @Test
  func csvImportProfileLookupByIdUsesPrimaryKey() async throws {
    let database = try ProfileDatabase.openInMemory()
    try await database.read { database in
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT * FROM csv_import_profile WHERE id = ?
          """,
        arguments: [UUID()]
      ).map { String(describing: $0["detail"] ?? "") }
      // Non-INTEGER PRIMARY KEY columns surface as
      // `SEARCH … USING INDEX sqlite_autoindex_csv_import_profile_1`
      // or similar in EQP output. The guarantee that matters is "no
      // table scan"; we additionally check the plan mentions either an
      // INDEX or a primary-key-shaped lookup so a future change that
      // accidentally drops the PK declaration shows up here.
      #expect(plan.contains { $0.contains("SEARCH") })
      #expect(!plan.contains { $0.contains("SCAN") })
    }
  }

  @Test
  func csvImportProfileFilterByAccountUsesIndex() async throws {
    let database = try ProfileDatabase.openInMemory()
    try await database.read { database in
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT * FROM csv_import_profile WHERE account_id = ?
          """,
        arguments: [UUID()]
      ).map { String(describing: $0["detail"] ?? "") }
      #expect(plan.contains { $0.contains("USING INDEX csv_import_profile_account") })
      #expect(!plan.contains { $0.contains("SCAN") })
    }
  }
}
