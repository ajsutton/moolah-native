import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("InvestmentStore branches on Account.valuationMode")
struct InvestmentStoreValuationModeTests {
  @Test("loadAllData(account:) calls legacy path when mode is recordedValue")
  func recordedTakesLegacyPath() async throws {
    let (backend, _) = try TestBackend.create()
    let account = try await backend.accounts.create(
      Account(
        name: "B", type: .investment, instrument: .AUD,
        valuationMode: .recordedValue))
    try await backend.investments.setValue(
      accountId: account.id,
      date: Date(timeIntervalSince1970: 1_700_000_000),
      value: InstrumentAmount(quantity: 100, instrument: .AUD))

    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService)
    await store.loadAllData(account: account, profileCurrency: .AUD)

    #expect(!store.values.isEmpty)
    #expect(store.positions.isEmpty)
  }

  @Test("loadAllData(account:) calls trades path when mode is calculatedFromTrades")
  func tradesTakesPositionsPath() async throws {
    let (backend, _) = try TestBackend.create()
    let account = try await backend.accounts.create(
      Account(
        name: "T", type: .investment, instrument: .AUD,
        valuationMode: .calculatedFromTrades))
    try await backend.investments.setValue(
      accountId: account.id,
      date: Date(timeIntervalSince1970: 1_700_000_000),
      value: InstrumentAmount(quantity: 9999, instrument: .AUD))

    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService)
    await store.loadAllData(account: account, profileCurrency: .AUD)

    #expect(store.values.isEmpty)
  }
}
