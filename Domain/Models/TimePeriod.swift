import Foundation

/// Time period selection for investment charts.
enum TimePeriod: Hashable, Sendable, CaseIterable, Identifiable {
  case months(Int)
  case all

  var id: String { label }

  var label: String {
    switch self {
    case .months(1): return "1M"
    case .months(3): return "3M"
    case .months(6): return "6M"
    case .months(9): return "9M"
    case .months(12): return "1Y"
    case .months(24): return "2Y"
    case .months(36): return "3Y"
    case .months(48): return "4Y"
    case .months(60): return "5Y"
    case .months(let n): return "\(n)M"
    case .all: return "All"
    }
  }

  /// The cutoff date for this period (nil for .all).
  var startDate: Date? {
    switch self {
    case .months(let n):
      return Calendar.current.date(byAdding: .month, value: -n, to: Date())
    case .all:
      return nil
    }
  }

  static var allCases: [TimePeriod] {
    [
      .months(1), .months(3), .months(6), .months(9),
      .months(12), .months(24), .months(36), .months(48), .months(60),
      .all,
    ]
  }
}
