import Foundation

extension Date {
  /// Returns true if this date falls on the same calendar day as `other`,
  /// ignoring time components.
  func isSameDay(as other: Date) -> Bool {
    Calendar.current.isDate(self, inSameDayAs: other)
  }
}
