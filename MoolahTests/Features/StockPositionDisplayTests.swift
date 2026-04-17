import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("InvestmentStore — Stock Positions")
@MainActor
struct StockPositionDisplayTests {
  let aud = Instrument.fiat(code: "AUD")
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")

  private func dateString(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.string(from: date)
  }

  @Test func loadPositionsComputesFromLegs() async throws {
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Invest", type: .investment, instrument: .defaultTestInstrument)
      ], in: container)

    // Seed a buy trade: -6345 AUD, +150 BHP
    let buyDate = Calendar.current.date(from: DateComponents(year: 2024, month: 6, day: 15))!
    TestBackend.seed(
      transactions: [
        Transaction(
          id: UUID(),
          date: buyDate,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: aud, quantity: Decimal(string: "-6345.00")!,
              type: .transfer),
            TransactionLeg(
              accountId: accountId, instrument: bhp, quantity: Decimal(150), type: .transfer),
          ]
        )
      ], in: container)

    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: FixedConversionService()
    )
    await store.loadPositions(accountId: accountId)

    #expect(store.positions.count == 2)  // AUD + BHP

    let bhpPosition = store.positions.first { $0.instrument == bhp }
    #expect(bhpPosition != nil)
    #expect(bhpPosition!.quantity == Decimal(150))

    let audPosition = store.positions.first { $0.instrument == aud }
    #expect(audPosition != nil)
    #expect(audPosition!.quantity == Decimal(string: "-6345.00")!)
  }

  @Test func valuedPositionsIncludeMarketValue() async throws {
    let accountId = UUID()
    let today = Date()
    let ds = dateString(today)

    let stockClient = FixedStockPriceClient(responses: [
      "BHP.AX": StockPriceResponse(instrument: .AUD, prices: [ds: Decimal(string: "45.00")!])
    ])
    let stockCacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("stock-valued-tests")
      .appendingPathComponent(UUID().uuidString)
    let stockService = StockPriceService(client: stockClient, cacheDirectory: stockCacheDir)
    let rateClient = FixedRateClient(rates: [:])
    let rateCacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("position-display-tests")
      .appendingPathComponent(UUID().uuidString)
    let rateService = ExchangeRateService(client: rateClient, cacheDirectory: rateCacheDir)
    let conversionService = FullConversionService(
      exchangeRates: rateService,
      stockPrices: stockService
    )

    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Invest", type: .investment, instrument: .defaultTestInstrument)
      ], in: container)
    TestBackend.seed(
      transactions: [
        Transaction(
          id: UUID(),
          date: today,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: aud, quantity: Decimal(string: "-6345.00")!,
              type: .transfer),
            TransactionLeg(
              accountId: accountId, instrument: bhp, quantity: Decimal(150), type: .transfer),
          ]
        )
      ], in: container)

    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: conversionService
    )
    await store.loadPositions(accountId: accountId)
    await store.valuatePositions(profileCurrency: aud, on: today)

    let bhpValued = store.valuedPositions.first { $0.position.instrument == bhp }
    #expect(bhpValued != nil)
    // 150 shares * $45.00 = $6,750.00
    #expect(bhpValued!.marketValue == Decimal(string: "6750.00")!)
  }

  @Test func totalPortfolioValueSumsAllPositions() async throws {
    let accountId = UUID()
    let today = Date()
    let ds = dateString(today)

    let stockClient = FixedStockPriceClient(responses: [
      "BHP.AX": StockPriceResponse(instrument: .AUD, prices: [ds: Decimal(string: "45.00")!]),
      "CBA.AX": StockPriceResponse(instrument: .AUD, prices: [ds: Decimal(string: "120.00")!]),
    ])
    let stockCacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("stock-total-tests")
      .appendingPathComponent(UUID().uuidString)
    let stockService = StockPriceService(client: stockClient, cacheDirectory: stockCacheDir)
    let rateClient = FixedRateClient(rates: [:])
    let rateCacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("position-display-tests")
      .appendingPathComponent(UUID().uuidString)
    let rateService = ExchangeRateService(client: rateClient, cacheDirectory: rateCacheDir)
    let conversionService = FullConversionService(
      exchangeRates: rateService,
      stockPrices: stockService
    )

    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Invest", type: .investment, instrument: .defaultTestInstrument)
      ], in: container)
    TestBackend.seed(
      transactions: [
        // Buy 150 BHP for 6345 AUD
        Transaction(
          id: UUID(), date: today,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: aud, quantity: Decimal(string: "-6345.00")!,
              type: .transfer),
            TransactionLeg(
              accountId: accountId, instrument: bhp, quantity: Decimal(150), type: .transfer),
          ]),
        // Buy 20 CBA for 2400 AUD
        Transaction(
          id: UUID(), date: today,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: aud, quantity: Decimal(string: "-2400.00")!,
              type: .transfer),
            TransactionLeg(
              accountId: accountId, instrument: cba, quantity: Decimal(20), type: .transfer),
          ]),
      ], in: container)

    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: conversionService
    )
    await store.loadPositions(accountId: accountId)
    await store.valuatePositions(profileCurrency: aud, on: today)

    // Cash: -6345 - 2400 = -8745 AUD (negative = cash spent)
    // BHP: 150 * 45.00 = 6750 AUD
    // CBA: 20 * 120.00 = 2400 AUD
    // Total: -8745 + 6750 + 2400 = 405 AUD
    #expect(store.totalPortfolioValue == Decimal(string: "405.00")!)
  }

  /// Per Rule 11 in `guides/INSTRUMENT_CONVERSION_GUIDE.md`: when a
  /// position's conversion fails, the aggregate `totalPortfolioValue`
  /// must be marked unavailable (nil) — we must not display a partial
  /// sum as the portfolio total. Per-position valuations still render
  /// individually with `marketValue == nil` for the failing one.
  @Test func totalPortfolioValueIsNilWhenAnyPositionConversionFails() async throws {
    let accountId = UUID()
    let today = Date()

    let conversionService = FailingConversionService(
      rates: [bhp.id: Decimal(45), cba.id: Decimal(120)],
      failingInstrumentIds: [cba.id]
    )

    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Invest", type: .investment, instrument: .defaultTestInstrument)
      ], in: container)
    TestBackend.seed(
      transactions: [
        Transaction(
          id: UUID(), date: today,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: aud, quantity: Decimal(string: "-6345.00")!,
              type: .transfer),
            TransactionLeg(
              accountId: accountId, instrument: bhp, quantity: Decimal(150), type: .transfer),
          ]),
        Transaction(
          id: UUID(), date: today,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: aud, quantity: Decimal(string: "-2400.00")!,
              type: .transfer),
            TransactionLeg(
              accountId: accountId, instrument: cba, quantity: Decimal(20), type: .transfer),
          ]),
      ], in: container)

    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: conversionService
    )
    await store.loadPositions(accountId: accountId)
    await store.valuatePositions(profileCurrency: aud, on: today)

    // Aggregate is unavailable — one position failed.
    #expect(store.totalPortfolioValue == nil)
    // Per-position rendering still works for the convertible BHP.
    let bhpValued = store.valuedPositions.first { $0.position.instrument == bhp }
    #expect(bhpValued?.marketValue == Decimal(string: "6750")!)
    // And the failing position is rendered with nil marketValue so the
    // view can show "Unavailable" on that row.
    let cbaValued = store.valuedPositions.first { $0.position.instrument == cba }
    #expect(cbaValued != nil)
    #expect(cbaValued?.marketValue == nil)
    // Error state is surfaced so a retry affordance can be shown.
    #expect(store.error != nil)
  }
}
