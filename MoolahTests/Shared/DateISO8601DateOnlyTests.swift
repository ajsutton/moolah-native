import Foundation
import Testing

@testable import Moolah

/// Tests for the `Date.iso8601DateOnly` format style extension.
///
/// The shared formatter previously used `nonisolated(unsafe)` on a non-`Sendable`
/// `ISO8601DateFormatter`. It has been replaced with a `Sendable`
/// `Date.ISO8601FormatStyle`. These tests verify the output matches what
/// `ISO8601DateFormatter` with `[.withFullDate]` produces.
@Suite("Date -- ISO8601 Date-Only")
struct DateISO8601DateOnlyTests {

  @Test
  func producesFullDateString() {
    var components = DateComponents()
    components.year = 2025
    components.month = 6
    components.day = 15
    components.hour = 14
    components.minute = 30
    components.timeZone = TimeZone(identifier: "UTC")
    let date = Calendar(identifier: .gregorian).date(from: components)!

    #expect(date.iso8601DateOnlyString == "2025-06-15")
  }

  @Test
  func matchesISO8601DateFormatterWithFullDateOption() {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]

    let dates = [
      Date(timeIntervalSince1970: 0),  // 1970-01-01
      Date(timeIntervalSince1970: 1_700_000_000),  // 2023-11-14
      Date(),
    ]

    for date in dates {
      #expect(date.iso8601DateOnlyString == formatter.string(from: date))
    }
  }

  @Test
  func padsSingleDigitMonthAndDay() {
    var components = DateComponents()
    components.year = 2026
    components.month = 1
    components.day = 3
    components.timeZone = TimeZone(identifier: "UTC")
    let date = Calendar(identifier: .gregorian).date(from: components)!

    #expect(date.iso8601DateOnlyString == "2026-01-03")
  }

  @Test
  func formatStyleIsReusableAcrossConcurrencyDomains() async {
    // Compiles only because `Date.ISO8601FormatStyle` is `Sendable` — the whole
    // point of the refactor. Call it from a detached task to exercise that.
    let style = Date.iso8601DateOnly
    let result = await Task.detached { () -> String in
      Date(timeIntervalSince1970: 1_700_000_000).formatted(style)
    }.value
    #expect(result == "2023-11-14")
  }
}
