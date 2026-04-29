import Foundation
import GRDB

/// SQL aggregation + Swift assembly helpers for `fetchExpenseBreakdown`.
///
/// Lifted out of the main `GRDBAnalysisRepository` body to keep its
/// `type_body_length` budget intact. Mirrors the
/// `GRDBAccountRepository+Positions.swift` shape: every helper is `static`
/// and takes its dependencies (database, instruments, conversion service)
/// as parameters so it doesn't need access to the main class's `private`
/// stored properties from a sibling-file extension.
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

  /// Diagnostic context passed to the conversion-failure handler so the
  /// caller's logger can identify which `(day, category, instrument)`
  /// tuple failed without coupling this helper to a `Logger` instance.
  struct ConversionFailureContext: Sendable {
    let day: String
    let categoryId: UUID?
    let instrumentId: String
  }

  /// Bundle of per-row diagnostic callbacks used by
  /// `assembleExpenseBreakdown`. Grouped into a struct so the function
  /// signature stays under SwiftLint's `function_parameter_count`
  /// budget, and so future analysis methods can share the same
  /// handler shape.
  struct ExpenseBreakdownHandlers: Sendable {
    let handleUnparseableDay: @Sendable (String) -> Void
    let handleConversionFailure: @Sendable (Error, ConversionFailureContext) -> Void
  }

  /// Runs the per-(day, category, instrument) SUM(quantity) aggregation
  /// pinned by
  /// `AnalysisAggregationPlanPinningTests.fetchExpenseBreakdownUsesCategoryCoveringIndex`.
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
  /// `handlers.handleUnparseableDay` lets the caller route malformed
  /// `day` strings to a logger without coupling this helper to a
  /// specific `Logger` instance. `handlers.handleConversionFailure` is
  /// invoked once per failing row so each failure surfaces individually
  /// in diagnostics rather than being collapsed into the first failure
  /// to escape — the loop continues processing remaining rows, then
  /// re-throws the first failure after the walk so the function
  /// preserves its existing "throws on conversion error" contract while
  /// still delivering the per-row detail required by
  /// `INSTRUMENT_CONVERSION_GUIDE.md` Rule 11. A `CancellationError` is
  /// rethrown immediately and never folded into the conversion-failure
  /// path.
  @concurrent
  static func assembleExpenseBreakdown(
    aggregation: ExpenseBreakdownAggregation,
    profileInstrument: Instrument,
    conversionService: any InstrumentConversionService,
    monthEnd: Int,
    handlers: ExpenseBreakdownHandlers
  ) async throws -> [ExpenseBreakdown] {
    var buckets: [String: [UUID?: InstrumentAmount]] = [:]
    var firstConversionError: Error?
    for row in aggregation.rows {
      guard let day = Self.parseDayString(row.day) else {
        handlers.handleUnparseableDay(row.day)
        continue
      }
      let instrument =
        aggregation.instrumentMap[row.instrumentId]
        ?? Instrument.fiat(code: row.instrumentId)
      let amount: InstrumentAmount
      do {
        amount = try await Self.convertedQuantity(
          storageValue: row.qty,
          instrument: instrument,
          to: profileInstrument,
          on: day,
          conversionService: conversionService)
      } catch is CancellationError {
        // Cooperative cancellation surfaces unchanged — never folded
        // into the per-row conversion-failure log path.
        throw CancellationError()
      } catch {
        let context = ConversionFailureContext(
          day: row.day, categoryId: row.categoryId, instrumentId: row.instrumentId)
        handlers.handleConversionFailure(error, context)
        if firstConversionError == nil {
          firstConversionError = error
        }
        continue
      }
      let month = Self.financialMonth(for: day, monthEnd: monthEnd)
      let current = buckets[month]?[row.categoryId] ?? .zero(instrument: profileInstrument)
      buckets[month, default: [:]][row.categoryId] = current + amount
    }
    if let firstConversionError {
      // Preserve the existing observable behaviour (throws on the first
      // conversion error) while having logged every per-row failure.
      // Per-bucket `InstrumentAmount?` requires reshaping
      // `ExpenseBreakdown` and every other analysis result type
      // together — out of scope for this method's individual rewrite.
      throw firstConversionError
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
