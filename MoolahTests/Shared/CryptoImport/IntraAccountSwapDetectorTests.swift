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
}
