import Foundation

enum RecurPeriod: String, Codable, Sendable, CaseIterable {
  case once = "ONCE"
  case day = "DAY"
  case week = "WEEK"
  case month = "MONTH"
  case year = "YEAR"

  var displayName: String {
    switch self {
    case .once: return "Once"
    case .day: return "Day"
    case .week: return "Week"
    case .month: return "Month"
    case .year: return "Year"
    }
  }

  var pluralDisplayName: String {
    switch self {
    case .once: return "Once"
    case .day: return "Days"
    case .week: return "Weeks"
    case .month: return "Months"
    case .year: return "Years"
    }
  }
}

extension RecurPeriod {
  /// Human-readable recurrence description, e.g. "Every month" or "Every 2 weeks".
  func recurrenceDescription(every: Int) -> String {
    guard self != .once else { return "" }
    let periodName = every == 1 ? displayName.lowercased() : pluralDisplayName.lowercased()
    return every == 1 ? "Every \(periodName)" : "Every \(every) \(periodName)"
  }
}
