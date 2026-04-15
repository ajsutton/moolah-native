import Foundation

extension ISO8601DateFormatter {
  /// Formatter that produces date-only strings like "2025-06-15".
  nonisolated(unsafe) static let dateOnly: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f
  }()
}
