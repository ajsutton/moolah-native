import Foundation

/// Conversion and day-bucketing helpers used by the SQL-driven analysis
/// methods on `GRDBAnalysisRepository`. Lifted into a sibling extension so
/// the main repository file stays small and so future SQL rewrites
/// (`fetchIncomeAndExpense`, `fetchCategoryBalances`,
/// `fetchDailyBalances`) can share the same day-string parser and the
/// (storageValue, instrument) → converted `InstrumentAmount` helper.
///
/// The helpers are static and free of CloudKit-only references so they
/// stand on their own once the SwiftData-era
/// `CloudKitAnalysisRepository` extension files are deleted.
extension GRDBAnalysisRepository {
  /// `Sendable` wrapper around an `ISO8601DateFormatter` so a single
  /// shared instance can be hoisted to a `static let` without
  /// `nonisolated(unsafe)` (forbidden in production by
  /// `guides/CONCURRENCY_GUIDE.md` §8). `ISO8601DateFormatter` predates
  /// Swift `Sendable` but is Apple-documented as thread-safe
  /// ("ISO8601DateFormatter is thread safe."). The wrapper is `final`,
  /// holds the formatter as a `let`, and exposes a read-only accessor —
  /// nothing mutates post-init, so the `@unchecked Sendable` waiver
  /// only bypasses Swift's structural check, not runtime safety.
  private final class SendableDayFormatter: @unchecked Sendable {
    let formatter: ISO8601DateFormatter

    init(_ formatter: ISO8601DateFormatter) { self.formatter = formatter }
  }

  /// Reused day-string parser anchored to UTC so the resulting `Date`
  /// round-trips through the conversion service's UTC-keyed ISO
  /// formatter onto the same day string. Hoisted to a static let so
  /// per-row aggregation doesn't pay the formatter allocator hit on
  /// every iteration.
  private static let dayFormatter: SendableDayFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
    formatter.timeZone = FinancialMonth.utcTimeZone
    return SendableDayFormatter(formatter)
  }()

  /// Day-string parser used by every SQL-driven method that aggregates
  /// `(DATE(t.date), …)`.
  ///
  /// SQLite's `DATE()` extracts the UTC calendar date of the stored
  /// timestamp (GRDB writes `Date` as UTC TEXT). The parser is anchored
  /// to UTC so the resulting `Date` round-trips through the conversion
  /// service's `ISO8601DateFormatter` (UTC-keyed) onto the same date
  /// string — preserving the per-day rate-cache equivalence.
  ///
  /// Returns `nil` for malformed day strings; callers log and skip the
  /// row rather than silently swallowing.
  static func parseDayString(_ day: String) -> Date? {
    dayFormatter.formatter.date(from: day)
  }

  /// Compute the financial-month key (`YYYYMM`) for `date`, respecting
  /// the user's configured `monthEnd` cut-off.
  ///
  /// Forwards to the shared `FinancialMonth.key(for:monthEnd:)` helper
  /// so this path and the CloudKit-side
  /// `CloudKitAnalysisRepository.financialMonth` resolve to the same
  /// UTC-anchored implementation — eliminating the previous risk that
  /// the two code paths could drift on boundary-day rows.
  static func financialMonth(for date: Date, monthEnd: Int) -> String {
    FinancialMonth.key(for: date, monthEnd: monthEnd)
  }

  /// Build an `InstrumentAmount` in `target` from a SQL-summed storage
  /// quantity, converting on `day` when the source instrument differs.
  /// Same-instrument legs short-circuit and skip the conversion service.
  ///
  /// The leg-less signature (vs. CloudKit's
  /// `convertedAmount(_:to:on:conversionService:)` which takes a
  /// `TransactionLeg`) reflects the SQL aggregation: rows arrive as
  /// already-summed `(storageValue, instrumentId)` tuples, with no leg
  /// available to project from.
  @concurrent
  static func convertedQuantity(
    storageValue: Int64,
    instrument: Instrument,
    to target: Instrument,
    on day: Date,
    conversionService: any InstrumentConversionService
  ) async throws -> InstrumentAmount {
    let amount = InstrumentAmount(storageValue: storageValue, instrument: instrument)
    if instrument.id == target.id {
      return amount
    }
    let converted = try await conversionService.convert(
      amount.quantity, from: instrument, to: target, on: day)
    return InstrumentAmount(quantity: converted, instrument: target)
  }
}
