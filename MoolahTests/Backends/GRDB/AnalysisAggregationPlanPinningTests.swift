import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning tests for the analysis aggregations and
/// the still-intentional full-table reads on the analysis hot path.
///
/// Split out of `AnalysisPlanPinningTests` so each file stays under the
/// SwiftLint `type_body_length` budget. Same `EXPLAIN QUERY PLAN`
/// methodology as the parent suite (see its file header).
@Suite("Analysis aggregation plan-pinning")
struct AnalysisAggregationPlanPinningTests {
  /// `makeDatabase` and `planDetail` are shared with
  /// `AnalysisPlanPinningTests` and `CSVImportPlanPinningTests` via
  /// `PlanPinningTestHelpers`.
  private func makeDatabase() throws -> DatabaseQueue {
    try PlanPinningTestHelpers.makeDatabase()
  }

  private func planDetail(
    _ database: DatabaseQueue, query: String, arguments: StatementArguments = []
  ) throws -> String {
    try PlanPinningTestHelpers.planDetail(database, query: query, arguments: arguments)
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

  @Test("fetchExpenseBreakdown SQL uses leg_analysis_by_type_category covering index")
  func fetchExpenseBreakdownUsesCategoryCoveringIndex() throws {
    let database = try makeDatabase()
    // Mirrors the exact SQL shape used by
    // `GRDBAnalysisRepository.fetchExpenseBreakdown(monthEnd:after:)`:
    // GROUP BY `(DATE(t.date), category_id, instrument_id)` restricted
    // to non-scheduled expense legs with a category. `account_id` is
    // intentionally absent from the WHERE clause for two reasons,
    // documented on `fetchExpenseBreakdownAggregation`:
    // 1. CloudKit parity — categorised expense legs without an account
    //    must appear in the breakdown.
    // 2. Covering — `account_id` is not in
    //    `leg_analysis_by_type_category`'s column list, so adding the
    //    predicate forces a base-row fetch and flips the plan from
    //    `USING COVERING INDEX` to plain `USING INDEX`.
    let detail = try planDetail(
      database,
      query: """
        SELECT DATE(t.date)        AS day,
               leg.category_id     AS category_id,
               leg.instrument_id   AS instrument_id,
               SUM(leg.quantity)   AS qty
        FROM transaction_leg leg
        JOIN "transaction"    t ON leg.transaction_id = t.id
        WHERE t.recur_period IS NULL
          AND leg.type = 'expense'
          AND leg.category_id IS NOT NULL
          AND (? IS NULL OR t.date >= ?)
        GROUP BY day, category_id, instrument_id
        ORDER BY day ASC, category_id ASC
        """,
      arguments: [Date?.none, Date?.none])
    #expect(detail.contains("leg_analysis_by_type_category"))
    #expect(detail.contains("USING COVERING INDEX"))
    #expect(!detail.contains("SCAN transaction_leg"))
    // SQLite's plan is permitted to (and does) include both
    // `USE TEMP B-TREE FOR GROUP BY` and `USE TEMP B-TREE FOR ORDER BY`.
    // We do NOT reject those lines because the GROUP BY and ORDER BY
    // both key on `day = DATE(t.date)` — a derived expression with no
    // index keying. SQLite has no choice but to materialise the groups
    // and the sort in temp B-trees; trying to forbid them would force
    // the planner away from the covering index entirely. The
    // covering-index property captured by the positive
    // `USING COVERING INDEX` assertion is the perf-critical signal —
    // it's what flips when the leg-side composite loses a column or
    // the WHERE clause grows a predicate the partial index doesn't
    // cover (e.g. a re-introduced `account_id IS NOT NULL`).
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
