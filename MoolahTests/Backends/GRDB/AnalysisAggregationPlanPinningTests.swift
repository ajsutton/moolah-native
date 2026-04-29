// MoolahTests/Backends/GRDB/AnalysisAggregationPlanPinningTests.swift

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
    // to non-scheduled, account-bound expense legs with a category.
    // The covering composite `leg_analysis_by_type_category`
    // (type, category_id, instrument_id, transaction_id, quantity) lets
    // SQLite drive the aggregation off the index without visiting the
    // base table — a SCAN of `transaction_leg` is the regression signal.
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
          AND leg.account_id IS NOT NULL
          AND (? IS NULL OR t.date >= ?)
        GROUP BY day, category_id, instrument_id
        ORDER BY day ASC, category_id ASC
        """,
      arguments: [Date?.none, Date?.none])
    #expect(detail.contains("leg_analysis_by_type_category"))
    #expect(!detail.contains("SCAN transaction_leg"))
    // SQLite emits `USING INDEX` (not `USING COVERING INDEX`) for this
    // query because the partial-index choice and the JOIN to
    // `transaction` (visited via PK to read `recur_period` and `date`)
    // mean SQLite can't statically declare the leg-side scan
    // base-table-free in EXPLAIN output, even though every column it
    // references from `leg` is in the composite. The
    // no-base-table-scan signal is captured by the `SCAN transaction_leg`
    // negative assertion above — that's what flips if the index loses
    // its leg-side coverage. Asserting on `USING COVERING INDEX`
    // would force-fail this test against a plan that's actually
    // optimal for SQLite, so we don't.
    //
    // The output is sorted by `(day, category_id)` where
    // `day = DATE(t.date)` — a derived value that no index keys, so
    // SQLite is free to use a temp B-tree for the ORDER BY. We don't
    // assert against `USE TEMP B-TREE FOR ORDER BY`: the query's
    // correctness depends on the per-day grouping (rate-equivalent to
    // per-leg conversion), not on the absence of a sort.
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
