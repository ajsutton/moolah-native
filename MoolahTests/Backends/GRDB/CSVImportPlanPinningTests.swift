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
  /// `makeDatabase` and `planDetail` are shared with
  /// `AnalysisPlanPinningTests` and `AnalysisAggregationPlanPinningTests`
  /// via `PlanPinningTestHelpers`.
  private func makeDatabase() throws -> DatabaseQueue {
    try PlanPinningTestHelpers.makeDatabase()
  }

  private func planDetail(
    _ database: DatabaseQueue, query: String, arguments: StatementArguments = []
  ) throws -> String {
    try PlanPinningTestHelpers.planDetail(database, query: query, arguments: arguments)
  }

  @Test
  func importRuleOrderByPositionUsesIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM import_rule ORDER BY position
        """)
    #expect(detail.contains("USING INDEX import_rule_position"))
    #expect(!detail.contains("USE TEMP B-TREE"))
  }

  @Test
  func csvImportProfileLookupByIdUsesPrimaryKey() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM csv_import_profile WHERE id = ?
        """,
      arguments: [UUID()])
    // BLOB PRIMARY KEY columns surface as
    // `SEARCH … USING INDEX sqlite_autoindex_csv_import_profile_1`.
    // Pin the exact auto-index name so a future change that drops the
    // PK declaration (and silently reverts to a SCAN) fails this
    // test rather than passing on a `SEARCH` against any other index.
    #expect(detail.contains("sqlite_autoindex_csv_import_profile_1"))
    #expect(!detail.contains("SCAN"))
  }

  @Test
  func importRuleFilterByAccountScopeUsesPartialIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM import_rule WHERE account_scope = ?
        """,
      arguments: [UUID()])
    // The partial index `import_rule_account_scope` covers the live
    // "rules scoped to account X" lookup driven by the rule
    // evaluator. Pinning the index here keeps the schema and the
    // query in lockstep — a future schema edit that drops the partial
    // index turns this test red instead of silently regressing the
    // hot path to a SCAN.
    #expect(detail.contains("USING INDEX import_rule_account_scope"))
    #expect(!detail.contains("SCAN"))
  }

  @Test
  func csvImportProfileFilterByAccountUsesIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM csv_import_profile WHERE account_id = ?
        """,
      arguments: [UUID()])
    #expect(detail.contains("USING INDEX csv_import_profile_account"))
    #expect(!detail.contains("SCAN"))
  }

  @Test
  func csvImportProfileOrderByCreatedAtUsesIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM csv_import_profile ORDER BY created_at
        """)
    // `GRDBCSVImportProfileRepository.fetchAll` orders by created_at
    // ASC — pinning the index here prevents a future schema edit from
    // silently regressing fetchAll() to a temp-B-tree sort over the
    // entire table.
    #expect(detail.contains("USING INDEX csv_import_profile_created"))
    #expect(!detail.contains("USE TEMP B-TREE"))
  }
}
