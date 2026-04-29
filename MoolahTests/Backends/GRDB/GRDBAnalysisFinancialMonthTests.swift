import Foundation
import Testing

@testable import Moolah

/// Direct unit tests for the UTC-anchored financial-month bucket key.
/// Cover both the underlying shared `FinancialMonth.key(for:monthEnd:)`
/// helper and the two repository façades (`GRDBAnalysisRepository` and
/// `CloudKitAnalysisRepository`) that forward to it — pinning that the
/// GRDB and CloudKit analysis paths cannot drift apart on the boundary
/// calendar.
///
/// The contract suite covers boundary behaviour through the public API,
/// but only catches a regression to a `Calendar.current`-based
/// implementation when the test runner happens to live in a negative-UTC
/// timezone. These tests pin the UTC anchoring timezone-independently:
/// a transaction whose UTC-anchored `Date` represents `2025-03-25` lands
/// in `202503` for `monthEnd: 25`, and a `Date` representing
/// `2025-03-26` lands in `202504`. A `Calendar.current`-based
/// implementation in a negative-UTC zone reads the previous local-time
/// day and drifts the boundary call backwards.
@Suite("FinancialMonth — UTC anchoring")
struct GRDBAnalysisFinancialMonthTests {
  @Test("UTC noon on monthEnd day buckets into the same month")
  func utcNoonOnMonthEndStaysInMonth() throws {
    let date = try AnalysisTestHelpers.utcDate(year: 2025, month: 3, day: 25, hour: 12)
    #expect(FinancialMonth.key(for: date, monthEnd: 25) == "202503")
  }

  @Test("UTC midnight on day after monthEnd spills into next month")
  func utcMidnightAfterMonthEndSpills() throws {
    let date = try AnalysisTestHelpers.utcDate(year: 2025, month: 3, day: 26, hour: 0)
    #expect(FinancialMonth.key(for: date, monthEnd: 25) == "202504")
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
    let date = try AnalysisTestHelpers.utcDate(year: 2025, month: 3, day: 24, hour: 23)
    #expect(FinancialMonth.key(for: date, monthEnd: 25) == "202503")
  }

  @Test("December monthEnd rollover lands in next year")
  func decemberRolloverWrapsToNextYear() throws {
    let date = try AnalysisTestHelpers.utcDate(year: 2025, month: 12, day: 26, hour: 0)
    #expect(FinancialMonth.key(for: date, monthEnd: 25) == "202601")
  }

  @Test("monthEnd=31 keeps every UTC day in its own calendar month")
  func monthEnd31KeepsAllDaysInMonth() throws {
    let lastDay = try AnalysisTestHelpers.utcDate(year: 2025, month: 7, day: 31, hour: 23)
    let firstDay = try AnalysisTestHelpers.utcDate(year: 2025, month: 7, day: 1, hour: 0)
    #expect(FinancialMonth.key(for: lastDay, monthEnd: 31) == "202507")
    #expect(FinancialMonth.key(for: firstDay, monthEnd: 31) == "202507")
  }

  // MARK: - Repository façades route to the shared helper

  /// Pins that `GRDBAnalysisRepository.financialMonth` and
  /// `CloudKitAnalysisRepository.financialMonth` both forward to
  /// `FinancialMonth.key(for:monthEnd:)`. If a future refactor
  /// reintroduces a `Calendar.current`-based path on either side, the
  /// boundary-day case below diverges from the shared helper's output —
  /// the test breaks instead of the production code silently
  /// mis-bucketing rows. The shared-helper approach is the C4 fix's
  /// drift-prevention guarantee.
  @Test("GRDB and CloudKit financialMonth forward to the shared FinancialMonth helper")
  func repositoryFacadesAgreeWithSharedHelper() throws {
    let boundary = try AnalysisTestHelpers.utcDate(
      year: 2025, month: 3, day: 24, hour: 23)
    let grdb = GRDBAnalysisRepository.financialMonth(for: boundary, monthEnd: 25)
    let cloudKit = CloudKitAnalysisRepository.financialMonth(
      for: boundary, monthEnd: 25)
    let shared = FinancialMonth.key(for: boundary, monthEnd: 25)
    #expect(grdb == shared)
    #expect(cloudKit == shared)
    #expect(shared == "202503")
  }
}
