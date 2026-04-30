import Foundation

/// Field-level parsing helpers shared by `SelfWealthMovementsParser` and
/// `SelfWealthCashReportParser`. SelfWealth's two reports use the same date
/// shape (`yyyy-MM-dd HH:mm:ss`) and the same numeric conventions (`$` and
/// `,` may appear inside numbers), so the helpers live here rather than as
/// private duplicates on each parser.
///
/// Kept separate from `GenericBankCSVParser`'s helpers because the latter
/// strips a wider set of currency symbols (`£`, `€`) that don't appear in
/// SelfWealth exports — keeping the SelfWealth path on a tighter helper set
/// avoids accidentally accepting upstream junk that isn't actually valid
/// SelfWealth output.
enum SelfWealthCSVParsing {

  /// Out-of-range reads return an empty string so callers can do uniform
  /// "trim then check empty" handling. Optional columns that aren't present
  /// in a particular file pass `-1` here, which also coerces to "".
  static func safe(_ row: [String], _ index: Int) -> String {
    index >= 0 && index < row.count ? row[index] : ""
  }

  static func parseDecimal(_ field: String) -> Decimal? {
    var value = field.trimmingCharacters(in: .whitespaces)
    if value.isEmpty { return nil }
    value = value.replacingOccurrences(of: "$", with: "")
    value = value.replacingOccurrences(of: ",", with: "")
    return Decimal(string: value)
  }

  static func parseDate(_ field: String) -> Date? {
    let trimmed = field.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }
    return dateFormatter.date(from: trimmed)
  }

  /// `DateFormatter` is documented thread-safe for date parsing. SelfWealth
  /// exports use a single fixed format, so we cache one formatter rather
  /// than allocating per row.
  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
  }()
}
