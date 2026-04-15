import Foundation
import Testing

@testable import Moolah

@Suite("TokenSwapDraft")
struct TokenSwapDraftTests {
  let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  let uni = Instrument.crypto(
    chainId: 1,
    contractAddress: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
    symbol: "UNI", name: "Uniswap", decimals: 18
  )
  let accountId = UUID()

  @Test func simpleSwapProducesTwoTransferLegs() {
    var draft = TokenSwapDraft(accountId: accountId)
    draft.sourceInstrument = eth
    draft.sourceQuantity = Decimal(string: "0.5")!
    draft.destinationInstrument = uni
    draft.destinationQuantity = Decimal(string: "1234.56")!
    draft.date = Date()

    let legs = draft.buildLegs()
    #expect(legs.count == 2)

    // Source leg: outflow
    let sourceLeg = legs[0]
    #expect(sourceLeg.accountId == accountId)
    #expect(sourceLeg.instrument == eth)
    #expect(sourceLeg.quantity == Decimal(string: "-0.5")!)
    #expect(sourceLeg.type == .transfer)

    // Destination leg: inflow
    let destLeg = legs[1]
    #expect(destLeg.accountId == accountId)
    #expect(destLeg.instrument == uni)
    #expect(destLeg.quantity == Decimal(string: "1234.56")!)
    #expect(destLeg.type == .transfer)
  }

  @Test func swapWithGasFeeProducesThreeLegs() {
    var draft = TokenSwapDraft(accountId: accountId)
    draft.sourceInstrument = eth
    draft.sourceQuantity = Decimal(string: "0.5")!
    draft.destinationInstrument = uni
    draft.destinationQuantity = Decimal(string: "1234.56")!
    draft.gasFeeInstrument = eth
    draft.gasFeeQuantity = Decimal(string: "0.002")!
    draft.date = Date()

    let legs = draft.buildLegs()
    #expect(legs.count == 3)

    // Gas fee leg: expense
    let feeLeg = legs[2]
    #expect(feeLeg.accountId == accountId)
    #expect(feeLeg.instrument == eth)
    #expect(feeLeg.quantity == Decimal(string: "-0.002")!)
    #expect(feeLeg.type == .expense)
  }

  @Test func swapWithGasFeeCategoryAssigned() {
    let gasCategoryId = UUID()
    var draft = TokenSwapDraft(accountId: accountId)
    draft.sourceInstrument = eth
    draft.sourceQuantity = Decimal(string: "0.5")!
    draft.destinationInstrument = uni
    draft.destinationQuantity = Decimal(string: "1234.56")!
    draft.gasFeeInstrument = eth
    draft.gasFeeQuantity = Decimal(string: "0.002")!
    draft.gasFeeCategoryId = gasCategoryId
    draft.date = Date()

    let legs = draft.buildLegs()
    let feeLeg = legs[2]
    #expect(feeLeg.categoryId == gasCategoryId)
  }

  @Test func validationRequiresSourceAndDestination() {
    var draft = TokenSwapDraft(accountId: accountId)
    #expect(draft.isValid == false)

    draft.sourceInstrument = eth
    draft.sourceQuantity = Decimal(string: "0.5")!
    #expect(draft.isValid == false)

    draft.destinationInstrument = uni
    draft.destinationQuantity = Decimal(string: "100")!
    #expect(draft.isValid == true)
  }

  @Test func validationRejectsZeroQuantities() {
    var draft = TokenSwapDraft(accountId: accountId)
    draft.sourceInstrument = eth
    draft.sourceQuantity = Decimal(0)
    draft.destinationInstrument = uni
    draft.destinationQuantity = Decimal(string: "100")!
    #expect(draft.isValid == false)
  }

  @Test func buildTransactionCombinesLegsWithMetadata() {
    var draft = TokenSwapDraft(accountId: accountId)
    draft.sourceInstrument = eth
    draft.sourceQuantity = Decimal(string: "0.5")!
    draft.destinationInstrument = uni
    draft.destinationQuantity = Decimal(string: "1234.56")!
    draft.date = Date()
    draft.notes = "Uniswap swap"

    let transaction = draft.buildTransaction()
    #expect(transaction.legs.count == 2)
    #expect(transaction.notes == "Uniswap swap")
    #expect(transaction.payee == nil)
  }
}
