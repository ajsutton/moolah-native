// Backends/GRDB/Repositories/GRDBAnalysisRepository+ExpenseBreakdown.swift

import Foundation
import GRDB

// SQL aggregation + Swift assembly helpers for `fetchExpenseBreakdown`.
//
// Lifted out of the main `GRDBAnalysisRepository` body to keep its
// `type_body_length` budget intact. Mirrors the
// `GRDBAccountRepository+Positions.swift` shape: every helper is `static`
// and takes its dependencies (database, instruments, conversion service)
// as parameters so it doesn't need access to the main class's `private`
// stored properties from a sibling-file extension.
extension GRDBAnalysisRepository {
  /// One row of the SQL aggregation that drives `fetchExpenseBreakdown`.
  /// `day` is the ISO-8601 `YYYY-MM-DD` string returned by `DATE(t.date)`
  /// — parsed in Swift on the way out of the read closure so the
  /// `Database` reference doesn't escape into the conversion service.
  struct ExpenseBreakdownRow: Sendable {
    let day: String
    let categoryId: UUID?
    let instrumentId: String
    let qty: Int64
  }

  /// Pair of SQL output rows and the instrument lookup, fetched in a
  /// single MVCC snapshot so a concurrent writer can't drop a row's
  /// `instrument_id` between the two reads.
  struct ExpenseBreakdownAggregation: Sendable {
    let rows: [ExpenseBreakdownRow]
    let instrumentMap: [String: Instrument]
  }

  /// Runs the per-(day, category, instrument) SUM(quantity) aggregation
  /// pinned by `AnalysisPlanPinningTests.fetchExpenseBreakdownUsesCategoryCoveringIndex`.
  /// The shape — `JOIN "transaction"`, `recur_period IS NULL`,
  /// `type = 'expense'`, `category_id IS NOT NULL`,
  /// `account_id IS NOT NULL`, optional `:after` — is what selects the
  /// `leg_analysis_by_type_category` covering composite (v3 schema). Any
  /// shape drift will trip the plan-pinning test.
  static func fetchExpenseBreakdownAggregation(
    database: any DatabaseReader,
    after: Date?
  ) async throws -> ExpenseBreakdownAggregation {
    try await database.read { database -> ExpenseBreakdownAggregation in
      let sql = """
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
          AND (:after IS NULL OR t.date >= :after)
        GROUP BY day, category_id, instrument_id
        ORDER BY day ASC, category_id ASC
        """
      let arguments: StatementArguments = ["after": after]
      let sqlRows = try Row.fetchAll(database, sql: sql, arguments: arguments)
      var rows: [ExpenseBreakdownRow] = []
      rows.reserveCapacity(sqlRows.count)
      for row in sqlRows {
        guard let day: String = row["day"] else { continue }
        guard let instrumentId: String = row["instrument_id"] else { continue }
        guard let qty: Int64 = row["qty"] else { continue }
        let categoryId: UUID? = row["category_id"]
        rows.append(
          ExpenseBreakdownRow(
            day: day, categoryId: categoryId, instrumentId: instrumentId, qty: qty))
      }
      let instrumentMap = try InstrumentRow.fetchInstrumentMap(database: database)
      return ExpenseBreakdownAggregation(rows: rows, instrumentMap: instrumentMap)
    }
  }

  /// Walks the SQL aggregation rows, converts each `(qty, instrument)`
  /// to the profile instrument on its own day, and buckets the results
  /// by `(financialMonth, categoryId)`. Conversion runs outside the
  /// `database.read` closure (in this async helper) so the `Database`
  /// reference stays inside the snapshot.
  ///
  /// `unparseableDayHandler` lets the caller route malformed `day`
  /// strings to a logger without coupling this helper to a specific
  /// `Logger` instance.
  static func assembleExpenseBreakdown(
    aggregation: ExpenseBreakdownAggregation,
    profileInstrument: Instrument,
    conversionService: any InstrumentConversionService,
    monthEnd: Int,
    onUnparseableDay: (String) -> Void
  ) async throws -> [ExpenseBreakdown] {
    var buckets: [String: [UUID?: InstrumentAmount]] = [:]
    for row in aggregation.rows {
      guard let day = Self.parseDayString(row.day) else {
        onUnparseableDay(row.day)
        continue
      }
      let instrument =
        aggregation.instrumentMap[row.instrumentId]
        ?? Instrument.fiat(code: row.instrumentId)
      let amount = try await Self.convertedQuantity(
        storageValue: row.qty,
        instrument: instrument,
        to: profileInstrument,
        on: day,
        conversionService: conversionService)
      let month = Self.financialMonth(for: day, monthEnd: monthEnd)
      let current = buckets[month]?[row.categoryId] ?? .zero(instrument: profileInstrument)
      buckets[month, default: [:]][row.categoryId] = current + amount
    }
    return flattenExpenseBreakdownBuckets(buckets)
  }

  /// Emits one `ExpenseBreakdown` per non-empty `(month, category)` bucket
  /// and sorts months descending — matching the SwiftData-era contract
  /// pinned by `AnalysisExpenseBreakdownTests.expenseBreakdownSortOrder`.
  private static func flattenExpenseBreakdownBuckets(
    _ buckets: [String: [UUID?: InstrumentAmount]]
  ) -> [ExpenseBreakdown] {
    var results: [ExpenseBreakdown] = []
    for (month, categories) in buckets {
      for (categoryId, total) in categories {
        results.append(
          ExpenseBreakdown(
            categoryId: categoryId, month: month, totalExpenses: total))
      }
    }
    return results.sorted { $0.month > $1.month }
  }
}
