// MoolahTests/Shared/CryptoImport/BlockscoutWireFormatDecodingTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("Blockscout wire-format decoding")
struct BlockscoutWireFormatDecodingTests {
  private func decodeTxPage(_ fixture: String) throws -> BlockscoutTransactionsPage {
    let data = try AlchemyTestSupport.loadFixture(fixture)
    return try JSONDecoder().decode(BlockscoutTransactionsPage.self, from: data)
  }

  @Test
  func decodesValueTransaction() throws {
    let page = try decodeTxPage("blockscout-tx-value")
    let tx = try #require(page.items.first)
    #expect(tx.hash == "0x7ce005a7bc9ca2d793ee9e57426f4103b06c2d02e8505f791b2291d9aa202df1")
    #expect(tx.blockNumber == 19_002_820)
    #expect(tx.value == "90000000000000000")
    #expect(tx.timestamp != nil)
    #expect(tx.isSuccess == true)
  }

  @Test
  func decodesApproveAsZeroValueSuccess() throws {
    let page = try decodeTxPage("blockscout-tx-approve")
    let tx = try #require(page.items.first)
    #expect(tx.blockNumber == 21_833_612)
    #expect(tx.value == "0")
    #expect(tx.isSuccess == true)
    #expect(tx.to != nil)
  }

  @Test
  func decodesFailedTransaction() throws {
    let page = try decodeTxPage("blockscout-tx-failed")
    let tx = try #require(page.items.first)
    #expect(tx.isSuccess == false)
  }

  @Test
  func decodesInternalTransfer() throws {
    let data = try AlchemyTestSupport.loadFixture("blockscout-internal")
    let page = try JSONDecoder().decode(BlockscoutInternalTxPage.self, from: data)
    let itx = try #require(page.items.first)
    #expect(
      itx.transactionHash
        == "0x039e6d039d65a078bdd90df9e27e73efae745e26ddb32fae42ac99e1f1da55c3")
    #expect(itx.value == "809501222242281153")
    #expect(itx.index == 12)
    #expect(itx.success)
  }

  @Test
  func decodesPageCursorPresent() throws {
    let data = try AlchemyTestSupport.loadFixture("blockscout-internal")
    let page = try JSONDecoder().decode(BlockscoutInternalTxPage.self, from: data)
    #expect(page.nextPageParams != nil)
    #expect(page.nextPageParams?.blockNumber == 21_298_374)
  }

  @Test
  func missingNextPageParamsDecodesAsNil() throws {
    let json = try #require(#"{"items":[],"next_page_params":null}"#.data(using: .utf8))
    let page = try JSONDecoder().decode(BlockscoutTransactionsPage.self, from: json)
    #expect(page.items.isEmpty)
    #expect(page.nextPageParams == nil)
  }
}
