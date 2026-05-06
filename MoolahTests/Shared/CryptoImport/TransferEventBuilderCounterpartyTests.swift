// MoolahTests/Shared/CryptoImport/TransferEventBuilderCounterpartyTests.swift
import Foundation
import Testing

@testable import Moolah

/// Behavioural tests for `TransferEventBuilder`'s `counterpartyAddress`
/// population. Covers the four-quadrant truth table described in the
/// builder doc: outbound = `to`, inbound = `from`, self-send = `nil`.
///
/// The "gas leg = nil" case is implicit: gas legs aren't built by this
/// stage (deferred to issue #762), so there is nothing to verify here.
/// When the receipt-fetch wiring lands, that test belongs alongside the
/// gas-leg construction test in the same suite.
@Suite("TransferEventBuilder counterpartyAddress")
struct TransferEventBuilderCounterpartyTests {
  // Reusable addresses. Mixed-case wallet so we also verify the lowercase
  // canonicalisation the builder applies.
  private static let walletMixedCase = "0xAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAa"
  private static let walletLowercase = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  private static let counterparty = "0x2222222222222222222222222222222222222222"

  @Test("Outbound transfer → counterparty is the `to` address (lowercased)")
  func outboundUsesToAddressAsCounterparty() async throws {
    let subject = makeDiscoverySubject()
    let account = makeCryptoAccount(walletAddress: Self.walletMixedCase, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let transfer = makeAlchemyTransfer(
      hash: "0xout",
      from: Self.walletLowercase,
      to: Self.counterparty,
      category: .external)

    let built = try await TransferEventBuilder().build(
      transfers: [transfer],
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: ZeroReceiptAlchemyStub()),
      importOrigin: origin)
    let leg = try #require(built.first?.transaction.legs.first)
    #expect(leg.counterpartyAddress == Self.counterparty)
  }

  @Test("Inbound transfer → counterparty is the `from` address (lowercased)")
  func inboundUsesFromAddressAsCounterparty() async throws {
    let subject = makeDiscoverySubject()
    let account = makeCryptoAccount(walletAddress: Self.walletMixedCase, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let transfer = makeAlchemyTransfer(
      hash: "0xin",
      from: Self.counterparty,
      to: Self.walletLowercase,
      category: .external)

    let built = try await TransferEventBuilder().build(
      transfers: [transfer],
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: ZeroReceiptAlchemyStub()),
      importOrigin: origin)
    let leg = try #require(built.first?.transaction.legs.first)
    #expect(leg.counterpartyAddress == Self.counterparty)
  }

  @Test("Self-send → counterparty is nil")
  func selfSendHasNilCounterparty() async throws {
    let subject = makeDiscoverySubject()
    let account = makeCryptoAccount(walletAddress: Self.walletMixedCase, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let transfer = makeAlchemyTransfer(
      hash: "0xself",
      from: Self.walletLowercase,
      to: Self.walletLowercase,
      category: .external)

    let built = try await TransferEventBuilder().build(
      transfers: [transfer],
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: ZeroReceiptAlchemyStub()),
      importOrigin: origin)
    let leg = try #require(built.first?.transaction.legs.first)
    #expect(leg.counterpartyAddress == nil)
  }

  @Test("Counterparty address is lowercased even if Alchemy returns mixed case")
  func counterpartyIsLowercased() async throws {
    let subject = makeDiscoverySubject()
    let account = makeCryptoAccount(walletAddress: Self.walletMixedCase, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let mixedCase = "0xBBbbBBbbBBbbBBbbBBbbBBbbBBbbBBbbBBbbBBbb"
    let transfer = makeAlchemyTransfer(
      hash: "0xcase",
      from: Self.walletLowercase,
      to: mixedCase,
      category: .external)

    let built = try await TransferEventBuilder().build(
      transfers: [transfer],
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: ZeroReceiptAlchemyStub()),
      importOrigin: origin)
    let leg = try #require(built.first?.transaction.legs.first)
    #expect(leg.counterpartyAddress == mixedCase.lowercased())
  }
}
