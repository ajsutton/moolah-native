import Foundation

/// UTC-anchored financial-month bucket key (`YYYYMM`) shared by every
/// analysis path that groups transactions into months respecting the
/// user's configured `monthEnd` cut-off.
///
/// Anchored to a UTC Gregorian calendar so a transaction whose UTC
/// `Date()` represents e.g. `2025-03-25` lands in the same financial-month
/// bucket regardless of the runner's local timezone. The previous
/// implementations on both `CloudKitAnalysisRepository` and the
/// SwiftData-era forecaster used `Calendar.current` against
/// UTC-anchored dates, which in negative-UTC zones (e.g.
/// America/New_York) reads the previous local-time day and mis-buckets
/// rows on the boundary day.
///
/// Both `GRDBAnalysisRepository.financialMonth` and
/// `CloudKitAnalysisRepository.financialMonth` forward to this helper
/// so the GRDB and CloudKit aggregation paths cannot drift apart on the
/// boundary calendar — every path that buckets months sees the same
/// UTC-anchored result.
enum FinancialMonth {
  /// `TimeZone(identifier: "UTC")` is documented to never return nil
  /// for the canonical `"UTC"` identifier; the `??` fallback uses the
  /// always-non-nil seconds-from-GMT initialiser so the resolved
  /// constant is non-optional without an `as!` / `!` cast (keeping
  /// SwiftLint's `force_unwrapping` rule satisfied).
  ///
  /// Module-internal so sibling files (e.g.
  /// `GRDBAnalysisRepository+Conversion.swift`) can share the same
  /// resolved instance instead of re-deriving it.
  static let utcTimeZone: TimeZone =
    TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? TimeZone.current

  /// UTC-anchored Gregorian calendar used to derive the financial-month
  /// bucket key from a UTC-anchored `Date`. `Calendar` is a `Sendable`
  /// value type so the constant has no concurrency caveats. Allocated
  /// once so per-row bucketing in the analysis loops doesn't pay
  /// calendar construction on every iteration.
  private static let utcGregorianCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcTimeZone
    return calendar
  }()

  /// Compute the financial-month key (`YYYYMM`) for `date`, respecting
  /// the user's configured `monthEnd` cut-off.
  ///
  /// Transactions whose UTC day-of-month is greater than `monthEnd` roll
  /// into the next calendar month's bucket; transactions on or before
  /// `monthEnd` stay in the current month. December rollovers wrap to
  /// the next year. `monthEnd: 31` keeps every UTC day in its own
  /// calendar month.
  static func key(for date: Date, monthEnd: Int) -> String {
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
}
