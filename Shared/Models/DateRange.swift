// swiftlint:disable multiline_arguments

import Foundation

/// Predefined date ranges for reports and analysis filtering.
enum DateRange: String, CaseIterable, Identifiable, Sendable {
  case thisFinancialYear = "This Financial Year"
  case lastFinancialYear = "Last Financial Year"
  case lastMonth = "Last month"
  case last3Months = "Last 3 months"
  case last6Months = "Last 6 months"
  case last9Months = "Last 9 months"
  case last12Months = "Last 12 months"
  case monthToDate = "Month to date"
  case quarterToDate = "Quarter to date"
  case yearToDate = "Year to date"
  case custom = "Custom"

  var id: String { rawValue }

  var displayName: String { rawValue }

  func startDate(financialYearStartMonth: Int = 7) -> Date {
    startDate(
      today: Calendar.current.startOfDay(for: Date()),
      financialYearStartMonth: financialYearStartMonth)
  }

  func startDate(today: Date, financialYearStartMonth: Int = 7) -> Date {
    let calendar = Calendar.current

    // Fixed-rolling-window cases share one `date(byAdding:)` call shape, so
    // collapsing them to a single branch keeps the remaining `switch` below
    // the cyclomatic-complexity threshold.
    if let monthsAgo = rollingWindowMonthsAgo {
      guard let date = calendar.date(byAdding: .month, value: -monthsAgo, to: today) else {
        return today
      }
      return date
    }

    switch self {
    case .thisFinancialYear:
      return financialYear(for: today, startMonth: financialYearStartMonth).start
    case .lastFinancialYear:
      let lastYear = calendar.date(byAdding: .year, value: -1, to: today)!
      return financialYear(for: lastYear, startMonth: financialYearStartMonth).start
    case .monthToDate:
      return calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
    case .quarterToDate:
      let month = calendar.component(.month, from: today)
      let quarterStart = ((month - 1) / 3) * 3 + 1
      return calendar.date(
        from: DateComponents(
          year: calendar.component(.year, from: today),
          month: quarterStart,
          day: 1
        ))!
    case .yearToDate:
      return calendar.date(from: calendar.dateComponents([.year], from: today))!
    case .custom:
      // Default for custom: 1 year ago
      return calendar.date(byAdding: .year, value: -1, to: today)!
    default:
      // Handled by the `rollingWindowMonthsAgo` early-return above; the
      // compiler can't prove exhaustiveness once that branch is lifted out.
      return today
    }
  }

  /// Offset in months for the fixed-window rolling cases (`lastMonth`,
  /// `last3Months`, etc.); `nil` for everything else.
  private var rollingWindowMonthsAgo: Int? {
    switch self {
    case .lastMonth: return 1
    case .last3Months: return 3
    case .last6Months: return 6
    case .last9Months: return 9
    case .last12Months: return 12
    default: return nil
    }
  }

  func endDate(financialYearStartMonth: Int = 7) -> Date {
    endDate(
      today: Calendar.current.startOfDay(for: Date()),
      financialYearStartMonth: financialYearStartMonth)
  }

  func endDate(today: Date, financialYearStartMonth: Int = 7) -> Date {
    let calendar = Calendar.current

    switch self {
    case .thisFinancialYear:
      return financialYear(for: today, startMonth: financialYearStartMonth).end
    case .lastFinancialYear:
      let lastYear = calendar.date(byAdding: .year, value: -1, to: today)!
      return financialYear(for: lastYear, startMonth: financialYearStartMonth).end
    default:
      return today
    }
  }

  /// Calculates the financial year boundaries for a given date.
  /// Financial year runs from the given start month (e.g. 7 for July 1 → June 30).
  private func financialYear(for date: Date, startMonth: Int) -> (start: Date, end: Date) {
    let calendar = Calendar.current
    let year = calendar.component(.year, from: date)
    let month = calendar.component(.month, from: date)

    let fyYear = month >= startMonth ? year : year - 1
    let endMonth = startMonth == 1 ? 12 : startMonth - 1
    let endYear = startMonth == 1 ? fyYear : fyYear + 1

    let start = calendar.date(from: DateComponents(year: fyYear, month: startMonth, day: 1))!
    let lastDayOfEndMonth =
      calendar.range(
        of: .day, in: .month,
        for: calendar.date(from: DateComponents(year: endYear, month: endMonth, day: 1))!
      )!.upperBound - 1
    let end = calendar.date(
      from: DateComponents(year: endYear, month: endMonth, day: lastDayOfEndMonth))!

    return (start, end)
  }
}
