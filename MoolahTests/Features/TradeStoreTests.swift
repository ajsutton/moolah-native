import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("TradeStore")
@MainActor
struct TradeStoreTests {
  let aud = Instrument.fiat(code: "AUD")
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  private func makeDate(year: Int, month: Int, day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
  }

  @Test func executeTradeSavesMultiLegTransaction() async throws {
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Sharesight", type: .investment, instrument: .defaultTestInstrument)
      ], in: container)

    let store = TradeStore(transactions: backend.transactions)

    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    draft.date = makeDate(year: 2024, month: 6, day: 15)

    let result = try await store.executeTrade(draft)
    #expect(result.legs.count == 2)

    // Verify transaction was persisted
    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0,
      pageSize: 10
    )
    #expect(page.transactions.count == 1)
    #expect(page.transactions[0].legs.count == 2)
  }

  @Test func executeTradeWithFeeSavesThreeLegs() async throws {
    let accountId = UUID()
    let feeCategoryId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Sharesight", type: .investment, instrument: .defaultTestInstrument)
      ], in: container)

    let store = TradeStore(transactions: backend.transactions)

    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    draft.feeAmountText = "9.50"
    draft.feeInstrument = aud
    draft.feeCategoryId = feeCategoryId
    draft.date = makeDate(year: 2024, month: 6, day: 15)

    let result = try await store.executeTrade(draft)
    #expect(result.legs.count == 3)
    #expect(result.legs[2].type == .expense)
  }

  @Test func executeInvalidDraftThrows() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TradeStore(transactions: backend.transactions)

    // Empty draft — invalid
    let draft = TradeDraft(accountId: UUID())

    await #expect(throws: TradeError.self) {
      _ = try await store.executeTrade(draft)
    }
  }

  @Test func executeTradeReportsError() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TradeStore(transactions: backend.transactions)

    let draft = TradeDraft(accountId: UUID())
    do {
      _ = try await store.executeTrade(draft)
    } catch {
      #expect(store.error != nil)
    }
  }

  // MARK: - Multi-instrument persistence

  @Test func executeTradePersistsLegInstrumentsExactly() async throws {
    // Verify each leg's instrument survives a round-trip through CloudKitBackend storage —
    // not just leg count. Stock trades span fiat + stock kinds.
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Sharesight", type: .investment, instrument: .defaultTestInstrument)
      ], in: container)

    let store = TradeStore(transactions: backend.transactions)

    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    draft.date = makeDate(year: 2024, month: 6, day: 15)

    _ = try await store.executeTrade(draft)

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0,
      pageSize: 10
    )
    let fetched = try #require(page.transactions.first)
    #expect(fetched.legs.count == 2)
    let audLeg = try #require(fetched.legs.first(where: { $0.instrument == aud }))
    let stockLeg = try #require(fetched.legs.first(where: { $0.instrument.kind == .stock }))
    #expect(audLeg.quantity == Decimal(string: "-6345.00")!)
    #expect(stockLeg.instrument == bhp)
    #expect(stockLeg.quantity == Decimal(150))
  }

  @Test func executeTradeWithFeeInThirdInstrumentPersistsThreeDistinctInstruments() async throws {
    let accountId = UUID()
    let feeCategoryId = UUID()
    let usd = Instrument.fiat(code: "USD")
    let aapl = Instrument.stock(ticker: "AAPL", exchange: "NASDAQ", name: "Apple")
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Interactive Brokers", type: .investment,
          instrument: .defaultTestInstrument)
      ], in: container)

    let store = TradeStore(transactions: backend.transactions)

    // Sell USD, buy AAPL, fee in AUD — three different instruments on the same trade.
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = usd
    draft.soldQuantityText = "1855.00"
    draft.boughtInstrument = aapl
    draft.boughtQuantityText = "10"
    draft.feeAmountText = "7.50"
    draft.feeInstrument = aud
    draft.feeCategoryId = feeCategoryId
    draft.date = makeDate(year: 2024, month: 6, day: 15)

    _ = try await store.executeTrade(draft)

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0,
      pageSize: 10
    )
    let fetched = try #require(page.transactions.first)
    #expect(fetched.legs.count == 3)
    let instrumentIds = Set(fetched.legs.map { $0.instrument.id })
    #expect(instrumentIds == [usd.id, aapl.id, aud.id])
    let feeLeg = try #require(fetched.legs.first(where: { $0.type == .expense }))
    #expect(feeLeg.instrument == aud)
    #expect(feeLeg.categoryId == feeCategoryId)
  }

  @Test func executeCryptoSwapPersistsBothLegsWithCorrectInstruments() async throws {
    let accountId = UUID()
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    let uni = Instrument.crypto(
      chainId: 1,
      contractAddress: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984",
      symbol: "UNI", name: "Uniswap", decimals: 18
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Wallet", type: .investment, instrument: .defaultTestInstrument)
      ], in: container)

    let store = TradeStore(transactions: backend.transactions)

    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = eth
    draft.soldQuantityText = "0.5"
    draft.boughtInstrument = uni
    draft.boughtQuantityText = "1234.56"
    draft.date = makeDate(year: 2024, month: 6, day: 15)

    _ = try await store.executeTrade(draft)

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0,
      pageSize: 10
    )
    let fetched = try #require(page.transactions.first)
    let soldLeg = try #require(fetched.legs.first(where: { $0.instrument == eth }))
    let boughtLeg = try #require(fetched.legs.first(where: { $0.instrument == uni }))
    #expect(soldLeg.quantity == Decimal(string: "-0.5")!)
    #expect(boughtLeg.quantity == Decimal(string: "1234.56")!)
    #expect(soldLeg.type == .transfer)
    #expect(boughtLeg.type == .transfer)
  }
}
