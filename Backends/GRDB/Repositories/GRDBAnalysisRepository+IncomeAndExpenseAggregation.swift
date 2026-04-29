import Foundation
import GRDB

/// SQL-side helpers for the `fetchIncomeAndExpense` aggregation. Holds
/// the query string, the row decoder, and the `database.read` entry
/// point — split out of `+IncomeAndExpense.swift` so that file's Swift
/// assembly path (the per-row conversion + month-bucket fold) stays
/// under the SwiftLint `file_length` budget.
extension GRDBAnalysisRepository {
  /// Runs the per-(day, instrument) conditional-sum aggregation
  /// pinned by
  /// `AnalysisAggregationPlanPinningTests.fetchIncomeAndExpenseUsesTypeAccountIndex`.
  ///
  /// **LEFT JOIN account.** The transfer branches read `account.type`
  /// to detect investment-account legs (`a.type` is NULL for
  /// nil-`account_id` legs). `income_qty` / `expense_qty` require
  /// `a.type IS NOT NULL` to mirror CloudKit `applyByType`'s
  /// `hasAccount` guard but DO NOT exclude investment accounts — a
  /// dividend (`.income` on a brokerage) or a brokerage fee
  /// (`.expense` on a brokerage) lands in the main totals. The
  /// `a.type = 'investment'` predicate only narrows the
  /// `investment_transfer_*` columns.
  ///
  /// **Why six aggregates in one query.** A single pass over the leg
  /// index keeps all six sums consistent with one MVCC snapshot —
  /// six independent queries could surface inconsistent totals if a
  /// writer commits between them.
  static func fetchIncomeAndExpenseAggregation(
    database: any DatabaseReader,
    after: Date?
  ) async throws -> IncomeAndExpenseAggregation {
    try await database.read { database -> IncomeAndExpenseAggregation in
      let arguments: StatementArguments = ["after": after]
      let sqlRows = try Row.fetchAll(
        database, sql: incomeAndExpenseAggregationSQL, arguments: arguments)
      let rows = sqlRows.compactMap(Self.mapAggregationRow(_:))
      let instrumentMap = try InstrumentRow.fetchInstrumentMap(database: database)
      return IncomeAndExpenseAggregation(rows: rows, instrumentMap: instrumentMap)
    }
  }

  /// Decode one `EXPLAIN`-pinned aggregation row, returning `nil` for
  /// malformed rows (e.g. NULL `day` / `instrument_id`) so the loop
  /// skips them without breaking the rest of the snapshot.
  static func mapAggregationRow(_ row: Row) -> IncomeAndExpenseRow? {
    guard let day: String = row["day"] else { return nil }
    guard let instrumentId: String = row["instrument_id"] else { return nil }
    return IncomeAndExpenseRow(
      day: day,
      instrumentId: instrumentId,
      incomeQty: row["income_qty"] ?? 0,
      expenseQty: row["expense_qty"] ?? 0,
      earmarkedIncomeQty: row["earmarked_income_qty"] ?? 0,
      earmarkedExpenseQty: row["earmarked_expense_qty"] ?? 0,
      investmentTransferInQty: row["investment_transfer_in_qty"] ?? 0,
      investmentTransferOutQty: row["investment_transfer_out_qty"] ?? 0)
  }
}

/// File-private SQL for the per-(day, instrument) aggregation. Hoisted
/// to file scope so the read closure body stays under SwiftLint's
/// `closure_body_length` budget. The query's plan shape (index usage,
/// absence of full-table scans) is pinned by
/// `AnalysisAggregationPlanPinningTests.fetchIncomeAndExpenseUsesTypeAccountIndex`;
/// structural changes here (WHERE predicates, JOIN reorders, GROUP BY)
/// should be reflected in that test so the plan stays under EXPLAIN.
private let incomeAndExpenseAggregationSQL = """
  SELECT
      DATE(t.date)         AS day,
      leg.instrument_id    AS instrument_id,
      SUM(CASE WHEN leg.type = 'income'
                AND a.type IS NOT NULL
               THEN leg.quantity ELSE 0 END)        AS income_qty,
      SUM(CASE WHEN leg.type = 'expense'
                AND a.type IS NOT NULL
               THEN leg.quantity ELSE 0 END)        AS expense_qty,
      SUM(CASE WHEN leg.earmark_id IS NOT NULL
                AND leg.type = 'income'
               THEN leg.quantity ELSE 0 END)        AS earmarked_income_qty,
      SUM(CASE WHEN leg.earmark_id IS NOT NULL
                AND leg.type = 'expense'
               THEN leg.quantity ELSE 0 END)        AS earmarked_expense_qty,
      SUM(CASE WHEN leg.type = 'transfer'
                AND a.type = 'investment'
                AND leg.quantity > 0
               THEN leg.quantity ELSE 0 END)        AS investment_transfer_in_qty,
      SUM(CASE WHEN leg.type = 'transfer'
                AND a.type = 'investment'
                AND leg.quantity < 0
               THEN leg.quantity ELSE 0 END)        AS investment_transfer_out_qty
  FROM transaction_leg leg
  JOIN "transaction"    t ON leg.transaction_id = t.id
  LEFT JOIN account     a ON leg.account_id = a.id
  WHERE t.recur_period IS NULL
    AND (:after IS NULL OR t.date >= :after)
  GROUP BY day, leg.instrument_id
  ORDER BY day ASC
  """
