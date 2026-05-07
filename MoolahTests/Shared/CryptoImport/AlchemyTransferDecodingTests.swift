// MoolahTests/Shared/CryptoImport/AlchemyTransferDecodingTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("AlchemyTransfer decoding")
struct AlchemyTransferDecodingTests {
  // MARK: - Fixture loading

  private func loadFixture(_ name: String) throws -> Data {
    guard
      let url = Bundle(for: TestBundleMarker.self)
        .url(forResource: name, withExtension: "json")
    else {
      Issue.record("Could not find \(name).json fixture")
      throw FixtureMissing(name: name)
    }
    return try Data(contentsOf: url)
  }

  private struct FixtureMissing: Error { let name: String }

  /// The Alchemy fixtures wrap the array in a JSON-RPC envelope. Tests
  /// that only care about the inner `transfers` array decode through
  /// this helper.
  private func decodeTransfers(_ data: Data) throws -> [AlchemyTransfer] {
    let envelope = try JSONDecoder().decode(JSONRPCFixtureEnvelope.self, from: data)
    return envelope.result.transfers
  }

  // MARK: - Tests

  @Test
  func decodesNativeEthSend() throws {
    let data = try loadFixture("eth-simple-eth-send")
    let transfers = try decodeTransfers(data)
    #expect(transfers.count == 1)
    let transfer = try #require(transfers.first)
    #expect(
      transfer.hash == "0xabc123def456000000000000000000000000000000000000000000000000aaaa")
    #expect(transfer.from == "0x1111111111111111111111111111111111111111")
    #expect(transfer.to == "0x2222222222222222222222222222222222222222")
    #expect(transfer.category == .external)
    #expect(transfer.asset == "ETH")
    #expect(transfer.rawContract.address == nil)
    #expect(transfer.rawContract.decimalsValue == 18)  // 0x12
    #expect(transfer.rawContract.rawDecimalValue == Decimal(0x00b1_a2bc_2ec5_0000))
    #expect(transfer.metadata.blockTimestamp == "2024-09-12T12:34:56.000Z")
    #expect(transfer.blockNum == "0x12d4f0a")
  }

  @Test
  func decodesErc20AndInternalCategories() throws {
    let data = try loadFixture("eth-erc20-transfer")
    let transfers = try decodeTransfers(data)
    #expect(transfers.count == 2)

    let erc20 = transfers[0]
    #expect(erc20.category == .erc20)
    #expect(erc20.asset == "USDC")
    #expect(erc20.rawContract.address == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
    #expect(erc20.rawContract.decimalsValue == 6)
    #expect(erc20.rawContract.rawDecimalValue == Decimal(0x3b9b_ca00))

    let internalTx = transfers[1]
    #expect(internalTx.category == .internal)
    #expect(internalTx.asset == "ETH")
    #expect(internalTx.rawContract.address == nil)
  }

  @Test
  func decodesPolygonSpamAirdropAndUnknownCategoryIsLenient() throws {
    let data = try loadFixture("polygon-spam-airdrop")
    let transfers = try decodeTransfers(data)
    #expect(transfers.count == 2)

    let spam = transfers[0]
    #expect(spam.category == .erc20)
    #expect(spam.asset == "VISIT-AIRDROP-SITE.COM")
    #expect(spam.rawContract.address == "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
    #expect(spam.rawContract.decimalsValue == 18)
    // Decimal must accept 256-bit-scale hex without overflow.
    #expect(spam.rawContract.rawDecimalValue == dec("1000000000000000000000000"))

    // NFT category in real data — the request filter excludes it, but the
    // decoder must not crash if one slips through. We surface it as
    // `.unknown` so callers can drop it.
    let nft = transfers[1]
    #expect(nft.category == .unknown)
    #expect(nft.rawContract.decimalsValue == nil)
  }

  @Test
  func receiveOnlyEventDecodesWithNonNilTo() throws {
    let data = try loadFixture("eth-simple-eth-send")
    let transfers = try decodeTransfers(data)
    let transfer = try #require(transfers.first)
    #expect(transfer.to != nil)
  }

  @Test
  func nullToFieldDecodesAsNil() throws {
    // Alchemy returns `to: null` for contract-creation transactions —
    // the decoder must treat the nil string field as Swift `nil`, not
    // throw or substitute an empty string.
    let json = Data(
      """
      {
        "blockNum": "0x100",
        "uniqueId": "0xaaaa:contract-creation",
        "hash": "0xaaaa",
        "from": "0x1111111111111111111111111111111111111111",
        "to": null,
        "value": null,
        "asset": null,
        "category": "external",
        "rawContract": {
          "value": "0x0",
          "address": null,
          "decimal": null
        },
        "metadata": { "blockTimestamp": "2024-09-12T12:34:56.000Z" }
      }
      """.utf8)
    let transfer = try JSONDecoder().decode(AlchemyTransfer.self, from: json)
    #expect(transfer.to == nil)
    #expect(transfer.asset == nil)
    #expect(transfer.rawContract.decimalsValue == nil)
  }

  @Test
  func categoryEnumLeniencyAcceptsNftCategoriesAsUnknown() throws {
    for raw in ["erc721", "erc1155", "specialnft", "future-category"] {
      let json = Data("\"\(raw)\"".utf8)
      let category = try JSONDecoder().decode(AlchemyTransferCategory.self, from: json)
      #expect(category == .unknown)
    }
  }

  @Test
  func rawContractValueDecodesFromAlchemyKeyValue() throws {
    // Regression: the JSON key for the precise integer-units transfer
    // amount is `value` (inside `rawContract`). An earlier wire format
    // hand-rolled the key as `rawValue` to match the Swift property
    // name, which silently produced `rawDecimalValue == nil` against
    // every real Alchemy response and broke the importer end-to-end —
    // every transfer dropped at `TransferEventBuilder.scaledQuantity`
    // with no user-visible error. This test pins the canonical
    // wire-format key so the regression cannot recur invisibly.
    let json = Data(
      """
      {
        "blockNum": "0x100",
        "uniqueId": "0xcafe:log:0",
        "hash": "0xcafe",
        "from": "0x1111111111111111111111111111111111111111",
        "to": "0x2222222222222222222222222222222222222222",
        "value": 0.5,
        "asset": "ETH",
        "category": "external",
        "rawContract": {
          "value": "0xb1a2bc2ec50000",
          "address": null,
          "decimal": "0x12"
        },
        "metadata": { "blockTimestamp": "2024-09-12T12:34:56.000Z" }
      }
      """.utf8)
    let transfer = try JSONDecoder().decode(AlchemyTransfer.self, from: json)
    #expect(transfer.rawContract.rawDecimalValue == Decimal(0x00b1_a2bc_2ec5_0000))
    #expect(transfer.rawContract.decimalsValue == 18)
  }

  @Test
  func rawContractValueIgnoresLegacyRawValueKey() throws {
    // Defensive: a fixture or upstream wrapper that still emits the old
    // `rawValue` key must NOT be silently parsed — otherwise the bug
    // could hide again behind divergent producer/consumer schemas.
    let json = Data(
      """
      {
        "blockNum": "0x100",
        "uniqueId": "0xbabe:log:0",
        "hash": "0xbabe",
        "from": "0x1111111111111111111111111111111111111111",
        "to": "0x2222222222222222222222222222222222222222",
        "value": null,
        "asset": null,
        "category": "external",
        "rawContract": {
          "rawValue": "0xb1a2bc2ec50000",
          "address": null,
          "decimal": "0x12"
        },
        "metadata": { "blockTimestamp": null }
      }
      """.utf8)
    let transfer = try JSONDecoder().decode(AlchemyTransfer.self, from: json)
    #expect(transfer.rawContract.rawDecimalValue == nil)
  }

  @Test
  func malformedHexFieldsReturnNilInsteadOfThrowing() throws {
    let json = Data(
      """
      {
        "blockNum": "0x100",
        "uniqueId": "0xbbbb:log:0",
        "hash": "0xbbbb",
        "from": "0x1",
        "to": "0x2",
        "category": "erc20",
        "rawContract": {
          "value": "0xZZZ",
          "address": "0xabc",
          "decimal": "not-hex"
        },
        "metadata": { "blockTimestamp": null }
      }
      """.utf8)
    let transfer = try JSONDecoder().decode(AlchemyTransfer.self, from: json)
    #expect(transfer.rawContract.rawDecimalValue == nil)
    #expect(transfer.rawContract.decimalsValue == nil)
  }
}

// MARK: - Fixture envelope

/// Mirrors the JSON-RPC envelope shape from the production decoder; defined
/// here so tests don't reach into `LiveAlchemyClient`'s `private` types.
private struct JSONRPCFixtureEnvelope: Decodable {
  let result: Result

  struct Result: Decodable {
    let transfers: [AlchemyTransfer]
  }
}
