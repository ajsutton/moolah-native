import Foundation
import Testing

@testable import Moolah

@Suite("Transaction.isTrade")
struct TransactionIsTradeTests {
  let aud = Instrument.AUD
  let usd = Instrument.fiat(code: "USD")
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
  let account = UUID()
  let otherAccount = UUID()
  let categoryId = UUID()
  let earmarkId = UUID()

  private func tradeLeg(
    instrument: Instrument,
    quantity: Decimal,
    account: UUID,
    category: UUID? = nil,
    earmark: UUID? = nil
  ) -> TransactionLeg {
    TransactionLeg(
      accountId: account, instrument: instrument, quantity: quantity,
      type: .trade, categoryId: category, earmarkId: earmark)
  }

  private func feeLeg(
    instrument: Instrument,
    quantity: Decimal,
    account: UUID,
    category: UUID? = nil,
    earmark: UUID? = nil
  ) -> TransactionLeg {
    TransactionLeg(
      accountId: account, instrument: instrument, quantity: quantity,
      type: .expense, categoryId: category, earmarkId: earmark)
  }

  private func makeTransaction(legs: [TransactionLeg]) -> Transaction {
    Transaction(date: Date(), legs: legs)
  }

  // MARK: - Accept

  @Test("two trade legs no fee")
  func twoTradeLegsNoFee() {
    let transaction = makeTransaction(legs: [
      tradeLeg(instrument: aud, quantity: -300, account: account),
      tradeLeg(instrument: vgs, quantity: 20, account: account),
    ])
    #expect(transaction.isTrade)
  }

  @Test("two trade legs plus one fee")
  func twoTradeLegsOneFee() {
    let transaction = makeTransaction(legs: [
      tradeLeg(instrument: aud, quantity: -300, account: account),
      tradeLeg(instrument: vgs, quantity: 20, account: account),
      feeLeg(instrument: aud, quantity: -10, account: account),
    ])
    #expect(transaction.isTrade)
  }

  @Test("two trade legs plus multiple fees in different instruments")
  func twoTradeLegsMultipleFees() {
    let transaction = makeTransaction(legs: [
      tradeLeg(instrument: aud, quantity: -300, account: account),
      tradeLeg(instrument: vgs, quantity: 20, account: account),
      feeLeg(instrument: aud, quantity: -10, account: account),
      feeLeg(instrument: usd, quantity: -5, account: account),
    ])
    #expect(transaction.isTrade)
  }

  @Test("same-instrument paid and received is allowed")
  func sameInstrumentPaidReceived() {
    let transaction = makeTransaction(legs: [
      tradeLeg(instrument: aud, quantity: -100, account: account),
      tradeLeg(instrument: aud, quantity: 100, account: account),
    ])
    #expect(transaction.isTrade)
  }

  @Test("same-sign trade legs are allowed")
  func sameSignLegs() {
    let transaction = makeTransaction(legs: [
      tradeLeg(instrument: aud, quantity: 100, account: account),
      tradeLeg(instrument: vgs, quantity: 5, account: account),
    ])
    #expect(transaction.isTrade)
  }

  @Test("zero-quantity trade legs are allowed")
  func zeroQuantityLegs() {
    let transaction = makeTransaction(legs: [
      tradeLeg(instrument: aud, quantity: 0, account: account),
      tradeLeg(instrument: vgs, quantity: 0, account: account),
    ])
    #expect(transaction.isTrade)
  }

  @Test("fee leg may carry a category")
  func feeWithCategory() {
    let transaction = makeTransaction(legs: [
      tradeLeg(instrument: aud, quantity: -300, account: account),
      tradeLeg(instrument: vgs, quantity: 20, account: account),
      feeLeg(instrument: aud, quantity: -10, account: account, category: categoryId),
    ])
    #expect(transaction.isTrade)
  }

  @Test("fee leg may carry an earmark")
  func feeWithEarmark() {
    let transaction = makeTransaction(legs: [
      tradeLeg(instrument: aud, quantity: -300, account: account),
      tradeLeg(instrument: vgs, quantity: 20, account: account),
      feeLeg(instrument: aud, quantity: -10, account: account, earmark: earmarkId),
    ])
    #expect(transaction.isTrade)
  }

  // MARK: - Reject

  @Test("empty legs is not a trade")
  func emptyLegsIsNotATrade() {
    #expect(!makeTransaction(legs: []).isTrade)
  }

  @Test("one trade leg is not a trade")
  func oneTradeLeg() {
    let transaction = makeTransaction(legs: [
      tradeLeg(instrument: aud, quantity: -300, account: account)
    ])
    #expect(!transaction.isTrade)
  }

  @Test("three trade legs is not a trade")
  func threeTradeLegs() {
    let transaction = makeTransaction(legs: [
      tradeLeg(instrument: aud, quantity: -300, account: account),
      tradeLeg(instrument: vgs, quantity: 10, account: account),
      tradeLeg(instrument: bhp, quantity: 5, account: account),
    ])
    #expect(!transaction.isTrade)
  }

  @Test("trade leg with a category is not a trade")
  func tradeLegWithCategory() {
    let transaction = makeTransaction(legs: [
      tradeLeg(instrument: aud, quantity: -300, account: account, category: categoryId),
      tradeLeg(instrument: vgs, quantity: 20, account: account),
    ])
    #expect(!transaction.isTrade)
  }

  @Test("trade leg with an earmark is not a trade")
  func tradeLegWithEarmark() {
    let transaction = makeTransaction(legs: [
      tradeLeg(instrument: aud, quantity: -300, account: account, earmark: earmarkId),
      tradeLeg(instrument: vgs, quantity: 20, account: account),
    ])
    #expect(!transaction.isTrade)
  }

  @Test("legs on different accounts is not a trade")
  func mixedAccounts() {
    let transaction = makeTransaction(legs: [
      tradeLeg(instrument: aud, quantity: -300, account: account),
      tradeLeg(instrument: vgs, quantity: 20, account: otherAccount),
    ])
    #expect(!transaction.isTrade)
  }

  @Test("fee leg on a different account is not a trade")
  func feeOnOtherAccount() {
    let transaction = makeTransaction(legs: [
      tradeLeg(instrument: aud, quantity: -300, account: account),
      tradeLeg(instrument: vgs, quantity: 20, account: account),
      feeLeg(instrument: aud, quantity: -10, account: otherAccount),
    ])
    #expect(!transaction.isTrade)
  }

  @Test("non-expense extra leg (e.g. income) is not a trade")
  func incomeExtraLeg() {
    let income = TransactionLeg(
      accountId: account, instrument: aud, quantity: 5, type: .income)
    let transaction = makeTransaction(legs: [
      tradeLeg(instrument: aud, quantity: -300, account: account),
      tradeLeg(instrument: vgs, quantity: 20, account: account),
      income,
    ])
    #expect(!transaction.isTrade)
  }

  @Test("legs without an account id are not a trade")
  func legsMissingAccount() {
    let leg1 = TransactionLeg(accountId: nil, instrument: aud, quantity: -300, type: .trade)
    let leg2 = TransactionLeg(accountId: nil, instrument: vgs, quantity: 20, type: .trade)
    #expect(!makeTransaction(legs: [leg1, leg2]).isTrade)
  }
}
