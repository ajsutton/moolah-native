import Foundation
import Testing

@testable import Moolah

/// Tests for DateRange enum calculations.
@Suite("DateRange Tests")
struct DateRangeTests {

  @Test("Last 12 months returns date 12 months ago")
  func last12MonthsCalculation() throws {
    let range = DateRange.last12Months
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let expected = calendar.date(byAdding: .month, value: -12, to: today)!

    #expect(range.startDate == expected)
    #expect(range.endDate == today)
  }

  @Test("Month to date returns first day of current month")
  func monthToDateCalculation() throws {
    let range = DateRange.monthToDate
    let calendar = Calendar.current
    let today = Date()
    let month = calendar.component(.month, from: today)
    let year = calendar.component(.year, from: today)

    let startMonth = calendar.component(.month, from: range.startDate)
    let startYear = calendar.component(.year, from: range.startDate)
    let startDay = calendar.component(.day, from: range.startDate)

    #expect(startYear == year)
    #expect(startMonth == month)
    #expect(startDay == 1)
  }

  @Test("Quarter to date returns first day of current quarter")
  func quarterToDateCalculation() throws {
    let range = DateRange.quarterToDate
    let calendar = Calendar.current
    let today = Date()
    let currentMonth = calendar.component(.month, from: today)

    // Calculate expected quarter start month (Q1: Jan, Q2: Apr, Q3: Jul, Q4: Oct)
    let expectedQuarterStart = ((currentMonth - 1) / 3) * 3 + 1

    let startMonth = calendar.component(.month, from: range.startDate)
    let startDay = calendar.component(.day, from: range.startDate)

    #expect(startMonth == expectedQuarterStart)
    #expect(startDay == 1)
  }

  @Test("Year to date returns first day of current year")
  func yearToDateCalculation() throws {
    let range = DateRange.yearToDate
    let calendar = Calendar.current
    let today = Date()
    let year = calendar.component(.year, from: today)

    let startYear = calendar.component(.year, from: range.startDate)
    let startMonth = calendar.component(.month, from: range.startDate)
    let startDay = calendar.component(.day, from: range.startDate)

    #expect(startYear == year)
    #expect(startMonth == 1)
    #expect(startDay == 1)
  }

  @Test("This financial year calculates July 1 to June 30")
  func thisFinancialYearCalculation() throws {
    let range = DateRange.thisFinancialYear
    let calendar = Calendar.current
    let today = Date()
    let currentYear = calendar.component(.year, from: today)
    let currentMonth = calendar.component(.month, from: today)

    // FY year is current year if we're past July, otherwise last year
    let expectedFYYear = currentMonth >= 7 ? currentYear : currentYear - 1

    let startYear = calendar.component(.year, from: range.startDate)
    let startMonth = calendar.component(.month, from: range.startDate)
    let startDay = calendar.component(.day, from: range.startDate)

    let endYear = calendar.component(.year, from: range.endDate)
    let endMonth = calendar.component(.month, from: range.endDate)
    let endDay = calendar.component(.day, from: range.endDate)

    #expect(startYear == expectedFYYear)
    #expect(startMonth == 7)
    #expect(startDay == 1)

    #expect(endYear == expectedFYYear + 1)
    #expect(endMonth == 6)
    #expect(endDay == 30)
  }

  @Test("Last financial year is one year before this financial year")
  func lastFinancialYearCalculation() throws {
    let thisRange = DateRange.thisFinancialYear
    let lastRange = DateRange.lastFinancialYear
    let calendar = Calendar.current

    let thisYear = calendar.component(.year, from: thisRange.startDate)
    let lastYear = calendar.component(.year, from: lastRange.startDate)

    #expect(lastYear == thisYear - 1)

    // Verify it's still July 1 to June 30
    let startMonth = calendar.component(.month, from: lastRange.startDate)
    let startDay = calendar.component(.day, from: lastRange.startDate)
    let endMonth = calendar.component(.month, from: lastRange.endDate)
    let endDay = calendar.component(.day, from: lastRange.endDate)

    #expect(startMonth == 7)
    #expect(startDay == 1)
    #expect(endMonth == 6)
    #expect(endDay == 30)
  }

  @Test("Last N months calculations")
  func lastNMonthsCalculations() throws {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())

    let testCases: [(DateRange, Int)] = [
      (.lastMonth, -1),
      (.last3Months, -3),
      (.last6Months, -6),
      (.last9Months, -9),
      (.last12Months, -12),
    ]

    for (range, months) in testCases {
      let expected = calendar.date(byAdding: .month, value: months, to: today)!
      #expect(range.startDate == expected, "Failed for \(range.displayName)")
    }
  }

  @Test("Custom range has sensible defaults")
  func customRangeDefaults() throws {
    let range = DateRange.custom
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())

    // Custom defaults to 1 year ago → today
    let expectedStart = calendar.date(byAdding: .year, value: -1, to: today)!
    #expect(range.startDate == expectedStart)
    #expect(range.endDate == today)
  }

  @Test("All cases are iterable")
  func allCasesIterable() throws {
    let allCases = DateRange.allCases
    #expect(allCases.count == 11)
    #expect(allCases.contains(.thisFinancialYear))
    #expect(allCases.contains(.custom))
  }

  @Test("Display names match raw values")
  func displayNames() throws {
    for range in DateRange.allCases {
      #expect(range.displayName == range.rawValue)
    }
  }
}
