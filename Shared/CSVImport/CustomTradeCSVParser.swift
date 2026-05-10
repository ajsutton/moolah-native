// swiftlint:disable multiline_arguments

import Foundation

/// Parser for a custom trade CSV format.
///
/// Each row can represent a Deposit, Trade, or other transaction types.
/// The CSV uses Sell/Buy pairs to represent exchanges.
///
/// Typical Trade row:
/// Date,Sell,Sell Unit,Buy,Buy Unit,Fee (AUD),Avg. Cost,Broker,Type
/// 2021-01-21,"1,387.8",AUD,12,IAF,$\t5.50,$\t115.65,InvestSMART,Trade
///
/// This maps to:
/// - AUD Sell leg (negative)
/// - IAF Buy leg (positive)
/// - AUD Fee leg (negative)
struct CustomTradeCSVParser: CSVParser, Sendable {

  let identifier = "custom-trade-csv"

  private static let requiredHeaders: Set<String> = [
    "date", "sell", "sell unit", "buy", "buy unit", "fee (aud)", "avg. cost", "broker", "type",
  ]

  func recognizes(headers: [String]) -> Bool {
    let normalised = Set(headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    return Self.requiredHeaders.isSubset(of: normalised)
  }

  func parse(rows: [[String]]) throws -> [ParsedRecord] {
    guard let headers = rows.first else { throw CSVParserError.emptyFile }
    guard recognizes(headers: headers) else { throw CSVParserError.headerMismatch }
    let columns = try columnIndex(headers)

    var results: [ParsedRecord] = []
    for (offset, row) in rows.dropFirst().enumerated() {
      let rowIndex = offset + 1
      if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
        results.append(.skip(reason: "blank row"))
        continue
      }
      results.append(try parseDataRow(row, columns: columns, rowIndex: rowIndex))
    }
    return results
  }

  // MARK: - Private

  private struct Columns {
    let date: Int
    let sell: Int
    let sellUnit: Int
    let buy: Int
    let buyUnit: Int
    let fee: Int
    let type: Int
  }

  private func columnIndex(_ headers: [String]) throws -> Columns {
    let normalised = headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    func find(_ name: String) -> Int? { normalised.firstIndex(of: name) }
    guard let date = find("date"),
      let sell = find("sell"),
      let sellUnit = find("sell unit"),
      let buy = find("buy"),
      let buyUnit = find("buy unit"),
      let fee = find("fee (aud)"),
      let type = find("type")
    else {
      throw CSVParserError.headerMismatch
    }
    return Columns(
      date: date, sell: sell, sellUnit: sellUnit, buy: buy, buyUnit: buyUnit, fee: fee, type: type)
  }

  private func parseDataRow(
    _ row: [String], columns: Columns, rowIndex: Int
  ) throws -> ParsedRecord {
    let dateField = safe(row, columns.date).trimmingCharacters(in: .whitespaces)
    let type = safe(row, columns.type).trimmingCharacters(in: .whitespaces)

    guard let date = parseDate(dateField) else {
      throw CSVParserError.malformedRow(
        index: rowIndex, reason: "invalid date: \(dateField)", row: row)
    }

    let sellAmount = parseDecimal(safe(row, columns.sell)) ?? 0
    let sellUnit = safe(row, columns.sellUnit).trimmingCharacters(in: .whitespaces)
    let buyAmount = parseDecimal(safe(row, columns.buy)) ?? 0
    let buyUnit = safe(row, columns.buyUnit).trimmingCharacters(in: .whitespaces)
    let fee = parseDecimal(safe(row, columns.fee)) ?? 0

    var legs: [ParsedLeg] = []

    // Sell side
    if sellAmount != 0 {
      legs.append(
        ParsedLeg(
          accountId: nil,
          instrument: instrument(for: sellUnit),
          quantity: -sellAmount,
          type: .trade,
          isInstrumentPlaceholder: sellUnit == "AUD"
        ))
    }

    // Buy side
    if buyAmount != 0 {
      legs.append(
        ParsedLeg(
          accountId: nil,
          instrument: instrument(for: buyUnit),
          quantity: buyAmount,
          type: .trade,
          isInstrumentPlaceholder: buyUnit == "AUD"
        ))
    }

    // Fee
    if fee != 0 {
      legs.append(
        ParsedLeg(
          accountId: nil,
          instrument: .AUD,
          quantity: -fee,
          type: .expense,
          isInstrumentPlaceholder: true
        ))
    }

    if legs.isEmpty {
      return .skip(reason: "row has no amounts")
    }

    // Determine rawAmount for display/dedupe logic.
    // If it's a trade involving AUD, use the AUD magnitude as the "amount".
    let rawAmount: Decimal
    if buyUnit == "AUD" {
      rawAmount = buyAmount
    } else if sellUnit == "AUD" {
      rawAmount = -sellAmount
    } else {
      // Non-AUD trade (rare for this source), pick buy side.
      rawAmount = buyAmount != 0 ? buyAmount : -sellAmount
    }

    return .transaction(
      ParsedTransaction(
        date: date,
        legs: legs,
        rawRow: row,
        rawDescription: type,
        rawAmount: rawAmount,
        rawBalance: nil,
        bankReference: nil
      ))
  }

  private func instrument(for unit: String) -> Instrument {
    if unit == "AUD" {
      return .AUD
    }
    // Assume ASX-based for non-AUD units
    return Instrument.stock(ticker: "\(unit).AX", exchange: "ASX", name: unit)
  }

  private func safe(_ row: [String], _ index: Int) -> String {
    index >= 0 && index < row.count ? row[index] : ""
  }

  private func parseDecimal(_ field: String) -> Decimal? {
    var value = field.trimmingCharacters(in: .whitespaces)
    if value.isEmpty { return nil }
    value = value.replacingOccurrences(of: "$", with: "")
    value = value.replacingOccurrences(of: ",", with: "")
    value = value.trimmingCharacters(in: .whitespaces)
    return Decimal(string: value)
  }

  private func parseDate(_ field: String) -> Date? {
    let trimmed = field.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }
    return dateFormatter.date(from: trimmed)
  }

  private let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()
}
