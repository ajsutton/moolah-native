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
    _ instr: Instrument, _ qty: Decimal,
    account: UUID, category: UUID? = nil, earmark: UUID? = nil
  ) -> TransactionLeg {
    TransactionLeg(
      accountId: account, instrument: instr, quantity: qty,
      type: .trade, categoryId: category, earmarkId: earmark)
  }

  private func feeLeg(
    _ instr: Instrument, _ qty: Decimal,
    account: UUID, category: UUID? = nil, earmark: UUID? = nil
  ) -> TransactionLeg {
    TransactionLeg(
      accountId: account, instrument: instr, quantity: qty,
      type: .expense, categoryId: category, earmarkId: earmark)
  }

  private func txn(_ legs: [TransactionLeg]) -> Transaction {
    Transaction(date: Date(), legs: legs)
  }

  // MARK: - Accept

  @Test("two trade legs no fee")
  func twoTradeLegsNoFee() {
    let t = txn([tradeLeg(aud, -300, account: account), tradeLeg(vgs, 20, account: account)])
    #expect(t.isTrade)
  }

  @Test("two trade legs plus one fee")
  func twoTradeLegsOneFee() {
    let t = txn([
      tradeLeg(aud, -300, account: account),
      tradeLeg(vgs, 20, account: account),
      feeLeg(aud, -10, account: account),
    ])
    #expect(t.isTrade)
  }

  @Test("two trade legs plus multiple fees in different instruments")
  func twoTradeLegsMultipleFees() {
    let t = txn([
      tradeLeg(aud, -300, account: account),
      tradeLeg(vgs, 20, account: account),
      feeLeg(aud, -10, account: account),
      feeLeg(usd, -5, account: account),
    ])
    #expect(t.isTrade)
  }

  @Test("same-instrument paid and received is allowed")
  func sameInstrumentPaidReceived() {
    let t = txn([tradeLeg(aud, -100, account: account), tradeLeg(aud, 100, account: account)])
    #expect(t.isTrade)
  }

  @Test("same-sign trade legs are allowed")
  func sameSignLegs() {
    let t = txn([tradeLeg(aud, 100, account: account), tradeLeg(vgs, 5, account: account)])
    #expect(t.isTrade)
  }

  @Test("zero-quantity trade legs are allowed")
  func zeroQuantityLegs() {
    let t = txn([tradeLeg(aud, 0, account: account), tradeLeg(vgs, 0, account: account)])
    #expect(t.isTrade)
  }

  @Test("fee leg may carry a category")
  func feeWithCategory() {
    let t = txn([
      tradeLeg(aud, -300, account: account),
      tradeLeg(vgs, 20, account: account),
      feeLeg(aud, -10, account: account, category: categoryId),
    ])
    #expect(t.isTrade)
  }

  @Test("fee leg may carry an earmark")
  func feeWithEarmark() {
    let t = txn([
      tradeLeg(aud, -300, account: account),
      tradeLeg(vgs, 20, account: account),
      feeLeg(aud, -10, account: account, earmark: earmarkId),
    ])
    #expect(t.isTrade)
  }

  // MARK: - Reject

  @Test("one trade leg is not a trade")
  func oneTradeLeg() {
    let t = txn([tradeLeg(aud, -300, account: account)])
    #expect(!t.isTrade)
  }

  @Test("three trade legs is not a trade")
  func threeTradeLegs() {
    let t = txn([
      tradeLeg(aud, -300, account: account),
      tradeLeg(vgs, 10, account: account),
      tradeLeg(bhp, 5, account: account),
    ])
    #expect(!t.isTrade)
  }

  @Test("trade leg with a category is not a trade")
  func tradeLegWithCategory() {
    let t = txn([
      tradeLeg(aud, -300, account: account, category: categoryId),
      tradeLeg(vgs, 20, account: account),
    ])
    #expect(!t.isTrade)
  }

  @Test("trade leg with an earmark is not a trade")
  func tradeLegWithEarmark() {
    let t = txn([
      tradeLeg(aud, -300, account: account, earmark: earmarkId),
      tradeLeg(vgs, 20, account: account),
    ])
    #expect(!t.isTrade)
  }

  @Test("legs on different accounts is not a trade")
  func mixedAccounts() {
    let t = txn([
      tradeLeg(aud, -300, account: account),
      tradeLeg(vgs, 20, account: otherAccount),
    ])
    #expect(!t.isTrade)
  }

  @Test("fee leg on a different account is not a trade")
  func feeOnOtherAccount() {
    let t = txn([
      tradeLeg(aud, -300, account: account),
      tradeLeg(vgs, 20, account: account),
      feeLeg(aud, -10, account: otherAccount),
    ])
    #expect(!t.isTrade)
  }

  @Test("non-expense extra leg (e.g. income) is not a trade")
  func incomeExtraLeg() {
    let income = TransactionLeg(accountId: account, instrument: aud, quantity: 5, type: .income)
    let t = txn([
      tradeLeg(aud, -300, account: account),
      tradeLeg(vgs, 20, account: account),
      income,
    ])
    #expect(!t.isTrade)
  }

  @Test("legs without an account id are not a trade")
  func legsMissingAccount() {
    let leg1 = TransactionLeg(accountId: nil, instrument: aud, quantity: -300, type: .trade)
    let leg2 = TransactionLeg(accountId: nil, instrument: vgs, quantity: 20, type: .trade)
    #expect(!txn([leg1, leg2]).isTrade)
  }
}
