import Foundation
import Testing

@testable import Moolah

// Shared helpers for the AnalysisRepository contract test suite. Hoisted here
// so the split `AnalysisRepository*Tests.swift` files can share date, decimal,
// and seeding utilities without duplication.
//
// Visibility is internal (was fileprivate) so sibling test files across the
// split suites can use these helpers — `strict_fileprivate` disallows
// fileprivate in this codebase.
enum AnalysisTestHelpers {
  /// Gregorian calendar used by every test in the suite so rate-by-date lookups
  /// agree across files.
  static let calendar = Calendar(identifier: .gregorian)

  /// Current calendar — distinct from `calendar` above; some tests want the
  /// user's locale (e.g. `Calendar.current`) rather than a fixed Gregorian.
  static let currentCalendar = Calendar.current

  /// Build a Date from year/month/day components (Gregorian) and fail the test
  /// (via `#require`) if components are invalid.
  static func date(year: Int, month: Int, day: Int) throws -> Date {
    try #require(
      calendar.date(from: DateComponents(year: year, month: month, day: day)))
  }

  /// Build a local-calendar `Date` at a specific `hour:` on the given
  /// day. Uses `Calendar.current` (not the fixed-Gregorian `calendar`
  /// used by the parameterless-hour `date(year:month:day:)` overload)
  /// so the resulting `Date`'s `startOfDay` agrees with the
  /// production fold's `Calendar.current.startOfDay(for:
  /// row.sampleDate)` math — required by Rule 10
  /// same-`startOfDay` normalization tests.
  ///
  /// Renamed from the `date(...)` overload to make the calendar
  /// asymmetry explicit at the call site: the prefix-shared
  /// `date(year:month:day:)` is fixed-Gregorian; this is local.
  static func localDate(
    year: Int, month: Int, day: Int, hour: Int
  ) throws -> Date {
    try #require(
      currentCalendar.date(
        from: DateComponents(
          year: year, month: month, day: day, hour: hour)))
  }

  /// Build a UTC-anchored Date from year/month/day components.
  ///
  /// SQL `DATE(t.date)` extracts the UTC calendar day, and
  /// `GRDBAnalysisRepository+Conversion.swift` parses and bucketises in
  /// UTC, so tests that pin a specific calendar-day boundary (e.g.
  /// monthEnd=25) must build txn dates in UTC for the SQL DATE
  /// extraction to land on the expected calendar day regardless of the
  /// runner's local timezone.
  static func utcDate(year: Int, month: Int, day: Int, hour: Int = 12) throws -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    return try #require(
      calendar.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour)))
  }

  /// Shift a date by `value` days using the Gregorian calendar.
  static func addingDays(_ value: Int, to date: Date) throws -> Date {
    try #require(calendar.date(byAdding: .day, value: value, to: date))
  }

  /// Shift a date by `value` days using the user's current calendar — for
  /// tests that anchor on `Date()` rather than a fixed day.
  static func addingDaysCurrentCalendar(_ value: Int, to date: Date) throws -> Date {
    try #require(currentCalendar.date(byAdding: .day, value: value, to: date))
  }

  /// Shift a date by `value` months using the user's current calendar.
  static func addingMonthsCurrentCalendar(_ value: Int, to date: Date) throws -> Date {
    try #require(currentCalendar.date(byAdding: .month, value: value, to: date))
  }

  /// Wrap `Decimal(string:)` with `#require` so invalid literals fail loudly
  /// rather than silently force-unwrap.
  static func decimal(_ string: String) throws -> Decimal {
    try #require(Decimal(string: string))
  }
}
