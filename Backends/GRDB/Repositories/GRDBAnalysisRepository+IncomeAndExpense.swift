import Foundation
import GRDB

/// SQL aggregation + Swift assembly helpers for `fetchIncomeAndExpense`.
/// Mirrors the `+ExpenseBreakdown.swift` and `+CategoryBalances.swift`
/// shapes: static helpers take their dependencies as parameters so
/// this sibling-file extension doesn't reach into the main class's
/// `private` storage.
///
/// The SQL groups by `(DATE(t.date), instrument_id)` with six
/// conditional `SUM(CASE …)` aggregates that route each leg to the
/// right monthly bucket. Per-row conversion runs in Swift so the
/// per-day rate-cache equivalence (Rule 5 of
/// `INSTRUMENT_CONVERSION_GUIDE.md`) holds.
///
/// **Investment-transfer split.** Transfers into investment accounts
/// route to `earmarkedIncome` (positive quantities) and
/// `earmarkedExpense` (negative quantities, sign-flipped on the way
/// in). The CloudKit reference path (`applyTransferLeg`) splits by
/// sign at the leg level, so the SQL splits the SUM by sign rather
/// than collapsing both directions — losing the sign before the flip
/// would mis-count any day with both a deposit and a withdrawal in
/// the same instrument. The split mirrors the contract pinned by
/// `AnalysisIncomeExpenseTests.investmentTransferClassification`.
extension GRDBAnalysisRepository {
  /// One row of the SQL aggregation that drives `fetchIncomeAndExpense`.
  /// Each row carries six conditional sums for one `(day, instrument)`
  /// tuple. `day` is the ISO-8601 `YYYY-MM-DD` string returned by
  /// `DATE(t.date)` — parsed in Swift on the way out of the read
  /// closure so the `Database` reference doesn't escape into the
  /// conversion service.
  struct IncomeAndExpenseRow: Sendable {
    let day: String
    let instrumentId: String
    let incomeQty: Int64
    let expenseQty: Int64
    let earmarkedIncomeQty: Int64
    let earmarkedExpenseQty: Int64
    /// Sum of positive transfer-leg quantities into investment
    /// accounts — routes to `earmarkedIncome` after conversion.
    let investmentTransferInQty: Int64
    /// Sum of negative transfer-leg quantities into investment
    /// accounts — sign-flipped to positive and routed to
    /// `earmarkedExpense` after conversion. Stored as the raw negative
    /// SUM here so the signed-amount addition into `earmarkedProfit`
    /// doesn't need a second column.
    let investmentTransferOutQty: Int64
  }

  /// Pair of SQL output rows and the instrument lookup, fetched in a
  /// single MVCC snapshot so a concurrent writer can't drop a row's
  /// `instrument_id` between the two reads.
  struct IncomeAndExpenseAggregation: Sendable {
    let rows: [IncomeAndExpenseRow]
    let instrumentMap: [String: Instrument]
  }

  /// Diagnostic context passed to the conversion-failure handler so
  /// the caller's logger can identify which `(day, instrument)` tuple
  /// failed without coupling this helper to a `Logger` instance.
  struct IncomeAndExpenseFailureContext: Sendable {
    let day: String
    let instrumentId: String
  }

  /// Bundle of per-row diagnostic callbacks used by
  /// `assembleIncomeAndExpense`. Matches the
  /// `ExpenseBreakdownHandlers` / `CategoryBalancesHandlers` shape so
  /// future analysis methods can share the same handler pattern.
  struct IncomeAndExpenseHandlers: Sendable {
    let handleUnparseableDay: @Sendable (String) -> Void
    let handleConversionFailure: @Sendable (Error, IncomeAndExpenseFailureContext) -> Void
  }

  /// Mutable per-month accumulator used during assembly. Stored
  /// outside `MonthlyIncomeExpense` (which has only `let` fields) so
  /// the loop can `+=` into each bucket without rebuilding the value
  /// type on every leg. `start` / `end` track the min/max parsed-day
  /// `Date` so the resulting `MonthlyIncomeExpense` preserves the
  /// SwiftData-era display behaviour.
  private struct MonthBucket {
    var start: Date
    var end: Date
    var income: InstrumentAmount
    var expense: InstrumentAmount
    var earmarkedIncome: InstrumentAmount
    var earmarkedExpense: InstrumentAmount
    var earmarkedProfit: InstrumentAmount
  }

  /// Bundle of converted per-row sums fed into a month bucket. Lifted
  /// out of the assembly loop so the bucket-update helper stays under
  /// SwiftLint's `function_parameter_count` budget.
  private struct ConvertedRowSums {
    let day: Date
    let income: InstrumentAmount
    let expense: InstrumentAmount
    let earmarkedIncome: InstrumentAmount
    let earmarkedExpense: InstrumentAmount
    let investmentTransferIn: InstrumentAmount
    let investmentTransferOut: InstrumentAmount
  }

  /// Runs the per-(day, instrument) conditional-sum aggregation
  /// pinned by
  /// `AnalysisAggregationPlanPinningTests.fetchIncomeAndExpenseUsesTypeAccountIndex`.
  ///
  /// **LEFT JOIN account.** The investment-account routing reads
  /// `account.type` only for legs whose `account_id` is NOT NULL —
  /// `a.type` is NULL for nil-`account_id` legs, and the
  /// `income_qty` / `expense_qty` CASE branches require
  /// `a.type IS NOT NULL` to mirror the CloudKit `applyByType`
  /// `hasAccount` guard.
  ///
  /// **Why six aggregates in one query.** A single pass over the leg
  /// index keeps all six sums consistent with the same MVCC snapshot
  /// — running six independent queries against a concurrently
  /// mutating writer could surface internally inconsistent totals.
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
  private static func mapAggregationRow(_ row: Row) -> IncomeAndExpenseRow? {
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

  /// Walks the SQL aggregation rows, converts each row's six sums to
  /// the profile instrument on the row's own day, and accumulates
  /// into per-financial-month buckets. Conversion runs outside the
  /// `database.read` closure (in this async helper) so the `Database`
  /// reference stays inside the snapshot.
  ///
  /// Mirrors `assembleExpenseBreakdown`'s per-row error contract:
  /// `handleUnparseableDay` and `handleConversionFailure` are invoked
  /// per failing row so each failure surfaces individually in
  /// diagnostics; the loop continues processing remaining rows then
  /// re-throws the first conversion error after the walk so the
  /// function preserves its existing "throws on conversion error"
  /// contract while still delivering the per-row detail required by
  /// `INSTRUMENT_CONVERSION_GUIDE.md` Rule 11. A `CancellationError`
  /// is rethrown immediately and never folded into the
  /// conversion-failure path.
  ///
  /// **Investment-transfer fold-in.** Each row's
  /// `investmentTransferInQty` (always positive) folds into
  /// `earmarkedIncome` directly. `investmentTransferOutQty` (always
  /// negative or zero) is sign-flipped before adding to
  /// `earmarkedExpense` — preserving the CloudKit `applyTransferLeg`
  /// semantics byte-for-byte. Both raw signed transfer sums also
  /// accumulate into `earmarkedProfit`.
  @concurrent
  static func assembleIncomeAndExpense(
    aggregation: IncomeAndExpenseAggregation,
    profileInstrument: Instrument,
    conversionService: any InstrumentConversionService,
    monthEnd: Int,
    handlers: IncomeAndExpenseHandlers
  ) async throws -> [MonthlyIncomeExpense] {
    var buckets: [String: MonthBucket] = [:]
    var firstConversionError: Error?
    for row in aggregation.rows {
      guard let day = Self.parseDayString(row.day) else {
        handlers.handleUnparseableDay(row.day)
        continue
      }
      let instrument =
        aggregation.instrumentMap[row.instrumentId]
        ?? Instrument.fiat(code: row.instrumentId)
      let converted: ConvertedRowSums
      do {
        converted = try await Self.convertRowSums(
          row: row,
          day: day,
          instrument: instrument,
          profileInstrument: profileInstrument,
          conversionService: conversionService)
      } catch let cancel as CancellationError {
        // Cooperative cancellation surfaces unchanged — never folded
        // into the per-row conversion-failure log path.
        throw cancel
      } catch {
        let context = IncomeAndExpenseFailureContext(
          day: row.day, instrumentId: row.instrumentId)
        handlers.handleConversionFailure(error, context)
        if firstConversionError == nil {
          firstConversionError = error
        }
        continue
      }
      let month = Self.financialMonth(for: day, monthEnd: monthEnd)
      var bucket =
        buckets[month]
        ?? Self.makeEmptyMonthBucket(day: day, instrument: profileInstrument)
      Self.applyConvertedRow(converted, into: &bucket)
      buckets[month] = bucket
    }
    if let firstConversionError {
      // Preserve the existing observable behaviour (throws on the
      // first conversion error) while having logged every per-row
      // failure.
      throw firstConversionError
    }
    return Self.flattenIncomeAndExpenseBuckets(buckets)
  }

  /// Converts each of the six per-row sums to the profile instrument
  /// on the row's `day`. Same-instrument sums short-circuit through
  /// `convertedQuantity`, so a row whose `instrumentId` already
  /// matches the profile incurs zero conversion-service calls.
  private static func convertRowSums(
    row: IncomeAndExpenseRow,
    day: Date,
    instrument: Instrument,
    profileInstrument: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> ConvertedRowSums {
    func convert(_ value: Int64) async throws -> InstrumentAmount {
      try await Self.convertedQuantityIfNonZero(
        storageValue: value,
        instrument: instrument,
        profileInstrument: profileInstrument,
        day: day,
        conversionService: conversionService)
    }
    return ConvertedRowSums(
      day: day,
      income: try await convert(row.incomeQty),
      expense: try await convert(row.expenseQty),
      earmarkedIncome: try await convert(row.earmarkedIncomeQty),
      earmarkedExpense: try await convert(row.earmarkedExpenseQty),
      investmentTransferIn: try await convert(row.investmentTransferInQty),
      investmentTransferOut: try await convert(row.investmentTransferOutQty))
  }

  /// Skip the conversion call when the storage value is zero — every
  /// CASE branch of the SQL emits `0` for non-matching legs, so most
  /// rows have several zero-value columns. Skipping the call keeps
  /// the conversion-service hit count tied to the row count rather
  /// than six-times the row count, preserving the per-row counter
  /// invariants asserted by `GRDBIncomeAndExpenseAssembleTests`.
  private static func convertedQuantityIfNonZero(
    storageValue: Int64,
    instrument: Instrument,
    profileInstrument: Instrument,
    day: Date,
    conversionService: any InstrumentConversionService
  ) async throws -> InstrumentAmount {
    if storageValue == 0 {
      return .zero(instrument: profileInstrument)
    }
    return try await Self.convertedQuantity(
      storageValue: storageValue,
      instrument: instrument,
      to: profileInstrument,
      on: day,
      conversionService: conversionService)
  }

  /// Build a fresh `MonthBucket` seeded with the row's day as both
  /// `start` and `end`. Subsequent rows widen the range via
  /// `applyConvertedRow`.
  private static func makeEmptyMonthBucket(
    day: Date,
    instrument: Instrument
  ) -> MonthBucket {
    MonthBucket(
      start: day,
      end: day,
      income: .zero(instrument: instrument),
      expense: .zero(instrument: instrument),
      earmarkedIncome: .zero(instrument: instrument),
      earmarkedExpense: .zero(instrument: instrument),
      earmarkedProfit: .zero(instrument: instrument))
  }

  /// Apply one converted row's six sums into a month bucket.
  ///
  /// Investment-transfer routing matches the CloudKit
  /// `applyTransferLeg` semantics byte-for-byte:
  /// - positive transfers (`investmentTransferIn`) add directly to
  ///   `earmarkedIncome`;
  /// - negative transfers (`investmentTransferOut`, stored as the raw
  ///   negative sum) are sign-flipped to a positive contribution to
  ///   `earmarkedExpense`;
  /// - both raw transfer sums add to `earmarkedProfit`.
  ///
  /// Non-transfer earmarked income/expense legs flow through with
  /// their original sign, matching `applyByType`'s expense branch
  /// (refunds with positive `expenseQty` reduce the negative expense
  /// total — see
  /// `AnalysisIncomeExpenseTests.expenseRefundsReduceTotal`).
  private static func applyConvertedRow(
    _ row: ConvertedRowSums,
    into bucket: inout MonthBucket
  ) {
    bucket.start = min(bucket.start, row.day)
    bucket.end = max(bucket.end, row.day)
    bucket.income += row.income
    bucket.expense += row.expense
    bucket.earmarkedIncome += row.earmarkedIncome + row.investmentTransferIn
    let investmentExpense = InstrumentAmount(
      quantity: -row.investmentTransferOut.quantity,
      instrument: row.investmentTransferOut.instrument)
    bucket.earmarkedExpense += row.earmarkedExpense + investmentExpense
    bucket.earmarkedProfit +=
      row.earmarkedIncome + row.earmarkedExpense
      + row.investmentTransferIn + row.investmentTransferOut
  }

  /// Emits one `MonthlyIncomeExpense` per non-empty bucket and sorts
  /// months descending — matching the CloudKit-era contract pinned
  /// by the income/expense contract suite. `profit = income + expense`
  /// is a derived signed-sum here rather than a separately-tracked
  /// accumulator because every leg that contributes to `profit`
  /// already contributes to `income` or `expense` with the same
  /// conditions.
  private static func flattenIncomeAndExpenseBuckets(
    _ buckets: [String: MonthBucket]
  ) -> [MonthlyIncomeExpense] {
    var results: [MonthlyIncomeExpense] = []
    results.reserveCapacity(buckets.count)
    for (month, bucket) in buckets {
      results.append(
        MonthlyIncomeExpense(
          month: month,
          start: bucket.start,
          end: bucket.end,
          income: bucket.income,
          expense: bucket.expense,
          profit: bucket.income + bucket.expense,
          earmarkedIncome: bucket.earmarkedIncome,
          earmarkedExpense: bucket.earmarkedExpense,
          earmarkedProfit: bucket.earmarkedProfit))
    }
    return results.sorted { $0.month > $1.month }
  }
}

/// File-private SQL string for the per-(day, instrument) aggregation.
/// Hoisted to file scope so the read closure body stays under
/// SwiftLint's `closure_body_length` budget; the literal text is
/// pinned by `AnalysisAggregationPlanPinningTests` so any drift here
/// trips the plan-pinning suite.
private let incomeAndExpenseAggregationSQL = """
  SELECT
      DATE(t.date)         AS day,
      leg.instrument_id    AS instrument_id,
      SUM(CASE WHEN leg.type = 'income'
                AND a.type IS NOT NULL
                AND a.type <> 'investment'
               THEN leg.quantity ELSE 0 END)        AS income_qty,
      SUM(CASE WHEN leg.type = 'expense'
                AND a.type IS NOT NULL
                AND a.type <> 'investment'
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
