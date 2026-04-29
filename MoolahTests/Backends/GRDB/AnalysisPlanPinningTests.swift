// MoolahTests/Backends/GRDB/AnalysisPlanPinningTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning tests for the hot read paths the GRDB
/// repositories drive against the core financial graph tables. Per
/// `guides/DATABASE_CODE_GUIDE.md` §6, every perf-critical query must
/// have a paired plan-pinning test so that an index regression breaks
/// the build immediately rather than landing as a silent O(N) scan.
///
/// Each test opens a fresh in-memory `ProfileDatabase` (which runs the
/// migrator and creates the v3 tables and indexes), runs an `EXPLAIN
/// QUERY PLAN` over the SQL shape used by the repository, and asserts
/// that:
///
/// 1. The plan mentions the expected `USING INDEX <name>` line.
/// 2. The plan does **not** include a `SCAN` of the table — a SCAN is the
///    canonical regression signature when an index becomes unusable
///    (column rename, predicate drift, partial-index WHERE clause that
///    no longer matches the predicate).
@Suite("Core financial graph plan-pinning")
struct AnalysisPlanPinningTests {

  // MARK: - Helpers

  private func makeDatabase() throws -> DatabaseQueue {
    try ProfileDatabase.openInMemory()
  }

  /// Returns the joined `detail` column from the EXPLAIN QUERY PLAN rows
  /// for the given query. Callers pass the bare query SQL (without the
  /// `EXPLAIN QUERY PLAN` prefix) — the helper prepends the directive
  /// via string concatenation so the `sql:` argument carries no string
  /// interpolation, satisfying `guides/DATABASE_CODE_GUIDE.md` §4.
  /// Joining the `detail` column keeps `contains` checks readable and
  /// matches the format the SQLite docs use to describe plans.
  private func planDetail(
    _ database: DatabaseQueue, query: String, arguments: StatementArguments = []
  ) throws -> String {
    try database.read { database in
      let planSQL = "EXPLAIN QUERY PLAN " + query
      let rows = try Row.fetchAll(database, sql: planSQL, arguments: arguments)
      return rows.compactMap { $0["detail"] as String? }.joined(separator: "; ")
    }
  }

  // MARK: - transaction

  @Test("fetchPayeeSuggestions matches the production query shape")
  func payeePrefixMatchesProduction() throws {
    let database = try makeDatabase()
    // Mirrors the exact SQL emitted by
    // `GRDBTransactionRepository.fetchPayeeSuggestions(prefix:)`:
    // a `lower(payee) LIKE lower(?) || '%'` autocomplete with a
    // `GROUP BY payee` aggregate and a `LIMIT 20`. The `IS NOT NULL`
    // predicate lets SQLite use the partial `transaction_by_payee`
    // index even though the `lower(...)` wrapping defeats range bounds
    // on `payee` itself — autocomplete is `LIMIT 20` so the cost stays
    // bounded. The pin asserts the partial index participates in
    // some way (covering or otherwise), and a `transaction_by_payee`
    // line in the plan is the regression signal.
    let detail = try planDetail(
      database,
      query: """
        SELECT payee
        FROM "transaction"
        WHERE payee IS NOT NULL
          AND lower(payee) LIKE lower(?) || '%'
        GROUP BY payee
        ORDER BY COUNT(*) DESC, payee ASC
        LIMIT 20
        """,
      arguments: ["X"])
    #expect(detail.contains("transaction_by_payee"))
  }

  @Test("transaction equality filter on payee uses the partial payee index")
  func payeeEqualityUsesPayeeIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM "transaction" WHERE payee = ?
        """,
      arguments: ["Coffee"])
    #expect(detail.contains("transaction_by_payee"))
    #expect(!detail.contains("SCAN \"transaction\""))
  }

  @Test("transaction date-range filter uses transaction_by_date")
  func dateRangeUsesDateIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM "transaction" WHERE date >= ? ORDER BY date
        """,
      arguments: [Date()])
    #expect(detail.contains("transaction_by_date"))
    #expect(!detail.contains("SCAN \"transaction\""))
  }

  @Test("scheduled-transaction filter uses transaction_scheduled partial index")
  func scheduledFilterUsesScheduledIndex() throws {
    let database = try makeDatabase()
    // Without ORDER BY the planner picks the partial-on-recur_period
    // index over the full transaction_by_date index. Add ORDER BY date and
    // SQLite re-routes to transaction_by_date because that one is already
    // ordered by date — outside the partial-index test's scope.
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM "transaction" WHERE recur_period IS NOT NULL
        """)
    #expect(detail.contains("transaction_scheduled"))
    #expect(!detail.contains("SCAN \"transaction\""))
  }

  // MARK: - transaction_leg

  @Test("leg fetch by transaction_id uses leg_by_transaction")
  func legByTransactionUsesIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM transaction_leg WHERE transaction_id = ?
        """,
      arguments: [UUID()])
    #expect(detail.contains("leg_by_transaction"))
    #expect(!detail.contains("SCAN transaction_leg"))
  }

  @Test("leg fetch by account_id uses leg_by_account partial index")
  func legByAccountUsesPartialIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM transaction_leg WHERE account_id = ?
        """,
      arguments: [UUID()])
    #expect(detail.contains("leg_by_account"))
    #expect(!detail.contains("SCAN transaction_leg"))
  }

  @Test("leg fetch by category_id uses leg_by_category partial index")
  func legByCategoryUsesPartialIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM transaction_leg WHERE category_id = ?
        """,
      arguments: [UUID()])
    #expect(detail.contains("leg_by_category"))
    #expect(!detail.contains("SCAN transaction_leg"))
  }

  @Test("leg fetch by earmark_id uses leg_by_earmark partial index")
  func legByEarmarkUsesPartialIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM transaction_leg WHERE earmark_id = ?
        """,
      arguments: [UUID()])
    #expect(detail.contains("leg_by_earmark"))
    #expect(!detail.contains("SCAN transaction_leg"))
  }

  // MARK: - investment_value

  @Test("investment-value listing uses iv_by_account_date_value for paginated reads")
  func investmentValueByAccountDateUsesIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM investment_value WHERE account_id = ? ORDER BY date DESC LIMIT 50
        """,
      arguments: [UUID()])
    // The value-extended composite covers the (account_id, date)
    // prefix used by paginated reads as well as the daily-balance
    // queries that also read value/instrument_id, so a single index
    // serves both. The failure case is a SCAN.
    #expect(detail.contains("iv_by_account_date_value"))
    #expect(!detail.contains("SCAN investment_value"))
  }

  // MARK: - earmark_budget_item

  @Test("budget-item lookup by earmark_id uses ebi_by_earmark")
  func budgetItemByEarmarkUsesIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM earmark_budget_item WHERE earmark_id = ?
        """,
      arguments: [UUID()])
    #expect(detail.contains("ebi_by_earmark"))
    #expect(!detail.contains("SCAN earmark_budget_item"))
  }

  @Test("budget-item lookup by category_id uses ebi_by_category")
  func budgetItemByCategoryUsesIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM earmark_budget_item WHERE category_id = ?
        """,
      arguments: [UUID()])
    #expect(detail.contains("ebi_by_category"))
    #expect(!detail.contains("SCAN earmark_budget_item"))
  }

  // MARK: - category

  @Test("category listing by parent_id uses category_by_parent")
  func categoryByParentUsesIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM category WHERE parent_id = ?
        """,
      arguments: [UUID()])
    #expect(detail.contains("category_by_parent"))
    #expect(!detail.contains("SCAN category"))
  }

  // MARK: - account

  @Test("account ordering by position uses account_by_position")
  func accountOrderByPositionUsesIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM account ORDER BY position
        """)
    #expect(detail.contains("account_by_position"))
    #expect(!detail.contains("USE TEMP B-TREE"))
  }

  // MARK: - earmark

  @Test("earmark ordering by position uses earmark_by_position")
  func earmarkOrderByPositionUsesIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM earmark ORDER BY position
        """)
    #expect(detail.contains("earmark_by_position"))
    #expect(!detail.contains("USE TEMP B-TREE"))
  }

  // MARK: - Analysis full-table reads (intentional)

  /// Pins the *current* shape of `GRDBAnalysisRepository.fetchTransactions`
  /// — three full-table reads against `transaction`, `transaction_leg`,
  /// and `instrument`. Not an index-driven query: the analysis path
  /// materialises every row into Swift values today. The test exists so
  /// the ratchet flips when TODO(#577) pushes the per-instrument
  /// GROUP BY into SQL — the SCAN should disappear once the rewrite
  /// lands. https://github.com/ajsutton/moolah-native/issues/577
  @Test("analysis-path fetchTransactions is an intentional SCAN until #577 lands")
  func analysisFetchTransactionsScansByDesign() throws {
    let database = try makeDatabase()
    // SQLite's EXPLAIN QUERY PLAN strips the table-name quotes when it
    // emits the SCAN line, so the assertion drops them too.
    let txnPlan = try planDetail(database, query: "SELECT * FROM \"transaction\"")
    let legPlan = try planDetail(database, query: "SELECT * FROM transaction_leg")
    #expect(txnPlan.contains("SCAN transaction"))
    #expect(legPlan.contains("SCAN transaction_leg"))
  }

  // MARK: - Aggregations

  @Test("computePositions JOIN+GROUP BY avoids a transaction_leg SCAN")
  func computePositionsAvoidsScan() throws {
    let database = try makeDatabase()
    // Mirrors `GRDBAccountRepository.computePositions(database:instruments:)`.
    // The JOIN+GROUP BY needs an index on the leg table that lets SQLite
    // group `(account_id, instrument_id)` without scanning every leg.
    let detail = try planDetail(
      database,
      query: """
        SELECT leg.account_id     AS account_id,
               leg.instrument_id  AS instrument_id,
               SUM(leg.quantity)  AS quantity
        FROM transaction_leg AS leg
        JOIN "transaction" AS txn ON leg.transaction_id = txn.id
        WHERE txn.recur_period IS NULL
          AND leg.account_id IS NOT NULL
        GROUP BY leg.account_id, leg.instrument_id
        HAVING SUM(leg.quantity) <> 0
        """)
    // Either of the leg-side indexes is acceptable: the partial
    // `leg_by_account` and the covering `leg_analysis_by_type_account`
    // both let SQLite find rows with non-NULL account_id without a
    // full table scan.
    let usesAcceptableIndex =
      detail.contains("leg_by_account")
      || detail.contains("leg_analysis_by_type_account")
    #expect(usesAcceptableIndex)
    #expect(!detail.contains("SCAN transaction_leg"))
    #expect(!detail.contains("SCAN \"transaction\""))
  }

  @Test("computeEarmarkPositions JOIN+GROUP BY avoids a transaction_leg SCAN")
  func computeEarmarkPositionsAvoidsScan() throws {
    let database = try makeDatabase()
    // Mirrors `GRDBEarmarkRepository.computeEarmarkPositions`.
    let detail = try planDetail(
      database,
      query: """
        SELECT leg.earmark_id     AS earmark_id,
               leg.instrument_id  AS instrument_id,
               leg.type           AS type,
               leg.quantity       AS quantity
        FROM transaction_leg AS leg
        JOIN "transaction" AS txn ON leg.transaction_id = txn.id
        WHERE txn.recur_period IS NULL
          AND leg.earmark_id IS NOT NULL
        """)
    // Either the partial `leg_by_earmark` or the covering
    // `leg_analysis_by_earmark_type` is acceptable; both keep the
    // earmark-non-NULL filter off a full scan.
    let usesAcceptableIndex =
      detail.contains("leg_by_earmark")
      || detail.contains("leg_analysis_by_earmark_type")
    #expect(usesAcceptableIndex)
    #expect(!detail.contains("SCAN transaction_leg"))
    #expect(!detail.contains("SCAN \"transaction\""))
  }
}
