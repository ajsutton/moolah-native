import Foundation
import Testing

@testable import Moolah

@Suite("PositionsTimeRange")
struct PositionsTimeRangeTests {
  @Test("all has a nil cutoff (caller treats as: from earliest holding)")
  func allRangeUnbounded() {
    #expect(PositionsTimeRange.all.cutoff(from: Date()) == nil)
  }

  @Test("YTD cutoff is start-of-year for the given reference date")
  func ytdCutoff() {
    var components = DateComponents()
    components.year = 2026
    components.month = 4
    components.day = 20
    components.hour = 12
    let calendar = Calendar(identifier: .gregorian)
    let now = calendar.date(from: components)!
    let cutoff = PositionsTimeRange.ytd.cutoff(from: now)!

    let cutoffComponents = calendar.dateComponents([.year, .month, .day], from: cutoff)
    #expect(cutoffComponents.year == 2026)
    #expect(cutoffComponents.month == 1)
    #expect(cutoffComponents.day == 1)
  }

  @Test("month-based ranges subtract the right number of months")
  func monthRangeCutoff() {
    let now = Date(timeIntervalSince1970: 1_775_000_000)  // 2026-04-09 ish
    let calendar = Calendar(identifier: .gregorian)
    let oneMonth = PositionsTimeRange.oneMonth.cutoff(from: now)!
    let expected = calendar.date(byAdding: .month, value: -1, to: now)!
    #expect(abs(oneMonth.timeIntervalSince(expected)) < 1)
  }

  @Test("allCases includes all 6 picker entries in order")
  func allCasesOrder() {
    #expect(
      PositionsTimeRange.allCases == [
        .oneMonth, .threeMonths, .sixMonths, .ytd, .oneYear, .all,
      ]
    )
  }
}
