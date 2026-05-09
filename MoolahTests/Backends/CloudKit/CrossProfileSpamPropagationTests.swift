// MoolahTests/Backends/CloudKit/CrossProfileSpamPropagationTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Smoking-gun test for the shared instrument registry. Two
/// `GRDBInstrumentRegistryRepository` instances pointed at the same
/// `profile-index.sqlite` (one per simulated profile session) must
/// observe each other's spam classifications — the whole point of
/// the design.
///
/// Before stage 12b: each profile session constructed its own
/// per-profile registry pointed at its own per-profile DB. Marking
/// `bitcoin` as spam in profile A's session left profile B's session
/// reading from a different table, so the spam classification didn't
/// propagate.
///
/// After stage 12b: every profile session points at the same shared
/// registry instance backed by the profile-index DB, so a spam
/// classification written by any session is visible to every session
/// that reads it next.
///
/// This test simulates two sessions by constructing two registry
/// instances against the same `profile-index.sqlite` queue (the
/// production wiring constructs a single shared instance, but two
/// instances pointing at the same DB is the equivalent observable
/// behaviour from the consumer's point of view). The shared queue is
/// the load-bearing invariant; the registry instance count is not.
@Suite("Cross-profile spam propagation")
struct CrossProfileSpamPropagationTests {

  @Test("marking spam through one registry is visible through another against the same DB")
  func spamMarkedInOneSessionIsVisibleToAnother() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let registryA = GRDBInstrumentRegistryRepository(database: queue)
    let registryB = GRDBInstrumentRegistryRepository(database: queue)

    // Profile A registers bitcoin as priced.
    let bitcoin = Instrument.crypto(
      chainId: 1,
      contractAddress: nil,
      symbol: "BTC",
      name: "Bitcoin",
      decimals: 8)
    try await registryA.registerCrypto(
      bitcoin,
      mapping: CryptoProviderMapping(
        instrumentId: bitcoin.id,
        coingeckoId: "bitcoin",
        cryptocompareSymbol: "BTC",
        binanceSymbol: nil))

    // Profile B sees the registration.
    let beforeSpam = try #require(
      try await registryB.cryptoRegistration(byId: bitcoin.id))
    #expect(beforeSpam.pricingStatus == .priced)

    // Profile A marks it spam (the user's "decide once, applies everywhere"
    // gesture from §Motivation in the design doc).
    var registration = beforeSpam
    registration.pricingStatus = .spam
    try await registryA.update(registration)

    // Profile B sees the spam classification immediately — same DB,
    // single source of truth.
    let afterSpam = try #require(
      try await registryB.cryptoRegistration(byId: bitcoin.id))
    #expect(afterSpam.pricingStatus == .spam)
  }

  @Test("removing a registration through one registry is visible through another")
  func removeIsVisibleAcrossSessions() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let registryA = GRDBInstrumentRegistryRepository(database: queue)
    let registryB = GRDBInstrumentRegistryRepository(database: queue)

    let usdc = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC",
      name: "USD Coin",
      decimals: 6)
    try await registryA.registerCrypto(
      usdc,
      mapping: CryptoProviderMapping(
        instrumentId: usdc.id,
        coingeckoId: "usd-coin",
        cryptocompareSymbol: "USDC",
        binanceSymbol: nil))
    #expect(
      try await registryB.cryptoRegistration(byId: usdc.id) != nil)

    try await registryA.remove(id: usdc.id)
    #expect(
      try await registryB.cryptoRegistration(byId: usdc.id) == nil)
  }
}
