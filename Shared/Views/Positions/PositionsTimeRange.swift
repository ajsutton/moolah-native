import Foundation

/// The six time-range options the chart picker offers, scoped to
/// `PositionsView`. Distinct from `Domain/Models/TimePeriod.swift` (which
/// covers a wider grid for reporting) so we don't over-fit the global type
/// to one screen's needs.
enum PositionsTimeRange: Hashable, Sendable, CaseIterable, Identifiable {
  case oneMonth
  case threeMonths
  case sixMonths
  case ytd
  case oneYear
  case all

  static var allCases: [PositionsTimeRange] {
    [.oneMonth, .threeMonths, .sixMonths, .ytd, .oneYear, .all]
  }

  var id: String { label }

  var label: String {
    switch self {
    case .oneMonth: return "1M"
    case .threeMonths: return "3M"
    case .sixMonths: return "6M"
    case .ytd: return "YTD"
    case .oneYear: return "1Y"
    case .all: return "All"
    }
  }

  /// First date inside the range, given a `now` reference. `nil` for `.all`
  /// (caller treats as "from the earliest available data point").
  func cutoff(from now: Date) -> Date? {
    let calendar = Calendar(identifier: .gregorian)
    switch self {
    case .oneMonth: return calendar.date(byAdding: .month, value: -1, to: now)
    case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: now)
    case .sixMonths: return calendar.date(byAdding: .month, value: -6, to: now)
    case .ytd:
      let comps = calendar.dateComponents([.year], from: now)
      return calendar.date(from: comps)
    case .oneYear: return calendar.date(byAdding: .year, value: -1, to: now)
    case .all: return nil
    }
  }
}
