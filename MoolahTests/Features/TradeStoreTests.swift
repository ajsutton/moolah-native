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
        Account(id: accountId, name: "Sharesight", type: .investment)
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
        Account(id: accountId, name: "Sharesight", type: .investment)
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
}
