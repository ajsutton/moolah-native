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
}
