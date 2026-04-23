import Foundation
import Testing

@testable import Moolah

@Suite("TransactionLeg")
struct TransactionLegTests {
  let accountId = UUID()
  let aud = Instrument.AUD

  @Test
  func expenseLeg() {
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: aud,
      quantity: dec("-50.00"),
      type: .expense
    )
    #expect(leg.accountId == accountId)
    #expect(leg.instrument == aud)
    #expect(leg.quantity == dec("-50.00"))
    #expect(leg.type == .expense)
    #expect(leg.categoryId == nil)
    #expect(leg.earmarkId == nil)
  }

  @Test
  func legWithCategoryAndEarmark() {
    let catId = UUID()
    let earId = UUID()
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: aud,
      quantity: dec("-50.00"),
      type: .expense,
      categoryId: catId,
      earmarkId: earId
    )
    #expect(leg.categoryId == catId)
    #expect(leg.earmarkId == earId)
  }

  @Test
  func codableRoundTrip() throws {
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: aud,
      quantity: dec("-50.23"),
      type: .expense,
      categoryId: UUID()
    )
    let data = try JSONEncoder().encode(leg)
    let decoded = try JSONDecoder().decode(TransactionLeg.self, from: data)
    #expect(decoded == leg)
  }

  @Test
  func amount() {
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: aud,
      quantity: dec("-50.23"),
      type: .expense
    )
    #expect(leg.amount == InstrumentAmount(quantity: dec("-50.23"), instrument: aud))
  }

  @Test
  func nilAccountId() {
    let earId = UUID()
    let leg = TransactionLeg(
      accountId: nil,
      instrument: aud,
      quantity: 5,
      type: .income,
      earmarkId: earId
    )
    #expect(leg.accountId == nil)
    #expect(leg.earmarkId == earId)
    #expect(leg.quantity == 5)
  }

  @Test
  func nilAccountIdCodableRoundTrip() throws {
    let leg = TransactionLeg(
      accountId: nil,
      instrument: aud,
      quantity: 5,
      type: .income,
      earmarkId: UUID()
    )
    let data = try JSONEncoder().encode(leg)
    let decoded = try JSONDecoder().decode(TransactionLeg.self, from: data)
    #expect(decoded == leg)
    #expect(decoded.accountId == nil)
  }

  // MARK: - Multi-instrument leg behavior

  @Test
  func stockLegCodableRoundTripPreservesInstrumentMetadata() throws {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: bhp,
      quantity: Decimal(150),
      type: .transfer
    )
    let data = try JSONEncoder().encode(leg)
    let decoded = try JSONDecoder().decode(TransactionLeg.self, from: data)
    #expect(decoded == leg)
    #expect(decoded.instrument.kind == .stock)
    #expect(decoded.instrument.ticker == "BHP.AX")
    #expect(decoded.instrument.exchange == "ASX")
    #expect(decoded.quantity == Decimal(150))
  }

  @Test
  func cryptoLegCodableRoundTripPreservesChainMetadata() throws {
    let usdc = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC", name: "USD Coin", decimals: 6
    )
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: usdc,
      quantity: dec("1234.567890"),
      type: .transfer
    )
    let data = try JSONEncoder().encode(leg)
    let decoded = try JSONDecoder().decode(TransactionLeg.self, from: data)
    #expect(decoded == leg)
    #expect(decoded.instrument.kind == .cryptoToken)
    #expect(decoded.instrument.chainId == 1)
    #expect(
      decoded.instrument.contractAddress == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
    #expect(decoded.instrument.decimals == 6)
    #expect(decoded.quantity == dec("1234.567890"))
  }

  @Test
  func amountPropertyReturnsInstrumentAmountForStock() {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: bhp,
      quantity: Decimal(-50),
      type: .transfer
    )
    let expected = InstrumentAmount(quantity: Decimal(-50), instrument: bhp)
    #expect(leg.amount == expected)
    #expect(leg.amount.instrument.kind == .stock)
  }

  @Test
  func amountPropertyReturnsInstrumentAmountForCrypto() {
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: eth,
      quantity: dec("0.12345678"),
      type: .transfer
    )
    #expect(leg.amount.instrument == eth)
    #expect(leg.amount.quantity == dec("0.12345678"))
  }
}
