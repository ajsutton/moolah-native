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
}
