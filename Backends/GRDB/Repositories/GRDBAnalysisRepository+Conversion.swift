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
  /// Reused `ISO8601DateFormatter` for parsing the `YYYY-MM-DD` strings
  /// returned by SQLite's `DATE()`. `ISO8601DateFormatter` is documented
  /// thread-safe by Apple ("ISO8601DateFormatter is thread safe.") but
  /// is not declared `Sendable` in Foundation's headers, so a
  /// `nonisolated(unsafe)` shared instance avoids the per-row allocator
  /// hit while keeping the compiler informed. Anchored to UTC so the
  /// parsed `Date` round-trips through the conversion service's
  /// UTC-keyed ISO formatter onto the same day string.
  nonisolated(unsafe) private static let dayFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
    formatter.timeZone = utcTimeZone
    return formatter
  }()

  /// UTC-anchored Gregorian calendar used to derive the financial-month
  /// bucket key from a UTC-anchored day `Date`. `Calendar` is a
  /// `Sendable` value type so the constant has no concurrency caveats.
  /// Allocated once so per-row bucketing inside
  /// `assembleExpenseBreakdown` doesn't pay calendar construction on
  /// every iteration.
  private static let utcGregorianCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcTimeZone
    return calendar
  }()

  /// `TimeZone(identifier: "UTC")` is documented to never return nil
  /// for the canonical `"UTC"` identifier; the `??` fallback uses the
  /// always-non-nil seconds-from-GMT initialiser so the resolved
  /// constant is non-optional without an `as!` / `!` cast (keeping
  /// SwiftLint's `force_unwrapping` rule satisfied).
  private static let utcTimeZone: TimeZone =
    TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? TimeZone.current

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
    dayFormatter.date(from: day)
  }

  /// Compute the financial-month key (`YYYYMM`) for `date`, respecting
  /// the user's configured `monthEnd` cut-off.
  ///
  /// Anchored to a UTC Gregorian calendar so a transaction whose UTC
  /// `DATE()` is e.g. `2025-03-25` lands in the same financial-month
  /// bucket regardless of the runner's local timezone. The previous
  /// implementation forwarded to `CloudKitAnalysisRepository.financialMonth`
  /// which used `Calendar.current`; in negative-UTC zones (e.g.
  /// America/New_York) `Calendar.current.component(.day, from:)` against
  /// the UTC-midnight `Date` returned by `parseDayString` returns the
  /// previous day, mis-bucketing rows on the boundary day.
  static func financialMonth(for date: Date, monthEnd: Int) -> String {
    let calendar = utcGregorianCalendar
    let dayOfMonth = calendar.component(.day, from: date)
    let adjustedDate: Date
    if dayOfMonth > monthEnd {
      guard let shifted = calendar.date(byAdding: .month, value: 1, to: date) else {
        return defaultMonthKey(for: date, calendar: calendar)
      }
      adjustedDate = shifted
    } else {
      adjustedDate = date
    }
    let year = calendar.component(.year, from: adjustedDate)
    let month = calendar.component(.month, from: adjustedDate)
    return String(format: "%04d%02d", year, month)
  }

  private static func defaultMonthKey(for date: Date, calendar: Calendar) -> String {
    let year = calendar.component(.year, from: date)
    let month = calendar.component(.month, from: date)
    return String(format: "%04d%02d", year, month)
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
