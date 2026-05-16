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
    #expect(tx.hash.hasPrefix("0x"))
    #expect(tx.blockNumber > 0)
    #expect(tx.from.hash.hasPrefix("0x"))
    #expect(tx.value != "0")
    #expect(tx.timestamp != nil)
    #expect(tx.isSuccess == true)
  }

  @Test
  func decodesApproveAsZeroValueSuccess() throws {
    let page = try decodeTxPage("blockscout-tx-approve")
    let tx = try #require(page.items.first)
    #expect(tx.value == "0")
    #expect(tx.isSuccess == true)
    #expect(tx.to?.hash != nil)
  }

  @Test
  func decodesFailedTransaction() throws {
    let page = try decodeTxPage("blockscout-tx-failed")
    let tx = try #require(page.items.first)
    #expect(tx.isSuccess == false)
  }

  @Test
  func decodesInternalTransfersWithPageCursor() throws {
    let data = try AlchemyTestSupport.loadFixture("blockscout-internal")
    let page = try JSONDecoder().decode(BlockscoutInternalTxPage.self, from: data)
    let itx = try #require(page.items.first)
    #expect(itx.transactionHash.hasPrefix("0x"))
    #expect(itx.value != "0")
    #expect(itx.index >= 0)
    #expect(page.nextPageParams != nil)
  }

  @Test
  func missingNextPageParamsDecodesAsNil() throws {
    let json = #"{"items":[],"next_page_params":null}"#.data(using: .utf8)!
    let page = try JSONDecoder().decode(BlockscoutTransactionsPage.self, from: json)
    #expect(page.items.isEmpty)
    #expect(page.nextPageParams == nil)
  }
}
