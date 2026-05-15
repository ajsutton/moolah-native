// MoolahTests/Sync/ApplyPathSharedRegistryResolutionTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the contract that the sync apply-path repository bundle resolves
/// and registers instruments against the SHARED profile-index registry,
/// not the per-profile `instrument` table.
///
/// Earlier work moved every `InstrumentRecord` apply onto the
/// profile-index zone (`ProfileIndexSyncHandler` + the shared registry);
/// the per-profile `ProfileDataSyncHandler` traps/skips them. The
/// remaining per-profile-`instrument`-table seam reachable from the
/// apply bundle was the `instrumentResolver` / `instrumentRegistrar`
/// injected into the txn/account/earmark/investment repos by
/// `makeForApply`. The apply path never invokes them today (it writes
/// raw Rows via `applyRemoteChangesSync`), but they were per-profile
/// `PerProfile*` shims pointed at the per-profile `instrument` table —
/// which the `v10_drop_shared_instrument_legacy` migration has now
/// dropped. After the cutover the per-profile `instrument` table no
/// longer exists at all, so when a shared registry is supplied the
/// bundle's resolver/registrar are the shared registry and any
/// apply-time instrument resolution lands against the profile-index
/// DB — the per-profile table is structurally unreachable.
@MainActor
@Suite("Apply-path bundle resolves via the shared registry")
struct ApplyPathSharedRegistryResolutionTests {

  @Test(
    "makeForApply resolver reads instruments from the shared registry, not the per-profile table")
  func resolverUsesSharedRegistry() async throws {
    // Two distinct databases: the per-profile DB (whose `instrument`
    // table v10 has dropped) and the shared profile-index DB.
    let perProfile = try ProfileDatabase.openInMemory()
    let sharedDB = try ProfileIndexDatabase.openInMemory()
    let sharedRegistry = GRDBInstrumentRegistryRepository(database: sharedDB)

    // A crypto instrument that exists ONLY in the shared registry.
    let crypto = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC",
      name: "USD Coin",
      decimals: 6)
    try await sharedRegistry.registerCrypto(
      crypto,
      mapping: CryptoProviderMapping(
        instrumentId: crypto.id,
        coingeckoId: "usd-coin",
        cryptocompareSymbol: "USDC",
        binanceSymbol: nil))

    let bundle = ProfileGRDBRepositories.makeForApply(
      database: perProfile, sharedRegistry: sharedRegistry)

    // All four repos resolve the crypto instrument because their injected
    // resolver is the shared registry, not the per-profile shim.
    let txnMap = try await bundle.transactions.instrumentResolver.instrumentMap()
    let accountMap = try await bundle.accounts.instrumentResolver.instrumentMap()
    let earmarkMap = try await bundle.earmarks.instrumentResolver.instrumentMap()
    let investmentMap =
      try await bundle.investmentValues.instrumentResolver.instrumentMap()
    #expect(txnMap[crypto.id]?.kind == .cryptoToken)
    #expect(accountMap[crypto.id]?.kind == .cryptoToken)
    #expect(earmarkMap[crypto.id]?.kind == .cryptoToken)
    #expect(investmentMap[crypto.id]?.kind == .cryptoToken)

    // Post-v10 the per-profile `instrument` table no longer exists —
    // resolution through it is structurally impossible, a strictly
    // stronger guarantee than "the table is empty".
    let perProfileTableExists = try await perProfile.read { database in
      try Bool.fetchOne(
        database,
        sql: """
          SELECT EXISTS(
            SELECT 1 FROM sqlite_master WHERE type='table' AND name='instrument')
          """) ?? true
    }
    #expect(perProfileTableExists == false)
  }

  @Test("apply bundle never resolves through the per-profile instrument table")
  func applyBundleIgnoresPerProfileInstrumentTable() async throws {
    let perProfile = try ProfileDatabase.openInMemory()
    let sharedRegistry = try SharedRegistryTestSupport.makeSharedRegistry()
    let bundle = ProfileGRDBRepositories.makeForApply(
      database: perProfile, sharedRegistry: sharedRegistry)

    // Post-v10 the per-profile `instrument` table is dropped, so it is
    // structurally impossible for the bundle's resolver to fall back to
    // a per-profile crypto row: the table simply does not exist.
    let perProfileTableExists = try await perProfile.read { database in
      try Bool.fetchOne(
        database,
        sql: """
          SELECT EXISTS(
            SELECT 1 FROM sqlite_master WHERE type='table' AND name='instrument')
          """) ?? true
    }
    #expect(perProfileTableExists == false)

    // A crypto id present in neither the per-profile DB nor the shared
    // registry resolves to nothing — resolution is shared-only now.
    let map = try await bundle.transactions.instrumentResolver.instrumentMap()
    #expect(
      map["1:native"] == nil,
      "the apply bundle must not resolve crypto from any per-profile table")
  }
}
