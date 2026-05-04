import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("AccountStore preloads only recordedValue accounts")
struct AccountStorePreloadFilterTests {
  @Test("only recordedValue investment accounts get a preload")
  func preloadFiltersByMode() async throws {
    let (backend, _) = try TestBackend.create()
    let recorded = try await backend.accounts.create(
      Account(
        name: "R", type: .investment, instrument: .AUD,
        valuationMode: .recordedValue))
    let trades = try await backend.accounts.create(
      Account(
        name: "T", type: .investment, instrument: .AUD,
        valuationMode: .calculatedFromTrades))
    try await backend.investments.setValue(
      accountId: recorded.id, date: Date(timeIntervalSince1970: 1_700_000_000),
      value: InstrumentAmount(quantity: 100, instrument: .AUD))
    try await backend.investments.setValue(
      accountId: trades.id, date: Date(timeIntervalSince1970: 1_700_000_000),
      value: InstrumentAmount(quantity: 999, instrument: .AUD))

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: FixedConversionService(),
      targetInstrument: .AUD,
      investmentRepository: backend.investments)
    await store.load()

    #expect(store.investmentValues[recorded.id] != nil)
    #expect(store.investmentValues[trades.id] == nil)
  }

  @Test("flipping mode to recordedValue triggers a snapshot preload")
  func updateToRecordedValuePreloadsSnapshot() async throws {
    let (backend, _) = try TestBackend.create()
    let account = try await backend.accounts.create(
      Account(
        name: "Brokerage", type: .investment, instrument: .AUD,
        valuationMode: .calculatedFromTrades))
    try await backend.investments.setValue(
      accountId: account.id, date: Date(timeIntervalSince1970: 1_700_000_000),
      value: InstrumentAmount(quantity: 250, instrument: .AUD))

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: FixedConversionService(),
      targetInstrument: .AUD,
      investmentRepository: backend.investments)
    await store.load()

    // The snapshot exists in the repo but the cache excluded it because
    // the account was in `calculatedFromTrades` mode at load time.
    #expect(store.investmentValues[account.id] == nil)

    var updated = account
    updated.valuationMode = .recordedValue
    _ = try await store.update(updated)

    // After the mode flip, `update` preloads investment values so the
    // cache picks up the existing snapshot for the now-recordedValue
    // account.
    #expect(store.investmentValues[account.id]?.quantity == 250)
  }
}
