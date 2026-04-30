import Foundation
import Testing

@testable import Moolah

@Suite("InvestmentStore performance")
@MainActor
struct InvestmentStorePerformanceTests {

  @Test("loadAllData populates accountPerformance for a position-tracked account")
  func loadAllDataPositionTrackedPerformance() async throws {
    let aud = Instrument.AUD
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService)

    let account = Account(name: "Brokerage", type: .investment, instrument: aud)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 10_000, instrument: aud))

    await store.loadAllData(accountId: account.id, profileCurrency: aud)

    let perf = try #require(store.accountPerformance)
    #expect(perf.instrument == aud)
    #expect(perf.totalContributions == InstrumentAmount(quantity: 10_000, instrument: aud))
  }

  @Test("loadAllData populates accountPerformance for a legacy-valuation account")
  func loadAllDataLegacyPerformance() async throws {
    let accountId = UUID()
    let aud = Instrument.AUD
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      investmentValues: [
        accountId: [
          InvestmentValue(
            date: Date(timeIntervalSinceReferenceDate: 0),
            value: InstrumentAmount(quantity: 10_000, instrument: aud)),
          InvestmentValue(
            date: Date(timeIntervalSinceReferenceDate: 365 * 86_400),
            value: InstrumentAmount(quantity: 11_000, instrument: aud)),
        ]
      ],
      in: database
    )
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService)

    await store.loadAllData(accountId: accountId, profileCurrency: aud)

    let perf = try #require(store.accountPerformance)
    #expect(perf.currentValue == InstrumentAmount(quantity: 11_000, instrument: aud))
  }
}
