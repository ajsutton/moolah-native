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

  // MARK: - Multi-instrument swap scenarios

  @Test func crossChainSwapPreservesChainIdsOnEachLeg() {
    // ETH on chain 1 swapped for a token on chain 137 (Polygon).
    let polyUsdc = Instrument.crypto(
      chainId: 137,
      contractAddress: "0x2791bca1f2de4661ed88a30c99a7a9449aa84174",
      symbol: "USDC", name: "USD Coin", decimals: 6
    )
    var draft = TokenSwapDraft(accountId: accountId)
    draft.sourceInstrument = eth
    draft.sourceQuantity = Decimal(string: "0.5")!
    draft.destinationInstrument = polyUsdc
    draft.destinationQuantity = Decimal(string: "800")!
    draft.date = Date()

    let legs = draft.buildLegs()
    #expect(legs.count == 2)
    #expect(legs[0].instrument.chainId == 1)
    #expect(legs[1].instrument.chainId == 137)
    #expect(legs[0].instrument.contractAddress == nil)
    #expect(legs[1].instrument.contractAddress != nil)
  }

  @Test func gasFeeInInstrumentDifferentFromSourceAndDestinationIsLegged() {
    // Swap UNI for a hypothetical token on chain 1, fee in ETH (native gas).
    let dai = Instrument.crypto(
      chainId: 1,
      contractAddress: "0x6b175474e89094c44da98b954eedeac495271d0f",
      symbol: "DAI", name: "Dai", decimals: 18
    )
    var draft = TokenSwapDraft(accountId: accountId)
    draft.sourceInstrument = uni
    draft.sourceQuantity = Decimal(string: "100")!
    draft.destinationInstrument = dai
    draft.destinationQuantity = Decimal(string: "600")!
    draft.gasFeeInstrument = eth
    draft.gasFeeQuantity = Decimal(string: "0.003")!
    draft.date = Date()

    let legs = draft.buildLegs()
    #expect(legs.count == 3)
    let instruments = Set(legs.map { $0.instrument.id })
    #expect(instruments.count == 3)
    let feeLeg = legs[2]
    #expect(feeLeg.instrument == eth)
    #expect(feeLeg.quantity == Decimal(string: "-0.003")!)
    #expect(feeLeg.type == .expense)
  }

  @Test func swapPreservesHighDecimalPrecisionOnBothSides() {
    // Source has 18-decimal ETH, destination has 6-decimal USDC.
    let usdc = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC", name: "USD Coin", decimals: 6
    )
    var draft = TokenSwapDraft(accountId: accountId)
    draft.sourceInstrument = eth
    draft.sourceQuantity = Decimal(string: "0.12345678")!
    draft.destinationInstrument = usdc
    draft.destinationQuantity = Decimal(string: "200.001234")!
    draft.date = Date()

    let legs = draft.buildLegs()
    #expect(legs[0].instrument.decimals == 18)
    #expect(legs[0].quantity == Decimal(string: "-0.12345678")!)
    #expect(legs[1].instrument.decimals == 6)
    #expect(legs[1].quantity == Decimal(string: "200.001234")!)
  }
}
