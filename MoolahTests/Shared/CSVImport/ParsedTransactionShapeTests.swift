import Foundation
import Testing

@testable import Moolah

@Suite("ParsedTransaction types")
struct ParsedTransactionShapeTests {

  @Test("ParsedTransaction carries rawRow, rawDescription, legs, and a bank reference")
  func parsedTransactionInit() {
    let tx = ParsedTransaction(
      date: Date(timeIntervalSince1970: 0),
      legs: [
        ParsedLeg(
          accountId: nil,
          instrument: .AUD,
          quantity: Decimal(string: "-12.34")!,
          type: .expense)
      ],
      rawRow: ["2024-01-01", "-12.34", "Coffee"],
      rawDescription: "Coffee",
      rawAmount: Decimal(string: "-12.34")!,
      rawBalance: nil,
      bankReference: "REF-1")
    #expect(tx.legs.count == 1)
    #expect(tx.bankReference == "REF-1")
    #expect(tx.legs.first?.accountId == nil)
    #expect(tx.legs.first?.instrument == .AUD)
  }

  @Test("ParsedRecord round-trips a .transaction and a .skip")
  func parsedRecordCases() {
    let tx = ParsedTransaction(
      date: Date(timeIntervalSince1970: 0),
      legs: [],
      rawRow: [],
      rawDescription: "",
      rawAmount: 0,
      rawBalance: nil,
      bankReference: nil)
    let wrapped = ParsedRecord.transaction(tx)
    let skip = ParsedRecord.skip(reason: "summary row")
    if case .transaction(let unwrapped) = wrapped {
      #expect(unwrapped == tx)
    } else {
      Issue.record("expected .transaction case")
    }
    if case .skip(let reason) = skip {
      #expect(reason == "summary row")
    } else {
      Issue.record("expected .skip case")
    }
  }

  @Test("CSVParserError.malformedRow carries the row index, reason, and row")
  func csvParserErrorShape() {
    let e = CSVParserError.malformedRow(
      index: 7, reason: "unparseable amount", row: ["a", "b", "c"])
    if case .malformedRow(let index, let reason, let row) = e {
      #expect(index == 7)
      #expect(reason == "unparseable amount")
      #expect(row == ["a", "b", "c"])
    } else {
      Issue.record("expected .malformedRow")
    }
  }
}
