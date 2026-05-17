import Foundation
import Testing

@testable import Moolah

@Suite("Transaction.importOrigin widening")
struct TransactionImportOriginAccessorTests {
  @Test("transferSuggestion defaults nil; importOrigin is the sum type")
  func defaults() {
    let leg = TransactionLeg(
      accountId: UUID(), instrument: .defaultTestInstrument, quantity: -10,
      type: .expense)
    var transaction = Transaction(date: Date(), legs: [leg])
    #expect(transaction.transferSuggestion == nil)
    #expect(transaction.importOrigin == nil)
    let origin = ImportOrigin(
      rawDescription: "x", rawAmount: 10, importedAt: Date(),
      importSessionId: UUID(), parserIdentifier: "p")
    transaction.importOrigin = .single(origin)
    #expect(transaction.importOrigin?.singleOrigin == origin)
  }
}
