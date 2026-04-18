import Foundation

extension Date {
  /// Sendable format style that produces date-only strings like "2025-06-15".
  ///
  /// Used in place of a shared `ISO8601DateFormatter` singleton: `ISO8601DateFormatter`
  /// is not `Sendable`, so sharing a static instance across concurrency domains requires
  /// `nonisolated(unsafe)`, which is disallowed in production code (see
  /// `guides/CONCURRENCY_GUIDE.md`). `Date.ISO8601FormatStyle` is `Sendable` and
  /// produces the same output as `ISO8601DateFormatter` with `[.withFullDate]`.
  static let iso8601DateOnly: ISO8601FormatStyle = .iso8601.year().month().day()

  /// Formats the date as an ISO-8601 date-only string like "2025-06-15".
  var iso8601DateOnlyString: String {
    formatted(Date.iso8601DateOnly)
  }
}
