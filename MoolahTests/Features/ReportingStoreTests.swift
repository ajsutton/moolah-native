import Foundation
import Testing

@testable import Moolah

@Suite("ReportingStore")
struct ReportingStoreTests {
  let aud = Instrument.fiat(code: "AUD")

  @Test @MainActor func loadProfitLoss_populatesState() async throws {
    let (backend, container) = try TestBackend.create()
    let account = Account(
      id: UUID(), name: "Brokerage", type: .bank,
      balance: .zero(instrument: aud)
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
      id: UUID(), name: "Brokerage", type: .bank,
      balance: .zero(instrument: aud)
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
      id: UUID(), name: "Brokerage", type: .bank,
      balance: .zero(instrument: aud)
    )
    TestBackend.seed(accounts: [account], in: container)

    let bhp = Instrument(
      id: "ASX:BHP", kind: .stock, name: "BHP", decimals: 0,
      ticker: "BHP.AX", exchange: "ASX", chainId: nil, contractAddress: nil)
    let cba = Instrument(
      id: "ASX:CBA", kind: .stock, name: "CBA", decimals: 0,
      ticker: "CBA.AX", exchange: "ASX", chainId: nil, contractAddress: nil)

    let calendar = Calendar(identifier: .gregorian)
    // Buy BHP early -- will be long-term when sold
    let buyBHPDate = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
    let buyBHP = Transaction(
      date: buyBHPDate,
      payee: "Buy BHP",
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: aud, quantity: -4000, type: .transfer),
        TransactionLeg(
          accountId: account.id, instrument: bhp, quantity: 100, type: .transfer),
      ]
    )

    // Buy CBA late -- will be short-term when sold
    let buyCBADate = calendar.date(from: DateComponents(year: 2025, month: 10, day: 1))!
    let buyCBA = Transaction(
      date: buyCBADate,
      payee: "Buy CBA",
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: aud, quantity: -5000, type: .transfer),
        TransactionLeg(
          accountId: account.id, instrument: cba, quantity: 50, type: .transfer),
      ]
    )

    // Sell both in FY2026
    let sellDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
    let sellBHP = Transaction(
      date: sellDate,
      payee: "Sell BHP",
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: bhp, quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: account.id, instrument: aud, quantity: 5000, type: .transfer),
      ]
    )
    let sellCBA = Transaction(
      date: sellDate,
      payee: "Sell CBA",
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: cba, quantity: -50, type: .transfer),
        TransactionLeg(
          accountId: account.id, instrument: aud, quantity: 6000, type: .transfer),
      ]
    )
    TestBackend.seed(transactions: [buyBHP, buyCBA, sellBHP, sellCBA], in: container)

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

  @Test func capitalGainsSummary_taxAdjustmentValues() {
    let summary = CapitalGainsSummary(
      shortTermGain: 500,
      longTermGain: 1000,
      totalGain: 1500,
      eventCount: 2
    )

    let (shortTerm, longTerm, losses) = summary.asTaxAdjustmentValues(currency: aud)
    #expect(shortTerm.quantity == 500)
    #expect(longTerm.quantity == 1000)
    #expect(losses.quantity == 0)
  }

  @Test func capitalGainsSummary_taxAdjustmentValues_withLosses() {
    let summary = CapitalGainsSummary(
      shortTermGain: -200,
      longTermGain: 1000,
      totalGain: 800,
      eventCount: 3
    )

    let (shortTerm, longTerm, losses) = summary.asTaxAdjustmentValues(currency: aud)
    #expect(shortTerm.quantity == 0)
    #expect(longTerm.quantity == 1000)
    #expect(losses.quantity == 200)
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
}
