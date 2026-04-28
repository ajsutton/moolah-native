import Foundation
import Testing

@testable import Moolah

@Suite("Transaction.tradeTitleSentence")
struct TransactionTradeTitleTests {
  let aud = Instrument.AUD
  let usd = Instrument.fiat(code: "USD")
  let gbp = Instrument.fiat(code: "GBP")
  let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
  let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  let usdc = Instrument.crypto(
    chainId: 1, contractAddress: "0xa0b86", symbol: "USDC", name: "USD Coin", decimals: 6)
  let account = UUID()

  private func tradeTxn(
    _ legA: Instrument,
    _ legAQty: Decimal,
    _ legB: Instrument,
    _ legBQty: Decimal
  ) -> Transaction {
    Transaction(
      date: Date(),
      legs: [
        TransactionLeg(accountId: account, instrument: legA, quantity: legAQty, type: .trade),
        TransactionLeg(accountId: account, instrument: legB, quantity: legBQty, type: .trade),
      ])
  }

  @Test("matching leg negative → Bought")
  func boughtVerb() {
    let txn = tradeTxn(aud, -300, vgs, 20)
    #expect(txn.tradeTitleSentence(scopeReference: aud) == "Bought 20 VGS.AX")
  }

  @Test("matching leg positive → Sold")
  func soldVerb() {
    let txn = tradeTxn(aud, 425, vgs, -10)
    #expect(txn.tradeTitleSentence(scopeReference: aud) == "Sold 10 VGS.AX")
  }

  @Test("neither leg matches reference → Swapped")
  func swappedVerb() {
    let txn = tradeTxn(usd, -100, gbp, 50)
    #expect(txn.tradeTitleSentence(scopeReference: aud) == "Swapped 100 USD for 50 GBP")
  }

  @Test("neither matches, mixed fiat / non-fiat")
  func swappedVerbFiatToNonFiat() {
    let txn = tradeTxn(usd, -100, vgs, 5)
    #expect(txn.tradeTitleSentence(scopeReference: aud) == "Swapped 100 USD for 5 VGS.AX")
  }

  @Test("non-fiat ↔ non-fiat swap")
  func swappedVerbCryptoSwap() {
    let txn = tradeTxn(eth, -1, usdc, 30_000)
    #expect(txn.tradeTitleSentence(scopeReference: aud) == "Swapped 1 ETH for 30,000 USDC")
  }

  @Test("both legs share the reference instrument → Swapped")
  func bothMatchRef() {
    let txn = tradeTxn(aud, -100, aud, 100)
    #expect(txn.tradeTitleSentence(scopeReference: aud) == "Swapped 100 AUD for 100 AUD")
  }

  @Test("non-trade transaction returns nil")
  func nonTradeReturnsNil() {
    let txn = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(accountId: account, instrument: aud, quantity: -50, type: .expense)
      ])
    #expect(txn.tradeTitleSentence(scopeReference: aud) == nil)
  }
}
