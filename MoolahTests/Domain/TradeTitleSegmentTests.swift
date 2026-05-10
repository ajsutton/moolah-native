import Foundation
import Testing

@testable import Moolah

@Suite("Transaction.tradeTitleSegments")
struct TradeTitleSegmentTests {
  let aud = Instrument.AUD
  let usd = Instrument.fiat(code: "USD")
  let gbp = Instrument.fiat(code: "GBP")
  let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
  let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  let usdc = Instrument.crypto(
    chainId: 1, contractAddress: "0xa0b86", symbol: "USDC", name: "USD Coin", decimals: 6)
  let scam = Instrument.crypto(
    chainId: 1, contractAddress: "0xdeadbeef", symbol: "SCAM",
    name: "Scam Token", decimals: 18)
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

  private func magnitude(_ qty: Decimal, _ instrument: Instrument) -> InstrumentAmount {
    InstrumentAmount(quantity: abs(qty), instrument: instrument)
  }

  // MARK: - Existing semantics (preserved)

  @Test("matching leg negative → Bought")
  func boughtVerb() {
    let txn = tradeTxn(aud, -300, vgs, 20)
    #expect(
      txn.tradeTitleSegments(scopeReference: aud, spamInstruments: []) == [
        .literal("Bought "),
        .magnitude(magnitude(20, vgs)),
      ])
  }

  @Test("matching leg positive → Sold")
  func soldVerb() {
    let txn = tradeTxn(aud, 425, vgs, -10)
    #expect(
      txn.tradeTitleSegments(scopeReference: aud, spamInstruments: []) == [
        .literal("Sold "),
        .magnitude(magnitude(10, vgs)),
      ])
  }

  @Test("non-fiat scope reference matches non-fiat leg → reverse perspective")
  func nonFiatScopeReference() {
    let txn = tradeTxn(aud, -300, vgs, 20)
    #expect(
      txn.tradeTitleSegments(scopeReference: vgs, spamInstruments: []) == [
        .literal("Sold "),
        .magnitude(magnitude(300, aud)),
      ])
  }

  @Test("neither matches → Swapped X for Y")
  func swappedVerb() {
    let txn = tradeTxn(usd, -100, gbp, 50)
    #expect(
      txn.tradeTitleSegments(scopeReference: aud, spamInstruments: []) == [
        .literal("Swapped "),
        .magnitude(magnitude(100, usd)),
        .literal(" for "),
        .magnitude(magnitude(50, gbp)),
      ])
  }

  @Test("both legs share the reference instrument → Swapped")
  func bothMatchRef() {
    let txn = tradeTxn(aud, -100, aud, 100)
    #expect(
      txn.tradeTitleSegments(scopeReference: aud, spamInstruments: []) == [
        .literal("Swapped "),
        .magnitude(magnitude(100, aud)),
        .literal(" for "),
        .magnitude(magnitude(100, aud)),
      ])
  }

  @Test("non-trade transaction returns empty array")
  func nonTradeReturnsEmpty() {
    let txn = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(accountId: account, instrument: aud, quantity: -50, type: .expense)
      ])
    #expect(txn.tradeTitleSegments(scopeReference: aud, spamInstruments: []).isEmpty)
  }

  // MARK: - Spam swap

  @Test("Bought {spam} → spam magnitude segment")
  func boughtSpamSwap() {
    let txn = tradeTxn(aud, -300, scam, 1_000_000)
    #expect(
      txn.tradeTitleSegments(scopeReference: aud, spamInstruments: [scam]) == [
        .literal("Bought "),
        .spamMagnitude(magnitude(1_000_000, scam)),
      ])
  }

  @Test("Sold {spam} → spam magnitude segment")
  func soldSpamSwap() {
    let txn = tradeTxn(aud, 300, scam, -1_000_000)
    #expect(
      txn.tradeTitleSegments(scopeReference: aud, spamInstruments: [scam]) == [
        .literal("Sold "),
        .spamMagnitude(magnitude(1_000_000, scam)),
      ])
  }

  @Test("Swapped: only spam side is swapped")
  func swappedOneSidedSpamSwap() {
    let txn = tradeTxn(eth, -1, scam, 50_000)
    #expect(
      txn.tradeTitleSegments(scopeReference: aud, spamInstruments: [scam]) == [
        .literal("Swapped "),
        .magnitude(magnitude(1, eth)),
        .literal(" for "),
        .spamMagnitude(magnitude(50_000, scam)),
      ])
  }

  @Test("Swapped: both sides spam → both swapped")
  func swappedBothSpamSwap() {
    let txn = tradeTxn(usdc, -100, scam, 50_000)
    #expect(
      txn.tradeTitleSegments(scopeReference: aud, spamInstruments: [usdc, scam]) == [
        .literal("Swapped "),
        .spamMagnitude(magnitude(100, usdc)),
        .literal(" for "),
        .spamMagnitude(magnitude(50_000, scam)),
      ])
  }

  // MARK: - Accessibility per-segment

  @Test("literal segment accessibilityString returns the literal")
  func accessibilityLiteral() {
    #expect(TradeTitleSegment.literal("Bought ").accessibilityString == "Bought ")
  }

  @Test("magnitude segment accessibilityString returns formatted")
  func accessibilityMagnitude() {
    let amount = InstrumentAmount(quantity: 20, instrument: vgs)
    #expect(TradeTitleSegment.magnitude(amount).accessibilityString == amount.formatted)
  }

  @Test(
    "spamMagnitude segment accessibilityString matches InstrumentAmount.accessibilityString(isSpam: true)"
  )
  func accessibilitySpamMagnitudeDelegates() {
    let amount = InstrumentAmount(quantity: 1_000_000, instrument: scam)
    #expect(
      TradeTitleSegment.spamMagnitude(amount).accessibilityString
        == amount.accessibilityString(isSpam: true))
  }
}
