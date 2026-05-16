// MoolahTests/Shared/CryptoImport/BlockscoutTransferAdapterTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("BlockscoutTransferAdapter")
struct BlockscoutTransferAdapterTests {
  private let wallet = "0xa4b572ea1b6f734fc88a0a004c5301f8dad54d60"

  private func tx(
    hash: String, from: String, to: String?, value: String,
    block: Int = 100, success: Bool = true
  ) -> BlockscoutTransaction {
    BlockscoutTransaction(
      hash: hash, blockNumber: block,
      timestamp: "2024-09-12T12:34:56.000000Z",
      from: .init(hash: from), to: to.map { .init(hash: $0) },
      value: value, status: success ? "ok" : "error",
      result: success ? "success" : "reverted")
  }

  private func itx(
    parent: String, from: String, to: String?, value: String, index: Int
  ) -> BlockscoutInternalTx {
    BlockscoutInternalTx(
      transactionHash: parent, blockNumber: 100,
      timestamp: "2024-09-12T12:34:56.000000Z",
      from: .init(hash: from), to: to.map { .init(hash: $0) },
      value: value, index: index, success: true)
  }

  @Test
  func outboundValueTxBecomesExternalTransferAndSignedGasTx() throws {
    let result = BlockscoutTransferAdapter.adapt(
      nativeTxs: [tx(hash: "0xH1", from: wallet, to: "0xDEF", value: "1000000000000000000")],
      internalTxs: [],
      walletAddress: wallet)
    let t = try #require(result.transfers.first)
    #expect(result.transfers.count == 1)
    #expect(t.category == .external)
    #expect(t.uniqueId == "0xH1:external:0")
    #expect(t.from.lowercased() == wallet)
    #expect(t.to == "0xDEF")
    #expect(t.rawContract.address == nil)
    #expect(t.rawContract.rawValue == "0xde0b6b3a7640000")  // 1e18 wei
    #expect(t.blockNum == "0x64")  // 100
    #expect(t.metadata.blockTimestamp == "2024-09-12T12:34:56.000000Z")
    #expect(result.signedGasTxs.map(\.hash) == ["0xH1"])
  }

  @Test
  func zeroValueApproveYieldsNoTransferButIsSignedGasTx() {  // #919
    let result = BlockscoutTransferAdapter.adapt(
      nativeTxs: [tx(hash: "0xAP", from: wallet, to: "0xTOKEN", value: "0")],
      internalTxs: [],
      walletAddress: wallet)
    #expect(result.transfers.isEmpty)
    #expect(result.signedGasTxs.count == 1)
    #expect(result.signedGasTxs.first?.hash == "0xAP")
  }

  @Test
  func failedTxStillCountsAsSignedGasTx() {  // #919
    let result = BlockscoutTransferAdapter.adapt(
      nativeTxs: [tx(hash: "0xFA", from: wallet, to: "0xC", value: "0", success: false)],
      internalTxs: [],
      walletAddress: wallet)
    #expect(result.transfers.isEmpty)
    #expect(result.signedGasTxs.map(\.hash) == ["0xFA"])
  }

  @Test
  func failedTxWithNonZeroValueIsNotATransferButIsSignedGasTx() {
    // A failed/reverted tx still paid gas (#919) but did NOT move value —
    // the value field reflects the attempted amount, not an actual transfer.
    let result = BlockscoutTransferAdapter.adapt(
      nativeTxs: [
        tx(hash: "0xFV", from: wallet, to: "0xC", value: "500000000000000000", success: false)
      ],
      internalTxs: [],
      walletAddress: wallet)
    #expect(result.transfers.isEmpty)
    #expect(result.signedGasTxs.map(\.hash) == ["0xFV"])
  }

  @Test
  func inboundValueTxIsExternalTransferButNotSignedGasTx() {
    let result = BlockscoutTransferAdapter.adapt(
      nativeTxs: [tx(hash: "0xIN", from: "0xSENDER", to: wallet, value: "5")],
      internalTxs: [],
      walletAddress: wallet)
    #expect(result.transfers.first?.category == .external)
    #expect(result.transfers.first?.to?.lowercased() == wallet)
    #expect(result.signedGasTxs.isEmpty)  // wallet did not sign
  }

  @Test
  func internalCreditBecomesInternalTransfer() throws {  // #918
    let result = BlockscoutTransferAdapter.adapt(
      nativeTxs: [],
      internalTxs: [itx(parent: "0xP", from: "0xROUTER", to: wallet, value: "777", index: 3)],
      walletAddress: wallet)
    let t = try #require(result.transfers.first)
    #expect(t.category == .internal)
    #expect(t.hash == "0xP")
    #expect(t.uniqueId == "0xP:internal:3")
    #expect(t.to?.lowercased() == wallet)
    #expect(result.signedGasTxs.isEmpty)
  }

  @Test
  func multipleInternalMovesInOneParentGetDistinctIds() {
    let result = BlockscoutTransferAdapter.adapt(
      nativeTxs: [],
      internalTxs: [
        itx(parent: "0xP", from: "0xR", to: wallet, value: "1", index: 0),
        itx(parent: "0xP", from: "0xR", to: wallet, value: "2", index: 1),
      ],
      walletAddress: wallet)
    #expect(Set(result.transfers.map(\.uniqueId)) == ["0xP:internal:0", "0xP:internal:1"])
  }

  @Test
  func zeroValueInternalIsDropped() {
    let result = BlockscoutTransferAdapter.adapt(
      nativeTxs: [],
      internalTxs: [itx(parent: "0xP", from: "0xR", to: wallet, value: "0", index: 0)],
      walletAddress: wallet)
    #expect(result.transfers.isEmpty)
  }

  @Test
  func failedInternalWithNonZeroValueIsDropped() {
    // Failed internal calls report the attempted value but did not move it.
    let itxFailed = BlockscoutInternalTx(
      transactionHash: "0xPI", blockNumber: 100,
      timestamp: "2024-09-12T12:34:56.000000Z",
      from: .init(hash: "0xROUTER"), to: .init(hash: wallet),
      value: "300000000000000000", index: 0, success: false)
    let result = BlockscoutTransferAdapter.adapt(
      nativeTxs: [],
      internalTxs: [itxFailed],
      walletAddress: wallet)
    #expect(result.transfers.isEmpty)
  }

  @Test
  func checksummedWalletMatchesLowercaseRows() {
    let result = BlockscoutTransferAdapter.adapt(
      nativeTxs: [tx(hash: "0xH", from: wallet.uppercased(), to: "0xD", value: "9")],
      internalTxs: [],
      walletAddress: wallet)
    #expect(result.signedGasTxs.map(\.hash) == ["0xH"])
  }

  @Test
  func decimalWeiToHexConversionIsExact() {
    #expect(BlockscoutTransferAdapter.decimalStringToHexWei("0") == "0x0")
    #expect(BlockscoutTransferAdapter.decimalStringToHexWei("1") == "0x1")
    #expect(BlockscoutTransferAdapter.decimalStringToHexWei("255") == "0xff")
    #expect(
      BlockscoutTransferAdapter.decimalStringToHexWei("1000000000000000000") == "0xde0b6b3a7640000")
    #expect(BlockscoutTransferAdapter.decimalStringToHexWei("abc") == nil)
    #expect(BlockscoutTransferAdapter.decimalStringToHexWei("") == nil)
  }
}
