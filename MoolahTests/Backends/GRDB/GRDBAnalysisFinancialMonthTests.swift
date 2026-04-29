import Foundation
import Testing

@testable import Moolah

/// Direct unit tests for `GRDBAnalysisRepository.financialMonth(for:monthEnd:)`
/// that exercise the UTC-anchored bucketing helper without standing up
/// a full GRDB stack.
///
/// The contract suite covers the boundary behaviour through the public
/// API, but only catches a regression to the previous
/// `Calendar.current`-based implementation when the test runner happens
/// to live in a negative-UTC timezone. These tests pin the UTC anchoring
/// timezone-independently: a transaction whose UTC-anchored `Date`
/// represents `2025-03-25` lands in `202503` for `monthEnd: 25`, and a
/// `Date` representing `2025-03-26` lands in `202504`. A
/// `Calendar.current`-based implementation in a negative-UTC zone reads
/// the previous local-time day and drifts the boundary call backwards.
@Suite("GRDBAnalysisRepository.financialMonth — UTC anchoring")
struct GRDBAnalysisFinancialMonthTests {
  /// Build a UTC-anchored Date at the given hour-of-day. Mirrors
  /// `AnalysisTestHelpers.utcDate` but is private to avoid coupling to
  /// the contract-suite helper's default-`hour` overload.
  private func utcDate(year: Int, month: Int, day: Int, hour: Int) throws -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    return try #require(
      calendar.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour)))
  }

  @Test("UTC noon on monthEnd day buckets into the same month")
  func utcNoonOnMonthEndStaysInMonth() throws {
    let date = try utcDate(year: 2025, month: 3, day: 25, hour: 12)
    let month = GRDBAnalysisRepository.financialMonth(for: date, monthEnd: 25)
    #expect(month == "202503")
  }

  @Test("UTC midnight on day after monthEnd spills into next month")
  func utcMidnightAfterMonthEndSpills() throws {
    let date = try utcDate(year: 2025, month: 3, day: 26, hour: 0)
    let month = GRDBAnalysisRepository.financialMonth(for: date, monthEnd: 25)
    #expect(month == "202504")
  }

  @Test("UTC late-evening on day before monthEnd stays in current month")
  func utcLateEveningStaysInCurrentMonth() throws {
    // 23:00 UTC on day 24 is local-time day 25 in UTC+1, but the UTC
    // calendar day is 24 — must bucket into March under monthEnd=25.
    // The previous `Calendar.current`-based implementation in UTC+1
    // would read local day 25 and still bucket into March; in UTC+2 it
    // would read local day 25 and bucket into March as well. The
    // off-by-one regression surfaces in UTC-N zones (negative offset)
    // where the local day reads as 24 when the UTC midnight is being
    // walked, mis-classifying a UTC March 25 row as March 24. This
    // direct test pins the UTC behaviour without needing a particular
    // CI timezone.
    let date = try utcDate(year: 2025, month: 3, day: 24, hour: 23)
    let month = GRDBAnalysisRepository.financialMonth(for: date, monthEnd: 25)
    #expect(month == "202503")
  }

  @Test("December monthEnd rollover lands in next year")
  func decemberRolloverWrapsToNextYear() throws {
    let date = try utcDate(year: 2025, month: 12, day: 26, hour: 0)
    let month = GRDBAnalysisRepository.financialMonth(for: date, monthEnd: 25)
    #expect(month == "202601")
  }

  @Test("monthEnd=31 keeps every UTC day in its own calendar month")
  func monthEnd31KeepsAllDaysInMonth() throws {
    let lastDay = try utcDate(year: 2025, month: 7, day: 31, hour: 23)
    let firstDay = try utcDate(year: 2025, month: 7, day: 1, hour: 0)
    #expect(GRDBAnalysisRepository.financialMonth(for: lastDay, monthEnd: 31) == "202507")
    #expect(GRDBAnalysisRepository.financialMonth(for: firstDay, monthEnd: 31) == "202507")
  }
}
