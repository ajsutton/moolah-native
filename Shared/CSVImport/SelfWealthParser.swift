import Foundation

/// Parser for SelfWealth trade-history CSV exports.
///
/// Trade rows become two-leg transactions: one cash leg (AUD, expense for BUY
/// / income for SELL) plus one position leg on the stock instrument
/// (`ASX:TICKER`, quantity with BUY → income / SELL → expense). Dividends,
/// brokerage, GST, cash in/out, and interest each become single-leg AUD
/// transactions. Unknown `Type` values emit `.skip(reason:)` rather than
/// throwing — SelfWealth occasionally emits informational rows and the file
/// should still parse.
///
/// Task 15 (`ImportStore`) re-routes the placeholder instruments to the
/// account's own `Instrument` where relevant.
struct SelfWealthParser: CSVParser, Sendable {

  let identifier = "selfwealth"

  private static let requiredHeaders: Set<String> = [
    "date", "type", "description", "debit", "credit", "balance",
  ]

  func recognizes(headers: [String]) -> Bool {
    let normalised = Set(headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    return Self.requiredHeaders.isSubset(of: normalised)
  }

  func parse(rows: [[String]]) throws -> [ParsedRecord] {
    guard let headers = rows.first else { throw CSVParserError.emptyFile }
    guard recognizes(headers: headers) else { throw CSVParserError.headerMismatch }
    let columns = columnIndex(headers)

    var results: [ParsedRecord] = []
    for (offset, row) in rows.dropFirst().enumerated() {
      let rowIndex = offset + 1
      if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
        results.append(.skip(reason: "blank row"))
        continue
      }
      let type = safe(row, columns.type)
      let description = safe(row, columns.description)
      guard let date = parseDate(safe(row, columns.date)) else {
        throw CSVParserError.malformedRow(index: rowIndex, reason: "invalid date")
      }
      let debitValue = parseAmount(safe(row, columns.debit)) ?? 0
      let creditValue = parseAmount(safe(row, columns.credit)) ?? 0
      let balance = parseAmount(safe(row, columns.balance))
      let cashAmount: Decimal = creditValue != 0 ? creditValue : -abs(debitValue)

      switch type.lowercased() {
      case "trade":
        let record = try parseTrade(
          date: date,
          description: description,
          cashAmount: cashAmount,
          balance: balance,
          row: row,
          index: rowIndex)
        results.append(record)
      case "dividend":
        let leg = ParsedLeg(
          accountId: nil,
          instrument: .AUD,
          quantity: cashAmount,
          type: .income)
        results.append(
          .transaction(
            ParsedTransaction(
              date: date,
              legs: [leg],
              rawRow: row,
              rawDescription: description,
              rawAmount: cashAmount,
              rawBalance: balance,
              bankReference: dividendReference(for: description))))
      case "brokerage", "gst on brokerage", "fee":
        let leg = ParsedLeg(
          accountId: nil,
          instrument: .AUD,
          quantity: cashAmount,
          type: .expense)
        results.append(
          .transaction(
            ParsedTransaction(
              date: date,
              legs: [leg],
              rawRow: row,
              rawDescription: description,
              rawAmount: cashAmount,
              rawBalance: balance,
              bankReference: nil)))
      case "cash in", "cash out", "interest":
        let leg = ParsedLeg(
          accountId: nil,
          instrument: .AUD,
          quantity: cashAmount,
          type: cashAmount >= 0 ? .income : .expense)
        results.append(
          .transaction(
            ParsedTransaction(
              date: date,
              legs: [leg],
              rawRow: row,
              rawDescription: description,
              rawAmount: cashAmount,
              rawBalance: balance,
              bankReference: nil)))
      default:
        results.append(.skip(reason: "unknown type: \(type)"))
      }
    }
    return results
  }

  // MARK: - Private

  private struct Columns {
    let date: Int
    let type: Int
    let description: Int
    let debit: Int
    let credit: Int
    let balance: Int
  }

  private func columnIndex(_ headers: [String]) -> Columns {
    let normalised = headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    return Columns(
      date: normalised.firstIndex(of: "date") ?? -1,
      type: normalised.firstIndex(of: "type") ?? -1,
      description: normalised.firstIndex(of: "description") ?? -1,
      debit: normalised.firstIndex(of: "debit") ?? -1,
      credit: normalised.firstIndex(of: "credit") ?? -1,
      balance: normalised.firstIndex(of: "balance") ?? -1)
  }

  private func safe(_ row: [String], _ index: Int) -> String {
    index >= 0 && index < row.count ? row[index] : ""
  }

  private func parseAmount(_ field: String) -> Decimal? {
    var value = field.trimmingCharacters(in: .whitespaces)
    if value.isEmpty { return nil }
    value = value.replacingOccurrences(of: "$", with: "")
    value = value.replacingOccurrences(of: ",", with: "")
    return Decimal(string: value)
  }

  private func parseDate(_ field: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "dd/MM/yyyy"
    return formatter.date(from: field.trimmingCharacters(in: .whitespaces))
  }

  private static let tradeRegex: NSRegularExpression = {
    // swiftlint:disable:next force_try — regex literal always compiles
    try! NSRegularExpression(
      pattern: #"(BUY|SELL)\s+(\d+)\s+([A-Z0-9.]+)\s+@\s+\$?([\d.]+)"#,
      options: [])
  }()

  private func parseTrade(
    date: Date,
    description: String,
    cashAmount: Decimal,
    balance: Decimal?,
    row: [String],
    index: Int
  ) throws -> ParsedRecord {
    let range = NSRange(description.startIndex..., in: description)
    guard
      let match = Self.tradeRegex.firstMatch(in: description, options: [], range: range)
    else {
      throw CSVParserError.malformedRow(
        index: index, reason: "unrecognised trade description: \(description)")
    }
    let ns = description as NSString
    let kind = ns.substring(with: match.range(at: 1))
    let quantityText = ns.substring(with: match.range(at: 2))
    let ticker = ns.substring(with: match.range(at: 3))
    guard let quantity = Decimal(string: quantityText) else {
      throw CSVParserError.malformedRow(
        index: index, reason: "invalid trade quantity: \(quantityText)")
    }
    let stockInstrument = Instrument(
      id: "ASX:\(ticker)",
      kind: .stock,
      name: ticker,
      decimals: 0,
      ticker: ticker,
      exchange: "ASX",
      chainId: nil,
      contractAddress: nil)
    let cashLeg = ParsedLeg(
      accountId: nil,
      instrument: .AUD,
      quantity: cashAmount,
      type: kind == "BUY" ? .expense : .income)
    let positionLeg = ParsedLeg(
      accountId: nil,
      instrument: stockInstrument,
      quantity: kind == "BUY" ? quantity : -quantity,
      type: kind == "BUY" ? .income : .expense)
    return .transaction(
      ParsedTransaction(
        date: date,
        legs: [cashLeg, positionLeg],
        rawRow: row,
        rawDescription: description,
        rawAmount: cashAmount,
        rawBalance: balance,
        bankReference: nil))
  }

  /// "DIVIDEND - BHP GROUP LIMITED" → "SW-DIV-BHP". Used as a bankReference so
  /// identical dividend payments on the same day/amount still dedupe cleanly.
  private func dividendReference(for description: String) -> String? {
    guard let dashRange = description.range(of: "-") else { return nil }
    let remainder = description[dashRange.upperBound...]
      .trimmingCharacters(in: .whitespaces)
    guard let firstToken = remainder.split(separator: " ").first else { return nil }
    return "SW-DIV-\(firstToken)"
  }
}
