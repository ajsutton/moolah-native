// MoolahTests/Shared/CryptoImport/SwapDetectorPreservationTests.swift
import Foundation
import Testing

@testable import Moolah

/// Field-, order-, and self-send-preservation tests for
/// `IntraAccountSwapDetector`. Lives in its own file so the predicate-
/// logic suite (`IntraAccountSwapDetectorTests`) stays under SwiftLint's
/// `type_body_length` budget. Asserts that the only field the detector
/// rewrites is `type`, that input order survives a retype, and that
/// self-send legs are never partitioned into the swap predicate.
@Suite("IntraAccountSwapDetector — preservation")
struct SwapDetectorPreservationTests {
  private static let accountId = makeUUID("AAAAAAAA-0000-0000-0000-000000000002")
  private static let ethereum = ChainConfig.ethereum.nativeInstrument
  private static let polygon = ChainConfig.polygon.nativeInstrument
  private static let base = ChainConfig.base.nativeInstrument

  @Test("Self-send + swap pair → self-send stays .income, swap legs retyped")
  func selfSendCoexistsWithSwap() {
    let selfSend = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.ethereum,
        quantity: 5,
        externalId: "0xhash:0",
        counterpartyAddress: nil,
        type: .income),
      direction: .selfSend)
    let inbound = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.polygon,
        quantity: 10,
        externalId: "0xhash:1",
        counterpartyAddress: "0xrouter",
        type: .income),
      direction: .inbound)
    let outbound = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.base,
        quantity: -1,
        externalId: "0xhash:2",
        counterpartyAddress: "0xrouter",
        type: .expense),
      direction: .outbound)

    let result = IntraAccountSwapDetector.retypeSwapLegs([selfSend, inbound, outbound])

    #expect(result.count == 3)
    // Order preserved: selfSend at [0], inbound at [1], outbound at [2].
    #expect(result[0].type == .income)
    #expect(result[1].type == .trade)
    #expect(result[2].type == .trade)
  }

  @Test("Self-send only (no inbound or outbound) → unchanged")
  func selfSendOnlyUnchanged() {
    let selfSend = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.ethereum,
        quantity: 5,
        externalId: "0xhash:0",
        type: .income),
      direction: .selfSend)

    let result = IntraAccountSwapDetector.retypeSwapLegs([selfSend])

    #expect(result.count == 1)
    #expect(result.first?.type == .income)
  }

  @Test("Field preservation: id, externalId, counterparty, category, earmark, quantity")
  func retypePreservesEveryFieldExceptType() throws {
    let categoryId = UUID()
    let earmarkId = UUID()
    let inboundId = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    let outboundId = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
    let inbound = DirectionalLeg(
      leg: TransactionLeg(
        id: inboundId,
        accountId: Self.accountId,
        instrument: Self.ethereum,
        quantity: 10,
        externalId: "0xhash:0",
        counterpartyAddress: "0xrouter-in",
        type: .income,
        categoryId: categoryId,
        earmarkId: earmarkId),
      direction: .inbound)
    let outbound = DirectionalLeg(
      leg: TransactionLeg(
        id: outboundId,
        accountId: Self.accountId,
        instrument: Self.polygon,
        quantity: -20,
        externalId: "0xhash:1",
        counterpartyAddress: "0xrouter-out",
        type: .expense),
      direction: .outbound)

    let result = IntraAccountSwapDetector.retypeSwapLegs([inbound, outbound])

    #expect(result.count == 2)
    let inboundResult = try #require(result.first { $0.id == inboundId })
    #expect(inboundResult.type == .trade)
    #expect(inboundResult.accountId == Self.accountId)
    #expect(inboundResult.instrument == Self.ethereum)
    #expect(inboundResult.quantity == Decimal(10))
    #expect(inboundResult.externalId == "0xhash:0")
    #expect(inboundResult.counterpartyAddress == "0xrouter-in")
    #expect(inboundResult.categoryId == categoryId)
    #expect(inboundResult.earmarkId == earmarkId)

    let outboundResult = try #require(result.first { $0.id == outboundId })
    #expect(outboundResult.type == .trade)
    #expect(outboundResult.quantity == Decimal(-20))
    #expect(outboundResult.counterpartyAddress == "0xrouter-out")
  }

  @Test("Input order is preserved on the output")
  func orderPreserved() {
    let outbound = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.polygon,
        quantity: -20,
        externalId: "0xhash:0",
        type: .expense),
      direction: .outbound)
    let inbound = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.ethereum,
        quantity: 10,
        externalId: "0xhash:1",
        type: .income),
      direction: .inbound)

    let result = IntraAccountSwapDetector.retypeSwapLegs([outbound, inbound])

    #expect(result.count == 2)
    #expect(result[0].externalId == "0xhash:0")  // outbound first
    #expect(result[1].externalId == "0xhash:1")  // inbound second
    #expect(result.allSatisfy { $0.type == .trade })
  }
}
