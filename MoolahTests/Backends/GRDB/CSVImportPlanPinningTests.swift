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
/// 3. `csv_import_profile.created_at` ascending — the canonical fetch
///    order used by `GRDBCSVImportProfileRepository.fetchAll()`. Must
///    hit `csv_import_profile_created` and avoid a temp B-tree sort.
/// 4. `csv_import_profile.account_id` lookup — partial filter for
///    account-scoped profile listing. Must hit
///    `csv_import_profile_account`.
/// 5. `import_rule.account_scope` lookup — partial filter used by the
///    rule evaluator for account-scoped rules. Must hit
///    `import_rule_account_scope`.
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
          SELECT id FROM import_rule ORDER BY position
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
          SELECT id FROM csv_import_profile WHERE id = ?
          """,
        arguments: [UUID()]
      ).map { String(describing: $0["detail"] ?? "") }
      // BLOB PRIMARY KEY columns surface as
      // `SEARCH … USING INDEX sqlite_autoindex_csv_import_profile_1`.
      // Pin the exact auto-index name so a future change that drops the
      // PK declaration (and silently reverts to a SCAN) fails this
      // test rather than passing on a `SEARCH` against any other index.
      #expect(
        plan.contains { $0.contains("sqlite_autoindex_csv_import_profile_1") })
      #expect(!plan.contains { $0.contains("SCAN") })
    }
  }

  @Test
  func importRuleFilterByAccountScopeUsesPartialIndex() async throws {
    let database = try ProfileDatabase.openInMemory()
    try await database.read { database in
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT id FROM import_rule WHERE account_scope = ?
          """,
        arguments: [UUID()]
      ).map { String(describing: $0["detail"] ?? "") }
      // The partial index `import_rule_account_scope` covers the live
      // "rules scoped to account X" lookup driven by the rule
      // evaluator. Pinning the index here keeps the schema and the
      // query in lockstep — a future schema edit that drops the partial
      // index turns this test red instead of silently regressing the
      // hot path to a SCAN.
      #expect(plan.contains { $0.contains("USING INDEX import_rule_account_scope") })
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
          SELECT id FROM csv_import_profile WHERE account_id = ?
          """,
        arguments: [UUID()]
      ).map { String(describing: $0["detail"] ?? "") }
      #expect(plan.contains { $0.contains("USING INDEX csv_import_profile_account") })
      #expect(!plan.contains { $0.contains("SCAN") })
    }
  }

  @Test
  func csvImportProfileOrderByCreatedAtUsesIndex() async throws {
    let database = try ProfileDatabase.openInMemory()
    try await database.read { database in
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT id FROM csv_import_profile ORDER BY created_at
          """
      ).map { String(describing: $0["detail"] ?? "") }
      // `GRDBCSVImportProfileRepository.fetchAll` orders by created_at
      // ASC — pinning the index here prevents a future schema edit from
      // silently regressing fetchAll() to a temp-B-tree sort over the
      // entire table.
      #expect(plan.contains { $0.contains("USING INDEX csv_import_profile_created") })
      #expect(!plan.contains { $0.contains("USE TEMP B-TREE") })
    }
  }
}
