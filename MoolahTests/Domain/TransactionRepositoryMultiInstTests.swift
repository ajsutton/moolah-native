import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("TransactionRepository — Multi-instrument Persistence")
struct TransactionRepositoryMultiInstTests {
  @Test("currency conversion transfer persists legs in distinct instruments")
  func testCurrencyConversionPersistsLegsInDistinctInstruments() async throws {
    let repository = try makeContractCloudKitTransactionRepository()
    let accountId = UUID()
    let date = try #require(
      Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 15)))
    let negOneThousand = try #require(Decimal(string: "-1000.00"))
    let sixFifty = try #require(Decimal(string: "650.00"))
    let conversion = Transaction(
      date: date,
      payee: "FX",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD,
          quantity: negOneThousand, type: .transfer),
        TransactionLeg(
          accountId: accountId, instrument: .USD,
          quantity: sixFifty, type: .transfer),
      ]
    )

    let created = try await repository.create(conversion)
    #expect(created.legs.count == 2)

    let page = try await repository.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0,
      pageSize: 10
    )
    let fetched = try #require(page.transactions.first(where: { $0.id == created.id }))
    #expect(fetched.legs.count == 2)
    let audLeg = try #require(fetched.legs.first(where: { $0.instrument == .AUD }))
    let usdLeg = try #require(fetched.legs.first(where: { $0.instrument == .USD }))
    #expect(audLeg.quantity == negOneThousand)
    #expect(usdLeg.quantity == sixFifty)
  }

  @Test("stock trade transaction persists fiat and stock legs")
  func testStockTradePersistsFiatAndStockLegs() async throws {
    let repository = try makeContractCloudKitTransactionRepository()
    let accountId = UUID()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let negSixThreeFourFive = try #require(Decimal(string: "-6345.00"))
    let trade = Transaction(
      date: Date(),
      payee: "Buy 150 BHP",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD,
          quantity: negSixThreeFourFive, type: .transfer),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: Decimal(150), type: .transfer),
      ]
    )

    let created = try await repository.create(trade)
    #expect(created.legs.count == 2)

    let page = try await repository.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0,
      pageSize: 10
    )
    let fetched = try #require(page.transactions.first(where: { $0.id == created.id }))
    let audLeg = try #require(fetched.legs.first(where: { $0.instrument == .AUD }))
    let stockLeg = try #require(fetched.legs.first(where: { $0.instrument.kind == .stock }))
    #expect(audLeg.quantity == negSixThreeFourFive)
    #expect(stockLeg.instrument == bhp)
    #expect(stockLeg.quantity == Decimal(150))
  }

  @Test("three-leg trade with fee in third instrument persists each leg")
  func testThreeLegTradeWithForeignFeePersistsAllLegs() async throws {
    let repository = try makeContractCloudKitTransactionRepository()
    let accountId = UUID()
    let feeCategoryId = UUID()
    let aapl = Instrument.stock(ticker: "AAPL", exchange: "NASDAQ", name: "Apple")
    let negEighteenFiftyFive = try #require(Decimal(string: "-1855.00"))
    let negSevenFifty = try #require(Decimal(string: "-7.50"))
    // Sell USD, buy AAPL, fee in AUD — three distinct instruments across legs.
    let trade = Transaction(
      date: Date(),
      payee: "Buy 10 Apple",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .USD,
          quantity: negEighteenFiftyFive, type: .transfer),
        TransactionLeg(
          accountId: accountId, instrument: aapl, quantity: Decimal(10), type: .transfer),
        TransactionLeg(
          accountId: accountId, instrument: .AUD,
          quantity: negSevenFifty, type: .expense,
          categoryId: feeCategoryId),
      ]
    )

    let created = try await repository.create(trade)
    #expect(created.legs.count == 3)

    let page = try await repository.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0,
      pageSize: 10
    )
    let fetched = try #require(page.transactions.first(where: { $0.id == created.id }))
    #expect(fetched.legs.count == 3)
    let instrumentIds = Set(fetched.legs.map { $0.instrument.id })
    #expect(instrumentIds == [Instrument.USD.id, aapl.id, Instrument.AUD.id])
    let feeLeg = try #require(fetched.legs.first(where: { $0.type == .expense }))
    #expect(feeLeg.instrument == .AUD)
    #expect(feeLeg.categoryId == feeCategoryId)
  }

  @Test("filter by accountId returns transactions regardless of leg instrument")
  func testFilterByAccountReturnsMultiInstrumentTransactions() async throws {
    let accountId = UUID()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let initial = try Self.makeMultiInstrumentFixtures(accountId: accountId, bhp: bhp)
    let repository = try makeContractCloudKitTransactionRepository(initialTransactions: initial)

    let page = try await repository.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0,
      pageSize: 50
    )
    #expect(page.transactions.count == 3)
    // Union of instruments across all legs on this account must include fiat + stock.
    let allInstruments = Set(page.transactions.flatMap { $0.legs.map(\.instrument.id) })
    #expect(allInstruments.contains(Instrument.AUD.id))
    #expect(allInstruments.contains(Instrument.USD.id))
    #expect(allInstruments.contains(bhp.id))
  }

  /// Seed: AUD opening balance, an AUD→USD FX transfer, and an AUD→BHP stock
  /// buy — on the same account. Used by the account-filter assertion above.
  private static func makeMultiInstrumentFixtures(
    accountId: UUID, bhp: Instrument
  ) throws -> [Transaction] {
    let calendar = Calendar.current
    let jan5 = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 5)))
    let jan10 = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 10)))
    let jan15 = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 15)))
    let tenThousand = try #require(Decimal(string: "10000.00"))
    let negOneThousand = try #require(Decimal(string: "-1000.00"))
    let sixFifty = try #require(Decimal(string: "650.00"))
    let negFourTwoThirty = try #require(Decimal(string: "-4230.00"))
    return [
      Transaction(
        date: jan5, payee: "Opening AUD",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .AUD,
            quantity: tenThousand, type: .openingBalance)
        ]),
      Transaction(
        date: jan10, payee: "FX",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .AUD,
            quantity: negOneThousand, type: .transfer),
          TransactionLeg(
            accountId: accountId, instrument: .USD,
            quantity: sixFifty, type: .transfer),
        ]),
      Transaction(
        date: jan15, payee: "Buy 100 BHP",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .AUD,
            quantity: negFourTwoThirty, type: .transfer),
          TransactionLeg(
            accountId: accountId, instrument: bhp, quantity: Decimal(100), type: .transfer),
        ]),
    ]
  }
}
