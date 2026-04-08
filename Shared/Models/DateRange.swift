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

  var startDate: Date {
    let today = Date()
    let calendar = Calendar.current

    switch self {
    case .thisFinancialYear:
      return financialYear(for: today).start
    case .lastFinancialYear:
      let lastYear = calendar.date(byAdding: .year, value: -1, to: today)!
      return financialYear(for: lastYear).start
    case .lastMonth:
      return calendar.date(byAdding: .month, value: -1, to: today)!
    case .last3Months:
      return calendar.date(byAdding: .month, value: -3, to: today)!
    case .last6Months:
      return calendar.date(byAdding: .month, value: -6, to: today)!
    case .last9Months:
      return calendar.date(byAdding: .month, value: -9, to: today)!
    case .last12Months:
      return calendar.date(byAdding: .month, value: -12, to: today)!
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
    }
  }

  var endDate: Date {
    let today = Date()
    let calendar = Calendar.current

    switch self {
    case .thisFinancialYear:
      return financialYear(for: today).end
    case .lastFinancialYear:
      let lastYear = calendar.date(byAdding: .year, value: -1, to: today)!
      return financialYear(for: lastYear).end
    default:
      return today
    }
  }

  /// Calculates the financial year boundaries for a given date.
  /// Financial year runs from July 1 to June 30.
  private func financialYear(for date: Date) -> (start: Date, end: Date) {
    let calendar = Calendar.current
    let year = calendar.component(.year, from: date)
    let month = calendar.component(.month, from: date)

    // Financial year: July 1 → June 30
    let fyYear = month >= 7 ? year : year - 1
    let start = calendar.date(from: DateComponents(year: fyYear, month: 7, day: 1))!
    let end = calendar.date(from: DateComponents(year: fyYear + 1, month: 6, day: 30))!

    return (start, end)
  }
}
