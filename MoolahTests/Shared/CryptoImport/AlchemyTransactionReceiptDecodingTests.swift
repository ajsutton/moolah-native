// MoolahTests/Shared/CryptoImport/AlchemyTransactionReceiptDecodingTests.swift
import Foundation
import Testing

@testable import Moolah

/// Decoding-level coverage for `AlchemyTransactionReceipt` and the
/// `eth_getTransactionReceipt` wire shape. Exercises the receipt
/// envelope through `LiveAlchemyClient` (the only public surface that
/// constructs the value) so the test path matches production decoding
/// rather than re-implementing the parse out-of-band.
@Suite("AlchemyTransactionReceipt decoding")
struct AlchemyTransactionReceiptDecodingTests {
  private static let ethSendHash =
    "0xabc123def456000000000000000000000000000000000000000000000000aaaa"
  private static let opErc20Hash =
    "0xfeedface00000000000000000000000000000000000000000000000000000001"

  @Test
  func ethSendReceiptDecodesAndComputesTotalGasFee() async throws {
    let fixture = try AlchemyTestSupport.loadFixture("eth-receipt-simple-send")
    let client = AlchemyTestSupport.makeClient { request in
      (AlchemyTestSupport.okResponse(for: request), fixture)
    }

    let receipt = try await client.getTransactionReceipt(
      chain: .ethereum, hash: Self.ethSendHash)

    #expect(receipt.hash == Self.ethSendHash)
    // gasUsed = 0x5208 = 21,000.
    #expect(receipt.gasUsed == Decimal(21_000))
    // effectiveGasPrice = 0x59682f00 = 1,500,000,000 wei (1.5 gwei).
    #expect(receipt.effectiveGasPrice == Decimal(1_500_000_000))
    // 21,000 * 1,500,000,000 = 31,500,000,000,000 wei.
    #expect(receipt.totalGasFeeWei == Decimal(31_500_000_000_000))
  }

  @Test
  func opErc20ReceiptDecodesWithChainSpecificValues() async throws {
    let fixture = try AlchemyTestSupport.loadFixture("op-receipt-erc20-transfer")
    let client = AlchemyTestSupport.makeClient { request in
      (AlchemyTestSupport.okResponse(for: request), fixture)
    }

    let receipt = try await client.getTransactionReceipt(
      chain: .optimism, hash: Self.opErc20Hash)

    // gasUsed = 0xfde8 = 65,000.
    #expect(receipt.gasUsed == Decimal(65_000))
    // effectiveGasPrice = 0xfaaa = 64,170 wei.
    #expect(receipt.effectiveGasPrice == Decimal(64_170))
    // 65,000 * 64,170 = 4,171,050,000 wei.
    #expect(receipt.totalGasFeeWei == Decimal(4_171_050_000))
  }

  @Test
  func nullResultEnvelopeMapsToProviderMalformedResponse() async throws {
    let payload = Data(
      """
      { "jsonrpc": "2.0", "id": 1, "result": null }
      """.utf8)
    let client = AlchemyTestSupport.makeClient { request in
      (AlchemyTestSupport.okResponse(for: request), payload)
    }
    await #expect(throws: WalletSyncError.providerMalformedResponse(stage: "getTransactionReceipt"))
    {
      _ = try await client.getTransactionReceipt(
        chain: .ethereum, hash: "0xnope")
    }
  }

  @Test
  func missingFieldsMapsToProviderMalformedResponse() async throws {
    // Receipt envelope present but `gasUsed` and `effectiveGasPrice`
    // are missing. Decoder must not silently zero them out — a zero
    // gas leg would corrupt the user's ledger.
    let payload = Data(
      """
      {
        "jsonrpc": "2.0",
        "id": 1,
        "result": {
          "transactionHash": "0xnope",
          "blockNumber": "0x1"
        }
      }
      """.utf8)
    let client = AlchemyTestSupport.makeClient { request in
      (AlchemyTestSupport.okResponse(for: request), payload)
    }
    await #expect(throws: WalletSyncError.providerMalformedResponse(stage: "getTransactionReceipt"))
    {
      _ = try await client.getTransactionReceipt(
        chain: .ethereum, hash: "0xnope")
    }
  }

  @Test
  func malformedHexInGasUsedMapsToProviderMalformedResponse() async throws {
    let payload = Data(
      """
      {
        "jsonrpc": "2.0",
        "id": 1,
        "result": {
          "gasUsed": "0xZZZ",
          "effectiveGasPrice": "0x59682f00"
        }
      }
      """.utf8)
    let client = AlchemyTestSupport.makeClient { request in
      (AlchemyTestSupport.okResponse(for: request), payload)
    }
    await #expect(throws: WalletSyncError.providerMalformedResponse(stage: "getTransactionReceipt"))
    {
      _ = try await client.getTransactionReceipt(
        chain: .ethereum, hash: "0xnope")
    }
  }

  @Test
  func unprefixedHexAlsoDecodesForLeniency() async throws {
    // The wire spec mandates 0x prefixes, but a node that omits them
    // shouldn't fail the whole sync — the lenient parser strips the
    // optional prefix and decodes either form.
    let payload = Data(
      """
      {
        "jsonrpc": "2.0",
        "id": 1,
        "result": {
          "gasUsed": "5208",
          "effectiveGasPrice": "59682f00"
        }
      }
      """.utf8)
    let client = AlchemyTestSupport.makeClient { request in
      (AlchemyTestSupport.okResponse(for: request), payload)
    }
    let receipt = try await client.getTransactionReceipt(
      chain: .ethereum, hash: "0xunprefixed")
    #expect(receipt.gasUsed == Decimal(21_000))
    #expect(receipt.effectiveGasPrice == Decimal(1_500_000_000))
  }
}
