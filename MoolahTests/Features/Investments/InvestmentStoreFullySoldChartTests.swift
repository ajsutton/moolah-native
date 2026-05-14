import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("InvestmentStore fully-sold account chart")
struct InvestmentStoreFullySoldChartTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  @Test("fully-sold account yields shouldHide + hasHistoricalSeries + showsChart")
  func fullySoldAccountSurfacesChart() async throws {
    let (backend, _) = try TestBackend.create()
    let conversionService = FixedConversionService(rates: [bhp.id: Decimal(50)])
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: conversionService
    )
    let account = Account(
      name: "Brokerage", type: .investment, instrument: aud,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 0, instrument: aud))

    // Buy 100 BHP @ 40 AUD on day -30.
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(timeIntervalSinceNow: -86_400 * 30),
        legs: [
          TransactionLeg(accountId: account.id, instrument: bhp, quantity: 100, type: .trade),
          TransactionLeg(accountId: account.id, instrument: aud, quantity: -4_000, type: .trade),
        ]))
    // Sell all 100 BHP @ 50 AUD on day -10.
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(timeIntervalSinceNow: -86_400 * 10),
        legs: [
          TransactionLeg(accountId: account.id, instrument: bhp, quantity: -100, type: .trade),
          TransactionLeg(accountId: account.id, instrument: aud, quantity: 5_000, type: .trade),
        ]))

    let input = try await store.loadAndBuildPositionsInput(
      account: account, profileCurrency: aud, range: .threeMonths)

    // A sell-for-profit leaves the net cash leg as a host-currency
    // position; `loadPositions` keeps non-zero rows. `shouldHide`
    // collapses this into the chart-only path.
    let nonHostPositions = input.positions.filter { $0.instrument != aud }
    #expect(nonHostPositions.isEmpty)
    #expect(input.shouldHide)
    #expect(input.hasHistoricalSeries)
    #expect(input.showsChart)
    #expect(input.showsAggregateChart)
  }

  @Test("brand-new account with no transactions still falls back to bare transactions path")
  func emptyAccountStillHidesChart() async throws {
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService
    )
    let account = Account(
      name: "Brokerage", type: .investment, instrument: aud,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 0, instrument: aud))

    let input = try await store.loadAndBuildPositionsInput(
      account: account, profileCurrency: aud, range: .threeMonths)

    #expect(input.positions.isEmpty)
    #expect(input.shouldHide)
    #expect(!input.hasHistoricalSeries)
    #expect(!input.showsChart)
  }
}
