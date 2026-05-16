// MoolahTests/Shared/CryptoImport/TransferEventBuilderGasLegL1FeeTests.swift
import Foundation
import Testing

@testable import Moolah

/// OP-stack L1 data-fee coverage for the gas-leg construction (#920).
/// Split out of `TransferEventBuilderGasLegTests` because the L1
/// data-fee behaviour is a distinct concern (chain-gated fee
/// composition) from the base gas-leg / coalescing / attribution
/// suites, and keeping it separate keeps each suite focused.
@Suite("TransferEventBuilder — gas leg L1 data fee")
struct TransferEventBuilderGasLegL1FeeTests {
  private static let wallet = "0x1111111111111111111111111111111111111111"
  private static let counterparty = "0x2222222222222222222222222222222222222222"

  // 21_000 gas * 1.5 gwei = 31_500_000_000_000 wei = 0.0000315 ETH (L2).
  private static let gasUsed = Decimal(21_000)
  private static let gasPrice = Decimal(1_500_000_000)
  private static let expectedFeeEth = dec("0.0000315")

  // 80_000_000_000_000 wei = 0.00008 ETH L1 data fee. Added on top of
  // the 0.0000315 ETH L2 execution fee → 0.0001115 ETH total.
  private static let l1FeeWei = Decimal(80_000_000_000_000)
  private static let expectedFeeWithL1Eth = dec("0.0001115")

  @Test("OP-stack outbound → gas leg includes L1 data fee (L2 + l1Fee)")
  func opStackGasLegIncludesL1DataFee() async throws {
    let subject = makeDiscoverySubject()
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: "0xop-send",
          gasUsed: Self.gasUsed,
          effectiveGasPrice: Self.gasPrice,
          from: Self.wallet,
          l1FeeWei: Self.l1FeeWei)
      ),
      for: "0xop-send")

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .optimism)
    let origin = makeWalletImportOrigin(for: account.id)
    let transfer = makeAlchemyTransfer(
      hash: "0xop-send",
      from: Self.wallet,
      to: Self.counterparty,
      category: .external)

    let built = try await TransferEventBuilder().build(
      transfers: [transfer],
      account: account,
      services: BuilderServices(
        chain: .optimism,
        discovery: subject.service,
        alchemy: alchemy),
      importOrigin: origin)

    let candidate = try #require(built.first)
    let gasLeg = try #require(
      candidate.transaction.legs.first(where: { $0.externalId == "0xop-send:gas" }))
    #expect(gasLeg.instrument == ChainConfig.optimism.nativeInstrument)
    #expect(gasLeg.quantity == -Self.expectedFeeWithL1Eth)
  }

  @Test("L1 chain ignores stray l1FeeWei → gas leg is L2-only")
  func l1ChainIgnoresL1DataFee() async throws {
    // Defensive: even if a receipt somehow carries `l1FeeWei` on a
    // non-OP-stack chain, the gas leg must stay L2-only — inclusion is
    // gated by `chain.chargesL1DataFee`.
    let subject = makeDiscoverySubject()
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: "0xeth-send",
          gasUsed: Self.gasUsed,
          effectiveGasPrice: Self.gasPrice,
          from: Self.wallet,
          l1FeeWei: Self.l1FeeWei)
      ),
      for: "0xeth-send")

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let transfer = makeAlchemyTransfer(
      hash: "0xeth-send",
      from: Self.wallet,
      to: Self.counterparty,
      category: .external)

    let built = try await TransferEventBuilder().build(
      transfers: [transfer],
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: alchemy),
      importOrigin: origin)

    let candidate = try #require(built.first)
    let gasLeg = try #require(
      candidate.transaction.legs.first(where: { $0.externalId == "0xeth-send:gas" }))
    #expect(gasLeg.quantity == -Self.expectedFeeEth)
  }

  @Test("OP-stack receipt missing l1Fee → gas leg still built from L2 only")
  func opStackReceiptMissingL1FeeFallsBackToL2() async throws {
    // Anomaly path: an OP-stack receipt should always carry l1Fee, but
    // if it doesn't the leg must still be built from the L2 portion
    // (an under-counted expense beats silently dropping it). The
    // coalescer logs the anomaly; behaviour, not the log line, is
    // asserted here.
    let subject = makeDiscoverySubject()
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: "0xop-no-l1",
          gasUsed: Self.gasUsed,
          effectiveGasPrice: Self.gasPrice,
          from: Self.wallet)
      ),
      for: "0xop-no-l1")

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .optimism)
    let origin = makeWalletImportOrigin(for: account.id)
    let transfer = makeAlchemyTransfer(
      hash: "0xop-no-l1",
      from: Self.wallet,
      to: Self.counterparty,
      category: .external)

    let built = try await TransferEventBuilder().build(
      transfers: [transfer],
      account: account,
      services: BuilderServices(
        chain: .optimism,
        discovery: subject.service,
        alchemy: alchemy),
      importOrigin: origin)

    let candidate = try #require(built.first)
    let gasLeg = try #require(
      candidate.transaction.legs.first(where: { $0.externalId == "0xop-no-l1:gas" }))
    #expect(gasLeg.quantity == -Self.expectedFeeEth)
  }
}
