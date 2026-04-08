import Foundation

/// Centralized date formatting for backend API communication.
/// The moolah-server uses "yyyy-MM-dd" format consistently for all date fields.
enum BackendDateFormatter {
  /// Shared date formatter for backend API dates.
  /// Format: yyyy-MM-dd (e.g., "2026-04-09")
  /// Timezone: UTC
  static let shared: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.calendar = Calendar(identifier: .gregorian)
    return formatter
  }()

  /// Converts a Date to backend API format string.
  static func string(from date: Date) -> String {
    shared.string(from: date)
  }

  /// Parses a backend API format string to Date.
  /// Returns nil if the string is not in the expected format.
  static func date(from string: String) -> Date? {
    shared.date(from: string)
  }
}
