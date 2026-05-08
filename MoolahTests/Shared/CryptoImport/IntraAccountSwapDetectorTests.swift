// MoolahTests/Shared/CryptoImport/IntraAccountSwapDetectorTests.swift
import Foundation
import Testing

@testable import Moolah

/// Pure unit tests for `IntraAccountSwapDetector`. The detector is a
/// total `[DirectionalLeg] → [TransactionLeg]` function with no async,
/// no fixtures beyond constructed legs — every test calls the helper
/// directly and asserts on the returned types.
@Suite("IntraAccountSwapDetector")
struct IntraAccountSwapDetectorTests {
  private static let accountId = UUID(
    uuidString: "00000000-0000-0000-0000-00000000A111")!
  private static let ethereum = ChainConfig.ethereum.nativeInstrument
  private static let polygon = ChainConfig.polygon.nativeInstrument
  private static let base = ChainConfig.base.nativeInstrument

  @Test("2-token swap (1 in, 1 out, distinct instruments) → both retyped to .trade")
  func twoTokenSwapRetypesBothLegs() {
    let inbound = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.ethereum,
        quantity: 10,
        externalId: "0xhash:0",
        counterpartyAddress: "0xrouter",
        type: .income),
      direction: .inbound)
    let outbound = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.polygon,
        quantity: -20,
        externalId: "0xhash:1",
        counterpartyAddress: "0xrouter",
        type: .expense),
      direction: .outbound)

    let result = IntraAccountSwapDetector.retypeSwapLegs([inbound, outbound])

    #expect(result.count == 2)
    #expect(result.allSatisfy { $0.type == .trade })
  }

  @Test("Pure inbound (no outbound) → unchanged")
  func pureInboundUnchanged() {
    let inbound = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.ethereum,
        quantity: 10,
        externalId: "0xhash:0",
        type: .income),
      direction: .inbound)

    let result = IntraAccountSwapDetector.retypeSwapLegs([inbound])

    #expect(result.count == 1)
    #expect(result.first?.type == .income)
  }

  @Test("Pure outbound (no inbound) → unchanged")
  func pureOutboundUnchanged() {
    let outbound = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.ethereum,
        quantity: -10,
        externalId: "0xhash:0",
        type: .expense),
      direction: .outbound)

    let result = IntraAccountSwapDetector.retypeSwapLegs([outbound])

    #expect(result.count == 1)
    #expect(result.first?.type == .expense)
  }

  @Test("Same instrument both sides (no third token) → unchanged")
  func sameInstrumentBothSidesUnchanged() {
    let inbound = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.ethereum,
        quantity: 100,
        externalId: "0xhash:0",
        type: .income),
      direction: .inbound)
    let outbound = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.ethereum,
        quantity: -50,
        externalId: "0xhash:1",
        type: .expense),
      direction: .outbound)

    let result = IntraAccountSwapDetector.retypeSwapLegs([inbound, outbound])

    #expect(result.count == 2)
    #expect(result.map(\.type) == [.income, .expense])
  }

  @Test("Empty input → empty output")
  func emptyInputUnchanged() {
    let result = IntraAccountSwapDetector.retypeSwapLegs([])
    #expect(result.isEmpty)
  }

  @Test("3-leg basket trade (1 in, 2 out, 3 instruments) → all retyped to .trade")
  func threeLegBasketTradeRetypesAll() {
    let inbound = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.ethereum,
        quantity: 5,
        externalId: "0xhash:0",
        type: .income),
      direction: .inbound)
    let outboundA = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.polygon,
        quantity: -10,
        externalId: "0xhash:1",
        type: .expense),
      direction: .outbound)
    let outboundB = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.base,
        quantity: -3,
        externalId: "0xhash:2",
        type: .expense),
      direction: .outbound)

    let result = IntraAccountSwapDetector.retypeSwapLegs([inbound, outboundA, outboundB])

    #expect(result.count == 3)
    #expect(result.allSatisfy { $0.type == .trade })
  }

  @Test("LP add shape (2 outbound, 1 inbound LP token) → all retyped to .trade")
  func lpAddShapeRetypesAll() {
    let outboundA = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.ethereum,
        quantity: -1,
        externalId: "0xhash:0",
        type: .expense),
      direction: .outbound)
    let outboundB = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.polygon,
        quantity: -100,
        externalId: "0xhash:1",
        type: .expense),
      direction: .outbound)
    let inboundLP = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.base,
        quantity: 1,
        externalId: "0xhash:2",
        type: .income),
      direction: .inbound)

    let result = IntraAccountSwapDetector.retypeSwapLegs([outboundA, outboundB, inboundLP])

    #expect(result.count == 3)
    #expect(result.allSatisfy { $0.type == .trade })
  }
}
