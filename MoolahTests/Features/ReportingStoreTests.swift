import Foundation
import Testing

@testable import Moolah

// Swift Testing's `@Test func foo()` is the documented idiom, and
// swift-format's `lineBreakBetweenDeclarationAttributes: false` keeps the
// attribute inline. Disable SwiftLint's `attributes` rule in this file so
// the formatter and the linter don't fight over the same layout.
// swiftlint:disable attributes

@Suite("ReportingStore")
struct ReportingStoreTests {
  let aud = Instrument.fiat(code: "AUD")

  @Test @MainActor func loadProfitLoss_populatesState() async throws {
    let (backend, container) = try TestBackend.create()
    let account = Account(
      id: UUID(), name: "Brokerage", type: .bank, instrument: .defaultTestInstrument
    )
    TestBackend.seed(accounts: [account], in: container)

    let bhp = Instrument(
      id: "ASX:BHP", kind: .stock, name: "BHP", decimals: 0,
      ticker: "BHP.AX", exchange: "ASX", chainId: nil, contractAddress: nil)

    let buyTx = Transaction(
      date: Date(),
      payee: "Buy BHP",
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: aud, quantity: -4000, type: .transfer),
        TransactionLeg(
          accountId: account.id, instrument: bhp, quantity: 100, type: .transfer),
      ]
    )
    TestBackend.seed(transactions: [buyTx], in: container)

    let service = FixedConversionService(rates: ["ASX:BHP": 50])
    let store = ReportingStore(
      transactionRepository: backend.transactions,
      conversionService: service,
      profileCurrency: aud
    )

    await store.loadProfitLoss()

    #expect(!store.isLoading)
    #expect(store.error == nil)
    #expect(store.profitLoss.count == 1)
    #expect(store.profitLoss[0].instrument.id == "ASX:BHP")
    #expect(store.profitLoss[0].totalInvested == 4000)
    #expect(store.profitLoss[0].currentValue == 5000)
    #expect(store.profitLoss[0].unrealizedGain == 1000)
  }

  @Test @MainActor func loadCapitalGains_forFinancialYear() async throws {
    let (backend, container) = try TestBackend.create()
    let account = Account(
      id: UUID(), name: "Brokerage", type: .bank, instrument: .defaultTestInstrument
    )
    TestBackend.seed(accounts: [account], in: container)

    let bhp = Instrument(
      id: "ASX:BHP", kind: .stock, name: "BHP", decimals: 0,
      ticker: "BHP.AX", exchange: "ASX", chainId: nil, contractAddress: nil)

    let calendar = Calendar(identifier: .gregorian)
    // Buy in early FY2026 (August 2025)
    let buyDate = calendar.date(from: DateComponents(year: 2025, month: 8, day: 1))!
    let buyTx = Transaction(
      date: buyDate,
      payee: "Buy BHP",
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: aud, quantity: -4000, type: .transfer),
        TransactionLeg(
          accountId: account.id, instrument: bhp, quantity: 100, type: .transfer),
      ]
    )

    // Sell in late FY2026 (May 2026)
    let sellDate = calendar.date(from: DateComponents(year: 2026, month: 5, day: 1))!
    let sellTx = Transaction(
      date: sellDate,
      payee: "Sell BHP",
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: bhp, quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: account.id, instrument: aud, quantity: 5000, type: .transfer),
      ]
    )
    TestBackend.seed(transactions: [buyTx, sellTx], in: container)

    let store = ReportingStore(
      transactionRepository: backend.transactions,
      conversionService: FixedConversionService(rates: [:]),
      profileCurrency: aud
    )

    await store.loadCapitalGains(financialYear: 2026)

    #expect(!store.isLoading)
    #expect(store.error == nil)
    #expect(store.capitalGainsResult != nil)
    #expect(store.capitalGainsResult?.events.count == 1)
    #expect(store.capitalGainsResult?.totalRealizedGain == 1000)
    #expect(store.capitalGainsSummary != nil)
    #expect(store.capitalGainsSummary?.eventCount == 1)
  }

  @Test @MainActor func capitalGainsSummary_separatesShortAndLongTerm() async throws {
    let (backend, container) = try TestBackend.create()
    let account = Account(
      id: UUID(), name: "Brokerage", type: .bank, instrument: .defaultTestInstrument
    )
    TestBackend.seed(accounts: [account], in: container)
    TestBackend.seed(
      transactions: makeShortAndLongTermGainsFixture(accountId: account.id), in: container)

    let store = ReportingStore(
      transactionRepository: backend.transactions,
      conversionService: FixedConversionService(rates: [:]),
      profileCurrency: aud
    )

    await store.loadCapitalGains(financialYear: 2026)

    let summary = store.capitalGainsSummary
    #expect(summary != nil)
    // BHP: long-term gain = 1000 (5000 - 4000)
    #expect(summary?.longTermGain == 1000)
    // CBA: short-term gain = 1000 (6000 - 5000)
    #expect(summary?.shortTermGain == 1000)
    #expect(summary?.totalGain == 2000)
  }

  /// Two stocks (BHP bought long-term before the window, CBA bought
  /// short-term inside the window) both sold on the same day in FY2026.
  private func makeShortAndLongTermGainsFixture(accountId: UUID) -> [Transaction] {
    let bhp = Instrument(
      id: "ASX:BHP", kind: .stock, name: "BHP", decimals: 0,
      ticker: "BHP.AX", exchange: "ASX", chainId: nil, contractAddress: nil)
    let cba = Instrument(
      id: "ASX:CBA", kind: .stock, name: "CBA", decimals: 0,
      ticker: "CBA.AX", exchange: "ASX", chainId: nil, contractAddress: nil)

    let calendar = Calendar(identifier: .gregorian)
    let buyBHPDate = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
    let buyCBADate = calendar.date(from: DateComponents(year: 2025, month: 10, day: 1))!
    let sellDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!

    return [
      Transaction(
        date: buyBHPDate, payee: "Buy BHP",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: aud, quantity: -4000, type: .transfer),
          TransactionLeg(
            accountId: accountId, instrument: bhp, quantity: 100, type: .transfer),
        ]),
      Transaction(
        date: buyCBADate, payee: "Buy CBA",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: aud, quantity: -5000, type: .transfer),
          TransactionLeg(
            accountId: accountId, instrument: cba, quantity: 50, type: .transfer),
        ]),
      Transaction(
        date: sellDate, payee: "Sell BHP",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: bhp, quantity: -100, type: .transfer),
          TransactionLeg(
            accountId: accountId, instrument: aud, quantity: 5000, type: .transfer),
        ]),
      Transaction(
        date: sellDate, payee: "Sell CBA",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: cba, quantity: -50, type: .transfer),
          TransactionLeg(
            accountId: accountId, instrument: aud, quantity: 6000, type: .transfer),
        ]),
    ]
  }

  @Test func capitalGainsSummary_taxAdjustmentValues() {
    let summary = CapitalGainsSummary(
      shortTermGain: 500,
      longTermGain: 1000,
      totalGain: 1500,
      eventCount: 2
    )

    let values = summary.asTaxAdjustmentValues(currency: aud)
    #expect(values.shortTerm.quantity == 500)
    #expect(values.longTerm.quantity == 1000)
    #expect(values.losses.quantity == 0)
  }

  @Test func capitalGainsSummary_taxAdjustmentValues_withLosses() {
    let summary = CapitalGainsSummary(
      shortTermGain: -200,
      longTermGain: 1000,
      totalGain: 800,
      eventCount: 3
    )

    let values = summary.asTaxAdjustmentValues(currency: aud)
    #expect(values.shortTerm.quantity == 0)
    #expect(values.longTerm.quantity == 1000)
    #expect(values.losses.quantity == 200)
  }

  @Test func capitalGainsSummary_cgtDiscount() {
    let summary = CapitalGainsSummary(
      shortTermGain: 0,
      longTermGain: 1000,
      totalGain: 1000,
      eventCount: 1
    )
    // 50% CGT discount on long-term gains
    #expect(summary.discountedLongTermGain == 500)
    #expect(summary.netCapitalGain == 500)
  }

  // MARK: - Multi-instrument profit/loss

  @Test @MainActor func loadProfitLoss_aggregatesMultipleStockInstruments() async throws {
    let (backend, container) = try TestBackend.create()
    let account = Account(
      id: UUID(), name: "Brokerage", type: .bank, instrument: .defaultTestInstrument
    )
    TestBackend.seed(accounts: [account], in: container)

    let bhp = Instrument(
      id: "ASX:BHP", kind: .stock, name: "BHP", decimals: 0,
      ticker: "BHP.AX", exchange: "ASX", chainId: nil, contractAddress: nil)
    let cba = Instrument(
      id: "ASX:CBA", kind: .stock, name: "CBA", decimals: 0,
      ticker: "CBA.AX", exchange: "ASX", chainId: nil, contractAddress: nil)

    let buyBHP = Transaction(
      date: Date(),
      payee: "Buy BHP",
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: aud, quantity: -4000, type: .transfer),
        TransactionLeg(
          accountId: account.id, instrument: bhp, quantity: 100, type: .transfer),
      ]
    )
    let buyCBA = Transaction(
      date: Date(),
      payee: "Buy CBA",
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: aud, quantity: -5000, type: .transfer),
        TransactionLeg(
          accountId: account.id, instrument: cba, quantity: 50, type: .transfer),
      ]
    )
    TestBackend.seed(transactions: [buyBHP, buyCBA], in: container)

    // BHP worth $50/share → 5000, CBA worth $120/share → 6000
    let service = FixedConversionService(rates: ["ASX:BHP": 50, "ASX:CBA": 120])
    let store = ReportingStore(
      transactionRepository: backend.transactions,
      conversionService: service,
      profileCurrency: aud
    )

    await store.loadProfitLoss()

    #expect(store.profitLoss.count == 2)
    let bhpPL = try #require(store.profitLoss.first { $0.instrument.id == "ASX:BHP" })
    let cbaPL = try #require(store.profitLoss.first { $0.instrument.id == "ASX:CBA" })
    #expect(bhpPL.totalInvested == 4000)
    #expect(bhpPL.currentValue == 5000)
    #expect(cbaPL.totalInvested == 5000)
    #expect(cbaPL.currentValue == 6000)
  }

  @Test @MainActor func loadProfitLoss_tracksStockAndCryptoInSamePortfolio() async throws {
    let (backend, container) = try TestBackend.create()
    let account = Account(
      id: UUID(), name: "Hybrid", type: .bank, instrument: .defaultTestInstrument
    )
    TestBackend.seed(accounts: [account], in: container)

    let bhp = Instrument(
      id: "ASX:BHP", kind: .stock, name: "BHP", decimals: 0,
      ticker: "BHP.AX", exchange: "ASX", chainId: nil, contractAddress: nil)
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )

    let txns = [
      Transaction(
        date: Date(),
        payee: "Buy BHP",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: aud, quantity: -4000, type: .transfer),
          TransactionLeg(
            accountId: account.id, instrument: bhp, quantity: 100, type: .transfer),
        ]),
      Transaction(
        date: Date(),
        payee: "Buy ETH",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: aud, quantity: -2000, type: .transfer),
          TransactionLeg(
            accountId: account.id, instrument: eth,
            quantity: Decimal(string: "1.0")!, type: .transfer),
        ]),
    ]
    TestBackend.seed(transactions: txns, in: container)

    let service = FixedConversionService(rates: ["ASX:BHP": 50, eth.id: 2500])
    let store = ReportingStore(
      transactionRepository: backend.transactions,
      conversionService: service,
      profileCurrency: aud
    )

    await store.loadProfitLoss()

    #expect(store.profitLoss.count == 2)
    let kinds = Set(store.profitLoss.map { $0.instrument.kind })
    #expect(kinds == [.stock, .cryptoToken])
  }

  @Test @MainActor func loadCategoryBalances_populatesIncomeAndExpense() async throws {
    let (backend, container) = try TestBackend.create()
    let account = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument
    )
    let incomeCategory = Moolah.Category(id: UUID(), name: "Salary")
    let expenseCategory = Moolah.Category(id: UUID(), name: "Groceries")
    TestBackend.seed(accounts: [account], in: container)
    TestBackend.seed(categories: [incomeCategory, expenseCategory], in: container)

    let today = Date()
    TestBackend.seed(
      transactions: [
        Transaction(
          date: today,
          payee: "Employer",
          legs: [
            TransactionLeg(
              accountId: account.id, instrument: .defaultTestInstrument,
              quantity: 1000, type: .income, categoryId: incomeCategory.id)
          ]
        ),
        Transaction(
          date: today,
          payee: "Store",
          legs: [
            TransactionLeg(
              accountId: account.id, instrument: .defaultTestInstrument,
              quantity: -50, type: .expense, categoryId: expenseCategory.id)
          ]
        ),
      ],
      in: container
    )

    let store = ReportingStore(
      transactionRepository: backend.transactions,
      analysisRepository: backend.analysis,
      conversionService: FixedConversionService(),
      profileCurrency: .defaultTestInstrument
    )

    let from = Calendar.current.date(byAdding: .day, value: -1, to: today)!
    let to = Calendar.current.date(byAdding: .day, value: 1, to: today)!
    await store.loadCategoryBalances(dateRange: from...to)

    #expect(!store.isLoadingCategoryBalances)
    #expect(store.categoryBalancesError == nil)
    #expect(store.incomeBalances[incomeCategory.id]?.quantity == 1000)
    #expect(store.expenseBalances[expenseCategory.id]?.quantity == -50)
  }
}

// swiftlint:enable attributes
