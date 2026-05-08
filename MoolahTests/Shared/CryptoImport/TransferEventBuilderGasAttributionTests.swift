// MoolahTests/Shared/CryptoImport/TransferEventBuilderGasAttributionTests.swift
import Foundation
import Testing

@testable import Moolah

/// Coverage for the gas-attribution gating predicate that suppresses
/// the `:gas` leg when the wallet did not sign the outer tx. Split out
/// of `TransferEventBuilderGasLegTests` so each suite stays inside
/// SwiftLint's `type_body_length` budget. The two real-world
/// misattribution paths covered here are:
///
/// - An `internal` sub-call inside someone else's tx where the wallet
///   appears as `from` of the inner call (not the outer signer).
/// - An ERC-20 `transferFrom(wallet, …)` initiated by a router or
///   third-party contract holding prior approval — Alchemy reports the
///   row with `from = wallet`, but the wallet did not sign the tx.
///
/// In both cases `receipt.from != walletAddress`, and
/// `TransferReceiptCoalescer.makeGasLeg` returns `nil`. The transfer
/// leg is still produced; only the gas leg is suppressed.
@Suite("TransferEventBuilder — gas attribution gating")
struct TransferEventBuilderGasAttributionTests {
  private static let wallet = "0x1111111111111111111111111111111111111111"
  private static let counterparty = "0x2222222222222222222222222222222222222222"
  private static let usdcAddress = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"

  private static let gasUsed = Decimal(21_000)
  private static let gasPrice = Decimal(1_500_000_000)

  // MARK: - Outer-tx signed by someone else → no gas leg

  @Test(
    "Internal transfer where wallet appears as `from` but receipt.from is counterparty → no gas leg"
  )
  func internalTransferSignedBySomeoneElseDoesNotEmitGasLeg() async throws {
    let subject = makeDiscoverySubject()
    let alchemy = RecordingAlchemyClientStub()
    // Receipt is fetched (the outboundHashes heuristic still trips on
    // `from == wallet` for any non-NFT transfer), but the EOA that
    // signed the tx is the counterparty — wallet did not pay gas.
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: "0xinternal",
          gasUsed: Self.gasUsed,
          effectiveGasPrice: Self.gasPrice,
          from: Self.counterparty)
      ),
      for: "0xinternal")

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    // Wallet is `from` of an `internal` sub-call inside someone else's
    // outer tx. Real example: a contract Alice called moves wallet's
    // funds via a prior approval / delegate.
    let transfer = makeAlchemyTransfer(
      hash: "0xinternal",
      from: Self.wallet,
      to: Self.counterparty,
      category: .internal)

    let built = try await TransferEventBuilder().build(
      transfers: [transfer],
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: alchemy),
      importOrigin: origin)

    let candidate = try #require(built.first)
    // Transfer leg still produced; gas leg is suppressed.
    #expect(candidate.transaction.legs.count == 1)
    #expect(
      candidate.transaction.legs.allSatisfy {
        $0.externalId?.hasSuffix(":gas") == false
      })
    // The receipt fetch still happened — gating is post-fetch, by design.
    #expect(alchemy.recordedReceiptCalls == ["0xinternal"])
  }

  @Test("ERC-20 row where wallet is `from` but receipt.from is a router → no gas leg")
  func erc20TransferFromWhereRouterSignedDoesNotEmitGasLeg() async throws {
    let subject = makeDiscoverySubject()
    // ERC-20 needs the discovery resolver scripted (USDC).
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .success(coingecko: "usd-coin", cryptocompare: nil, binance: nil))
    let alchemy = RecordingAlchemyClientStub()
    // Outer tx signed by the router — a third-party EOA / contract that
    // had prior approval to move wallet's USDC. Wallet did not pay gas.
    let routerSigner = "0x3333333333333333333333333333333333333333"
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: "0xtransferfrom",
          gasUsed: Self.gasUsed,
          effectiveGasPrice: Self.gasPrice,
          from: routerSigner)
      ),
      for: "0xtransferfrom")

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    // ERC-20 row: wallet is the token `from` (token holder), but the
    // EOA that signed the on-chain tx (and paid gas) is the router.
    let transfer = makeAlchemyTransfer(
      hash: "0xtransferfrom",
      from: Self.wallet,
      to: Self.counterparty,
      category: .erc20,
      asset: "USDC",
      contractAddress: Self.usdcAddress,
      decimalsHex: "0x6",
      rawValueHex: "0x5f5e100")

    let built = try await TransferEventBuilder().build(
      transfers: [transfer],
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: alchemy),
      importOrigin: origin)

    let candidate = try #require(built.first)
    // Transfer leg still produced; gas leg suppressed.
    #expect(candidate.transaction.legs.count == 1)
    #expect(
      candidate.transaction.legs.allSatisfy {
        $0.externalId?.hasSuffix(":gas") == false
      })
    #expect(alchemy.recordedReceiptCalls == ["0xtransferfrom"])
  }
}
