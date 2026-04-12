import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("Trade Flow — Integration")
@MainActor
struct TradeFlowIntegrationTests {
  let aud = Instrument.fiat(code: "AUD")
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  private func dateString(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.string(from: date)
  }

  @Test func buyThenSellUpdatesPositions() async throws {
    let accountId = UUID()
    let today = Date()
    let ds = dateString(today)

    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(id: accountId, name: "Invest", type: .investment, usesPositionTracking: true)
      ], in: container)

    let stockClient = FixedStockPriceClient(responses: [
      "BHP.AX": StockPriceResponse(instrument: .AUD, prices: [ds: Decimal(string: "45.00")!])
    ])
    let stockCacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("trade-flow-tests")
      .appendingPathComponent(UUID().uuidString)
    let stockService = StockPriceService(client: stockClient, cacheDirectory: stockCacheDir)
    let rateClient = FixedRateClient(rates: [:])
    let rateCacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("trade-flow-rates")
      .appendingPathComponent(UUID().uuidString)
    let rateService = ExchangeRateService(client: rateClient, cacheDirectory: rateCacheDir)
    let conversionService = FullConversionService(
      exchangeRates: rateService,
      stockPrices: stockService
    )

    let tradeStore = TradeStore(transactions: backend.transactions)
    let investmentStore = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: conversionService
    )

    // Buy 100 BHP for $4,230
    var buyDraft = TradeDraft(accountId: accountId)
    buyDraft.soldInstrument = aud
    buyDraft.soldQuantityText = "4230.00"
    buyDraft.boughtInstrument = bhp
    buyDraft.boughtQuantityText = "100"
    buyDraft.date = today
    _ = try await tradeStore.executeTrade(buyDraft)

    // Load and check positions
    await investmentStore.loadPositions(accountId: accountId)
    #expect(investmentStore.positions.count == 2)

    let bhpPos = investmentStore.positions.first { $0.instrument == bhp }
    #expect(bhpPos?.quantity == Decimal(100))

    // Valuate
    await investmentStore.valuatePositions(profileCurrency: aud, on: today)
    let bhpValued = investmentStore.valuedPositions.first { $0.position.instrument == bhp }
    #expect(bhpValued?.marketValue == Decimal(string: "4500.00")!)  // 100 * 45.00

    // Sell 30 BHP for $1,350
    var sellDraft = TradeDraft(accountId: accountId)
    sellDraft.soldInstrument = bhp
    sellDraft.soldQuantityText = "30"
    sellDraft.boughtInstrument = aud
    sellDraft.boughtQuantityText = "1350.00"
    sellDraft.date = today
    _ = try await tradeStore.executeTrade(sellDraft)

    // Reload positions
    await investmentStore.loadPositions(accountId: accountId)
    let bhpAfterSell = investmentStore.positions.first { $0.instrument == bhp }
    #expect(bhpAfterSell?.quantity == Decimal(70))  // 100 - 30

    // Cash position: -4230 + 1350 = -2880
    let cashPos = investmentStore.positions.first { $0.instrument == aud }
    #expect(cashPos?.quantity == Decimal(string: "-2880.00")!)
  }

  @Test func tradeWithFeeReducesCashPosition() async throws {
    let accountId = UUID()
    let feeCatId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(id: accountId, name: "Invest", type: .investment, usesPositionTracking: true)
      ], in: container)
    TestBackend.seed(
      categories: [
        Category(id: feeCatId, name: "Brokerage Fees")
      ], in: container)

    let tradeStore = TradeStore(transactions: backend.transactions)
    let investmentStore = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: nil
    )

    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    draft.feeAmountText = "9.50"
    draft.feeInstrument = aud
    draft.feeCategoryId = feeCatId
    draft.date = Date()
    _ = try await tradeStore.executeTrade(draft)

    await investmentStore.loadPositions(accountId: accountId)

    // Cash: -6345 - 9.50 = -6354.50
    let cashPos = investmentStore.positions.first { $0.instrument == aud }
    #expect(cashPos?.quantity == Decimal(string: "-6354.50")!)
  }
}
