import Foundation
import SwiftData
import Testing

@testable import Moolah

/// Mirrors `EnsureInstrumentCryptoMappingTests` for the account repo: a
/// write that references a crypto instrument with no price-provider mapping
/// must throw `UnmappedCryptoInstrumentError` rather than silently inserting
/// an unmapped row (which later trips `ConversionError.noProviderMapping`
/// at conversion time). Fiat and stock paths are unaffected — see design
/// plan §4.8.
@Suite("CloudKitAccountRepository — ensureInstrument")
@MainActor
struct AccountEnsureCryptoMappingTests {
  @Test("fiat instrument is allowed (no insert, no throw)")
  func fiatInstrumentSucceeds() throws {
    let repo = try makeAccountRepo()
    try repo.ensureInstrument(Instrument.fiat(code: "USD"))
  }

  @Test("crypto instrument with a registered mapping is allowed")
  func mappedCryptoInstrumentSucceeds() throws {
    let repo = try makeAccountRepo()
    let context = repo.modelContainer.mainContext
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18)

    // Seed an InstrumentRecord with a provider mapping populated, mirroring
    // what InstrumentRegistryRepository.registerCrypto does. ensureInstrument
    // should treat any non-nil mapping field as "registered".
    let row = InstrumentRecord(
      id: eth.id,
      kind: eth.kind.rawValue,
      name: eth.name,
      decimals: eth.decimals,
      ticker: eth.ticker,
      exchange: eth.exchange,
      chainId: eth.chainId,
      contractAddress: eth.contractAddress,
      coingeckoId: "ethereum"
    )
    context.insert(row)
    try context.save()

    try repo.ensureInstrument(eth)
  }

  @Test("crypto instrument with no row throws UnmappedCryptoInstrumentError")
  func unmappedCryptoInstrumentThrowsWhenRowMissing() throws {
    let repo = try makeAccountRepo()
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18)

    #expect(throws: UnmappedCryptoInstrumentError(instrumentId: eth.id)) {
      try repo.ensureInstrument(eth)
    }
  }

  @Test("crypto instrument with row but all mapping fields nil throws")
  func unmappedCryptoInstrumentThrowsWhenMappingNil() throws {
    let repo = try makeAccountRepo()
    let context = repo.modelContainer.mainContext
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18)

    // Simulates a pre-Task-15 silently-auto-inserted row: crypto kind, but
    // no provider mapping. Tightening means ensureInstrument now refuses
    // these instead of treating the row's mere presence as registered.
    let ghost = InstrumentRecord(
      id: eth.id,
      kind: eth.kind.rawValue,
      name: eth.name,
      decimals: eth.decimals,
      ticker: eth.ticker,
      chainId: eth.chainId,
      contractAddress: eth.contractAddress
    )
    context.insert(ghost)
    try context.save()

    #expect(throws: UnmappedCryptoInstrumentError(instrumentId: eth.id)) {
      try repo.ensureInstrument(eth)
    }
  }

  // MARK: - Helpers

  private func makeAccountRepo() throws -> CloudKitAccountRepository {
    let container = try TestModelContainer.create()
    return CloudKitAccountRepository(modelContainer: container)
  }
}
