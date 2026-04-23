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
// internal (was fileprivate) so sibling test files can use this helper
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
