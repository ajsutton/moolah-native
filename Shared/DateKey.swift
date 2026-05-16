import Foundation

/// Compact comparable date key: a `yyyymmdd` `Int32` (e.g. `2024-01-15`
/// → `20240115`). Integer ordering equals chronological ordering, so a
/// binary search over `Int32` keys is correct. Used by the price/rate
/// caches instead of `"YYYY-MM-DD"` `String` keys: ~12 bytes smaller per
/// entry and integer-fast comparisons.
///
/// Conversion goes through the existing ISO `"YYYY-MM-DD"` string the
/// services already compute (`ISO8601DateFormatter` `.withFullDate`,
/// UTC), so day bucketing is identical to the previous behaviour — no
/// timezone/calendar re-derivation.
enum DateKey {
  /// Parses `"YYYY-MM-DD"` into `yyyymmdd`. Returns `nil` for any string
  /// that is not exactly three `-`-separated integer fields with a
  /// 1...12 month and 1...31 day.
  static func from(isoString: String) -> Int32? {
    let parts = isoString.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
      let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
      year > 0, (1...12).contains(month), (1...31).contains(day)
    else { return nil }
    return Int32(year * 10_000 + month * 100 + day)
  }

  /// Formats `yyyymmdd` back into a zero-padded `"YYYY-MM-DD"` string.
  static func isoString(_ key: Int32) -> String {
    let v = Int(key)
    let year = v / 10_000
    let month = (v / 100) % 100
    let day = v % 100
    return String(format: "%04d-%02d-%02d", year, month, day)
  }
}
