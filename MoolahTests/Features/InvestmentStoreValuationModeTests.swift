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
        name: "Recorded", type: .investment, instrument: .AUD,
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
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let account = try await backend.accounts.create(
      Account(
        name: "Trades", type: .investment, instrument: .AUD,
        valuationMode: .calculatedFromTrades))
    try await backend.investments.setValue(
      accountId: account.id,
      date: Date(timeIntervalSince1970: 1_700_000_000),
      value: InstrumentAmount(quantity: 9999, instrument: .AUD))
    // Seed a trade so the trades path produces a non-empty `positions`
    // result; pinning both sides ensures the test fails not just when
    // the legacy branch fires but also when the trades branch is a no-op.
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(accountId: account.id, instrument: bhp, quantity: 100, type: .trade),
          TransactionLeg(accountId: account.id, instrument: .AUD, quantity: -4_000, type: .trade),
        ]))

    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService)
    await store.loadAllData(account: account, profileCurrency: .AUD)

    #expect(store.values.isEmpty)
    #expect(!store.positions.isEmpty)
  }
}
