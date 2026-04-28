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

  /// Computes the same magnitude string the implementation produces — uses
  /// `InstrumentAmount.formatted` so the assertions stay locale-resilient.
  private func formatted(_ qty: Decimal, _ instrument: Instrument) -> String {
    InstrumentAmount(quantity: qty, instrument: instrument).formatted
  }

  @Test("matching leg negative → Bought")
  func boughtVerb() {
    let txn = tradeTxn(aud, -300, vgs, 20)
    #expect(txn.tradeTitleSentence(scopeReference: aud) == "Bought \(formatted(20, vgs))")
  }

  @Test("matching leg positive → Sold")
  func soldVerb() {
    let txn = tradeTxn(aud, 425, vgs, -10)
    #expect(txn.tradeTitleSentence(scopeReference: aud) == "Sold \(formatted(10, vgs))")
  }

  @Test("USD scope reference matches USD leg → Bought")
  func boughtVerbWithUSDReference() {
    let txn = tradeTxn(usd, -300, vgs, 20)
    #expect(txn.tradeTitleSentence(scopeReference: usd) == "Bought \(formatted(20, vgs))")
  }

  @Test("non-fiat scope reference matches non-fiat leg → reverse perspective")
  func nonFiatScopeReference() {
    // From a stock-instrument scope, the direction reads from the position's
    // perspective: paying out 300 AUD to acquire 20 VGS reads as
    // "Sold {300 AUD}" because VGS is the matching (positive) leg under the
    // stock scope.
    let txn = tradeTxn(aud, -300, vgs, 20)
    #expect(txn.tradeTitleSentence(scopeReference: vgs) == "Sold \(formatted(300, aud))")
  }

  @Test("neither leg matches reference → Swapped")
  func swappedVerb() {
    let txn = tradeTxn(usd, -100, gbp, 50)
    #expect(
      txn.tradeTitleSentence(scopeReference: aud)
        == "Swapped \(formatted(100, usd)) for \(formatted(50, gbp))"
    )
  }

  @Test("neither matches, mixed fiat / non-fiat")
  func swappedVerbFiatToNonFiat() {
    let txn = tradeTxn(usd, -100, vgs, 5)
    #expect(
      txn.tradeTitleSentence(scopeReference: aud)
        == "Swapped \(formatted(100, usd)) for \(formatted(5, vgs))"
    )
  }

  @Test("non-fiat ↔ non-fiat swap")
  func swappedVerbCryptoSwap() {
    let txn = tradeTxn(eth, -1, usdc, 30_000)
    #expect(
      txn.tradeTitleSentence(scopeReference: aud)
        == "Swapped \(formatted(1, eth)) for \(formatted(30_000, usdc))"
    )
  }

  @Test("both legs share the reference instrument → Swapped")
  func bothMatchRef() {
    let txn = tradeTxn(aud, -100, aud, 100)
    #expect(
      txn.tradeTitleSentence(scopeReference: aud)
        == "Swapped \(formatted(100, aud)) for \(formatted(100, aud))"
    )
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
