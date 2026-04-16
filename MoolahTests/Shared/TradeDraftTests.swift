import Foundation
import Testing

@testable import Moolah

@Suite("TradeDraft")
struct TradeDraftTests {
  let accountId = UUID()
  let aud = Instrument.fiat(code: "AUD")
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let feeCategoryId = UUID()

  // MARK: - Validation

  @Test func emptyDraftIsInvalid() {
    let draft = TradeDraft(accountId: accountId)
    #expect(!draft.isValid)
  }

  @Test func validBuyDraft() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    draft.date = Date()
    #expect(draft.isValid)
  }

  @Test func missingBoughtInstrumentIsInvalid() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtQuantityText = "150"
    draft.date = Date()
    #expect(!draft.isValid)
  }

  @Test func zeroQuantityIsInvalid() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "0"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    #expect(!draft.isValid)
  }

  // MARK: - Leg Generation

  @Test func buyStockProducesTwoTransferLegs() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    draft.date = Date()

    let transaction = draft.toTransaction(id: UUID())
    #expect(transaction != nil)

    let legs = transaction!.legs
    #expect(legs.count == 2)

    // Leg 0: cash outflow
    #expect(legs[0].accountId == accountId)
    #expect(legs[0].instrument == aud)
    #expect(legs[0].quantity == Decimal(string: "-6345.00")!)
    #expect(legs[0].type == .transfer)

    // Leg 1: stock inflow
    #expect(legs[1].accountId == accountId)
    #expect(legs[1].instrument == bhp)
    #expect(legs[1].quantity == Decimal(150))
    #expect(legs[1].type == .transfer)
  }

  @Test func buyStockWithFeeProducesThreeLegs() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    draft.feeAmountText = "9.50"
    draft.feeInstrument = aud
    draft.feeCategoryId = feeCategoryId
    draft.date = Date()

    let transaction = draft.toTransaction(id: UUID())
    #expect(transaction != nil)

    let legs = transaction!.legs
    #expect(legs.count == 3)

    // Leg 2: fee expense
    #expect(legs[2].accountId == accountId)
    #expect(legs[2].instrument == aud)
    #expect(legs[2].quantity == Decimal(string: "-9.50")!)
    #expect(legs[2].type == .expense)
    #expect(legs[2].categoryId == feeCategoryId)
  }

  @Test func sellStockProducesCorrectSigns() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = bhp
    draft.soldQuantityText = "50"
    draft.boughtInstrument = aud
    draft.boughtQuantityText = "2115.00"
    draft.date = Date()

    let transaction = draft.toTransaction(id: UUID())
    #expect(transaction != nil)

    let legs = transaction!.legs
    #expect(legs.count == 2)

    // Leg 0: stock outflow
    #expect(legs[0].instrument == bhp)
    #expect(legs[0].quantity == Decimal(-50))

    // Leg 1: cash inflow
    #expect(legs[1].instrument == aud)
    #expect(legs[1].quantity == Decimal(string: "2115.00")!)
  }

  @Test func transactionPayeeIsGeneratedFromTrade() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    draft.date = Date()

    let transaction = draft.toTransaction(id: UUID())
    #expect(transaction?.payee == "Buy 150 BHP")
  }

  @Test func sellTransactionPayee() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = bhp
    draft.soldQuantityText = "50"
    draft.boughtInstrument = aud
    draft.boughtQuantityText = "2115.00"
    draft.date = Date()

    let transaction = draft.toTransaction(id: UUID())
    #expect(transaction?.payee == "Sell 50 BHP")
  }

  @Test func feeWithoutCategoryStillValid() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    draft.feeAmountText = "9.50"
    draft.feeInstrument = aud
    draft.date = Date()

    #expect(draft.isValid)
    let legs = draft.toTransaction(id: UUID())!.legs
    #expect(legs.count == 3)
    #expect(legs[2].categoryId == nil)
  }

  @Test func parsedQuantitiesHandleCommas() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "1,234.56"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "100"
    draft.date = Date()

    let transaction = draft.toTransaction(id: UUID())
    #expect(transaction != nil)
    #expect(transaction!.legs[0].quantity == Decimal(string: "-1234.56")!)
  }

  // MARK: - Cross-instrument trades

  @Test func stockToStockTradeProducesTwoStockLegsAndTradePayee() throws {
    let aapl = Instrument.stock(ticker: "AAPL", exchange: "NASDAQ", name: "Apple")
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = bhp
    draft.soldQuantityText = "100"
    draft.boughtInstrument = aapl
    draft.boughtQuantityText = "25"
    draft.date = Date()

    let transaction = try #require(draft.toTransaction(id: UUID()))
    #expect(transaction.legs.count == 2)
    #expect(transaction.legs[0].instrument == bhp)
    #expect(transaction.legs[0].quantity == Decimal(-100))
    #expect(transaction.legs[1].instrument == aapl)
    #expect(transaction.legs[1].quantity == Decimal(25))
    #expect(transaction.payee == "Trade BHP for Apple")
  }

  @Test func cryptoToCryptoSwapProducesTwoCryptoLegs() throws {
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    let uni = Instrument.crypto(
      chainId: 1,
      contractAddress: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984",
      symbol: "UNI", name: "Uniswap", decimals: 18
    )
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = eth
    draft.soldQuantityText = "0.5"
    draft.boughtInstrument = uni
    draft.boughtQuantityText = "1234.56"
    draft.date = Date()

    let transaction = try #require(draft.toTransaction(id: UUID()))
    #expect(transaction.legs.count == 2)
    #expect(transaction.legs[0].instrument == eth)
    #expect(transaction.legs[0].quantity == Decimal(string: "-0.5")!)
    #expect(transaction.legs[1].instrument == uni)
    #expect(transaction.legs[1].quantity == Decimal(string: "1234.56")!)
    #expect(transaction.payee == "Trade Ethereum for Uniswap")
  }

  @Test func crossCurrencyFiatTradeProducesTwoFiatLegs() throws {
    let usd = Instrument.fiat(code: "USD")
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "1000.00"
    draft.boughtInstrument = usd
    draft.boughtQuantityText = "650.00"
    draft.date = Date()

    let transaction = try #require(draft.toTransaction(id: UUID()))
    #expect(transaction.legs.count == 2)
    #expect(transaction.legs[0].instrument == aud)
    #expect(transaction.legs[0].quantity == Decimal(string: "-1000.00")!)
    #expect(transaction.legs[1].instrument == usd)
    #expect(transaction.legs[1].quantity == Decimal(string: "650.00")!)
    #expect(transaction.legs[0].type == .transfer)
    #expect(transaction.legs[1].type == .transfer)
    #expect(transaction.payee == "Trade AUD for USD")
  }

  @Test func feeDefaultsToSoldInstrumentWhenFeeInstrumentIsNil() throws {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    draft.feeAmountText = "9.50"
    draft.feeInstrument = nil
    draft.date = Date()

    let transaction = try #require(draft.toTransaction(id: UUID()))
    #expect(transaction.legs.count == 3)
    #expect(transaction.legs[2].instrument == aud)
    #expect(transaction.legs[2].quantity == Decimal(string: "-9.50")!)
    #expect(transaction.legs[2].type == .expense)
  }

  @Test func feeInThirdInstrumentPersistsOnLeg() throws {
    // Sell USD, buy BHP, fee in AUD — three distinct instruments.
    let usd = Instrument.fiat(code: "USD")
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = usd
    draft.soldQuantityText = "4200.00"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    draft.feeAmountText = "12.00"
    draft.feeInstrument = aud
    draft.feeCategoryId = feeCategoryId
    draft.date = Date()

    let transaction = try #require(draft.toTransaction(id: UUID()))
    #expect(transaction.legs.count == 3)
    #expect(transaction.legs[0].instrument == usd)
    #expect(transaction.legs[1].instrument == bhp)
    #expect(transaction.legs[2].instrument == aud)
    #expect(transaction.legs[2].quantity == Decimal(string: "-12.00")!)
    #expect(transaction.legs[2].categoryId == feeCategoryId)
    let instrumentIds = Set(transaction.legs.map { $0.instrument.id })
    #expect(instrumentIds.count == 3)
  }

  @Test func cryptoTradeWithFeeInNativeGasToken() throws {
    // Swap UNI for USDC, pay gas fee in ETH — fee in instrument different from both trade sides.
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    let uni = Instrument.crypto(
      chainId: 1,
      contractAddress: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984",
      symbol: "UNI", name: "Uniswap", decimals: 18
    )
    let usdc = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC", name: "USD Coin", decimals: 6
    )
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = uni
    draft.soldQuantityText = "100"
    draft.boughtInstrument = usdc
    draft.boughtQuantityText = "550.00"
    draft.feeAmountText = "0.002"
    draft.feeInstrument = eth
    draft.feeCategoryId = feeCategoryId
    draft.date = Date()

    let transaction = try #require(draft.toTransaction(id: UUID()))
    #expect(transaction.legs.count == 3)
    #expect(transaction.legs[2].instrument == eth)
    #expect(transaction.legs[2].quantity == Decimal(string: "-0.002")!)
    #expect(transaction.legs[2].type == .expense)
  }
}
