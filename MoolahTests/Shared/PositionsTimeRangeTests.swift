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

    let cutoffComponents = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: cutoff)
    #expect(cutoffComponents.year == 2026)
    #expect(cutoffComponents.month == 1)
    #expect(cutoffComponents.day == 1)
    #expect(cutoffComponents.hour == 0)
    #expect(cutoffComponents.minute == 0)
    #expect(cutoffComponents.second == 0)
  }

  @Test(
    "month-based ranges subtract the correct amount",
    arguments: [
      (PositionsTimeRange.oneMonth, -1, Calendar.Component.month),
      (PositionsTimeRange.threeMonths, -3, Calendar.Component.month),
      (PositionsTimeRange.sixMonths, -6, Calendar.Component.month),
      (PositionsTimeRange.oneYear, -1, Calendar.Component.year),
    ]
  )
  func monthRangeCutoff(range: PositionsTimeRange, value: Int, component: Calendar.Component) {
    let now = Date(timeIntervalSince1970: 1_775_000_000)  // 2026-04-29 UTC
    let calendar = Calendar(identifier: .gregorian)
    let cutoff = range.cutoff(from: now)!
    let expected = calendar.date(byAdding: component, value: value, to: now)!
    #expect(abs(cutoff.timeIntervalSince(expected)) < 1)
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
