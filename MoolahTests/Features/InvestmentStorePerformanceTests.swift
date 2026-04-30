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

  @Test("loadAllData with nil transactionRepository leaves accountPerformance nil")
  func loadAllDataNilTransactionRepositoryLeavesPerformanceNil() async throws {
    let aud = Instrument.AUD
    let (backend, _) = try TestBackend.create()
    // No transaction repository → position-tracked compute can't run; the
    // legacy branch isn't taken either because no investment values were
    // seeded. accountPerformance must stay nil.
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: nil,
      conversionService: backend.conversionService)

    let account = Account(name: "Brokerage", type: .investment, instrument: aud)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 1_000, instrument: aud))

    await store.loadAllData(accountId: account.id, profileCurrency: aud)

    #expect(store.accountPerformance == nil)
  }

  @Test(
    "loadAllData on conversion failure marks accountPerformance unavailable and surfaces the error"
  )
  func loadAllDataConversionFailureMarksUnavailable() async throws {
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let (backend, _) = try TestBackend.create()
    let conversion = FailingConversionService(failingInstrumentIds: [usd.id])
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: conversion)

    let account = Account(name: "Brokerage", type: .investment, instrument: aud)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 0, instrument: aud))

    // Cross-account USD transfer in — calculator must convert USD → AUD.
    // FailingConversionService throws on USD, so compute() throws and the
    // store sets accountPerformance = nil + records the error.
    let cashAccount = UUID()
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(timeIntervalSinceReferenceDate: 0),
        legs: [
          TransactionLeg(
            accountId: cashAccount, instrument: usd, quantity: -100, type: .transfer),
          TransactionLeg(
            accountId: account.id, instrument: usd, quantity: 100, type: .transfer),
        ]
      )
    )

    await store.loadAllData(accountId: account.id, profileCurrency: aud)

    #expect(store.accountPerformance == nil)
    #expect(store.error != nil)
  }
}
