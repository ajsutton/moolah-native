import Foundation
import Testing

@testable import Moolah

@Suite("Transaction.importOrigin")
struct TransactionImportOriginTests {

  @Test("Transaction carries optional ImportOrigin; nil by default")
  func defaultsToNil() {
    let transaction = Transaction(date: Date(), legs: [])
    #expect(transaction.importOrigin == nil)
  }

  @Test("Transaction.importOrigin survives Codable round-trip")
  func codableRoundTrip() throws {
    let origin = ImportOrigin(
      rawDescription: "COFFEE",
      bankReference: "REF1",
      rawAmount: dec("-12.34"),
      rawBalance: dec("100.00"),
      importedAt: Date(timeIntervalSince1970: 1_700_000_000),
      importSessionId: UUID(),
      sourceFilename: "transactions.csv",
      parserIdentifier: "generic-bank")
    let transaction = Transaction(date: Date(), legs: [], importOrigin: origin)
    let data = try JSONEncoder().encode(transaction)
    let decoded = try JSONDecoder().decode(Transaction.self, from: data)
    #expect(decoded.importOrigin == origin)
  }

  @Test("nil importOrigin still round-trips cleanly")
  func nilCodableRoundTrip() throws {
    let transaction = Transaction(date: Date(), legs: [])
    let data = try JSONEncoder().encode(transaction)
    let decoded = try JSONDecoder().decode(Transaction.self, from: data)
    #expect(decoded.importOrigin == nil)
  }
}
