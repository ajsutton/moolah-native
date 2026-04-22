import Foundation
import Testing

@testable import Moolah

@Suite("Transaction.isSimpleCrossCurrencyTransfer")
struct IsSimpleCrossCurrencyTransferTests {
  let aud = Instrument.AUD
  let usd = Instrument.USD

  func makeLeg(
    accountId: UUID? = UUID(),
    instrument: Instrument = .AUD,
    quantity: Decimal = -100,
    type: TransactionType = .transfer,
    categoryId: UUID? = nil,
    earmarkId: UUID? = nil
  ) -> TransactionLeg {
    TransactionLeg(
      accountId: accountId,
      instrument: instrument,
      quantity: quantity,
      type: type,
      categoryId: categoryId,
      earmarkId: earmarkId
    )
  }

  func makeTransaction(legs: [TransactionLeg]) -> Transaction {
    Transaction(date: Date(), legs: legs)
  }

  // MARK: - True case

  @Test("Two transfer legs with different instruments and different accounts")
  func isSimpleCrossCurrencyTransferWithDifferentInstruments() {
    let transaction = makeTransaction(legs: [
      makeLeg(instrument: aud, quantity: -100),
      makeLeg(instrument: usd, quantity: 75),
    ])
    #expect(transaction.isSimpleCrossCurrencyTransfer == true)
  }

  // MARK: - False cases

  @Test("False when instruments are the same")
  func isSimpleCrossCurrencyTransferFalseForSameCurrency() {
    let transaction = makeTransaction(legs: [
      makeLeg(instrument: aud, quantity: -100),
      makeLeg(instrument: aud, quantity: 100),
    ])
    #expect(transaction.isSimpleCrossCurrencyTransfer == false)
  }

  @Test("False for single-leg transaction")
  func isSimpleCrossCurrencyTransferFalseForSingleLeg() {
    let transaction = makeTransaction(legs: [
      makeLeg(instrument: aud, quantity: -100)
    ])
    #expect(transaction.isSimpleCrossCurrencyTransfer == false)
  }

  @Test("False when second leg has categoryId")
  func isSimpleCrossCurrencyTransferFalseWhenSecondLegHasCategory() {
    let transaction = makeTransaction(legs: [
      makeLeg(instrument: aud, quantity: -100),
      makeLeg(instrument: usd, quantity: 75, categoryId: UUID()),
    ])
    #expect(transaction.isSimpleCrossCurrencyTransfer == false)
  }

  @Test("False when both legs have same accountId")
  func isSimpleCrossCurrencyTransferFalseWhenSameAccount() {
    let acctId = UUID()
    let transaction = makeTransaction(legs: [
      makeLeg(accountId: acctId, instrument: aud, quantity: -100),
      makeLeg(accountId: acctId, instrument: usd, quantity: 75),
    ])
    #expect(transaction.isSimpleCrossCurrencyTransfer == false)
  }

  @Test("False when one leg has nil accountId")
  func isSimpleCrossCurrencyTransferFalseWhenNilAccountId() {
    let transaction = makeTransaction(legs: [
      makeLeg(instrument: aud, quantity: -100),
      makeLeg(accountId: nil, instrument: usd, quantity: 75),
    ])
    #expect(transaction.isSimpleCrossCurrencyTransfer == false)
  }

  @Test("False when second leg has earmarkId")
  func isSimpleCrossCurrencyTransferFalseWhenSecondLegHasEarmark() {
    let transaction = makeTransaction(legs: [
      makeLeg(instrument: aud, quantity: -100),
      makeLeg(instrument: usd, quantity: 75, earmarkId: UUID()),
    ])
    #expect(transaction.isSimpleCrossCurrencyTransfer == false)
  }

  @Test("False when leg types are not transfer")
  func isSimpleCrossCurrencyTransferFalseWhenNotTransfer() {
    let transaction = makeTransaction(legs: [
      makeLeg(instrument: aud, quantity: -100, type: .expense),
      makeLeg(instrument: usd, quantity: 75, type: .income),
    ])
    #expect(transaction.isSimpleCrossCurrencyTransfer == false)
  }
}
