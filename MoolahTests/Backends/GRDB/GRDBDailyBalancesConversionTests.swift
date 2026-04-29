import Foundation
import GRDB
import Testing

@testable import Moolah

/// Date-sensitive conversion tests for `GRDBAnalysisRepository.fetchDailyBalances`.
///
/// The SQL aggregation drives a per-day `PositionBook.dailyBalance(...)`
/// call, which converts each per-`(account, instrument)` position to
/// the profile instrument on the day's `Date`. These tests pin that
/// the right calendar day is fed into the `InstrumentConversionService`
/// per day — a regression that converted every day at a single
/// snapshot date (e.g. `Date()`) would silently pass against the
/// constant-rate `FixedConversionService` used by other contract suites.
///
/// Uses `DateBasedFixedConversionService`, which returns a different
/// rate per calendar day, to detect such regressions.
@Suite("GRDBAnalysisRepository daily balances — date-sensitive conversion")
struct GRDBDailyBalancesConversionTests {

  @Test("daily balances convert each day's USD position at that day's rate")
  func dailyBalancesConvertPerDayRate() async throws {
    // Two consecutive UTC days with different USD→AUD rates. The legs
    // are identical USD income; if the per-day conversion collapses to
    // a single snapshot date, both days' balances would convert at the
    // same rate and diverge from the per-day truth.
    let dayOne = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayTwo = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 11, hour: 12)
    let rateOne = try AnalysisTestHelpers.decimal("1.5")
    let rateTwo = try AnalysisTestHelpers.decimal("2.0")

    // Seed at UTC midnight for each day so `ratesAsOf`'s descending
    // `<=` scan lands on the right rate per parsed-day Date.
    let conversion = DateBasedFixedConversionService(
      rates: [
        try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 0): [
          "USD": rateOne
        ],
        try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 11, hour: 0): [
          "USD": rateTwo
        ],
      ])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let account = Account(
      id: UUID(), name: "USD Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let usd = Instrument.fiat(code: "USD")

    _ = try await backend.transactions.create(
      Transaction(
        date: dayOne, payee: "US Salary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: 100, type: .income)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: dayTwo, payee: "US Salary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: 100, type: .income)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(
      after: nil, forecastUntil: nil)

    // `balance` is cumulative: day 1 sees one USD 100 position
    // (100 * 1.5 = 150); day 2 sees two USD 100 positions accumulated
    // (200 * 2.0 = 400). A bug that converted both days at the same
    // snapshot rate `r` would yield 100*r and 200*r — only matching
    // 150/400 if r = 1.5/2.0 (impossible) or by coincidence on a
    // 1:1-fallback date.
    let dayOneStart = AnalysisTestHelpers.calendar.startOfDay(for: dayOne)
    let dayTwoStart = AnalysisTestHelpers.calendar.startOfDay(for: dayTwo)
    let dayOneBalance = try #require(balances.first { $0.date == dayOneStart })
    let dayTwoBalance = try #require(balances.first { $0.date == dayTwoStart })
    #expect(dayOneBalance.balance.quantity == 150)
    #expect(dayTwoBalance.balance.quantity == 400)
    #expect(dayOneBalance.balance.instrument == .defaultTestInstrument)
    #expect(dayTwoBalance.balance.instrument == .defaultTestInstrument)
  }

  @Test("daily balances sum multi-instrument positions per their own day's rate")
  func dailyBalancesMultiInstrumentSameDay() async throws {
    // Two foreign-instrument legs on the same day must convert with the
    // day's rates and sum into a single profile-instrument balance.
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let usdRate = try AnalysisTestHelpers.decimal("1.5")
    let eurRate = try AnalysisTestHelpers.decimal("1.7")
    let conversion = DateBasedFixedConversionService(
      rates: [
        try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 0): [
          "USD": usdRate, "EUR": eurRate,
        ]
      ])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let usdAccount = Account(
      id: UUID(), name: "USD", type: .bank, instrument: .defaultTestInstrument)
    let eurAccount = Account(
      id: UUID(), name: "EUR", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(usdAccount)
    _ = try await backend.accounts.create(eurAccount)

    let usd = Instrument.fiat(code: "USD")
    let eur = Instrument.fiat(code: "EUR")

    _ = try await backend.transactions.create(
      Transaction(
        date: day, payee: "USD Income",
        legs: [
          TransactionLeg(
            accountId: usdAccount.id, instrument: usd,
            quantity: 100, type: .income)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: day, payee: "EUR Income",
        legs: [
          TransactionLeg(
            accountId: eurAccount.id, instrument: eur,
            quantity: 100, type: .income)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(
      after: nil, forecastUntil: nil)

    // Per-day USD * 1.5 + EUR * 1.7 = 150 + 170 = 320.
    let dayStart = AnalysisTestHelpers.calendar.startOfDay(for: day)
    let dayBalance = try #require(balances.first { $0.date == dayStart })
    #expect(dayBalance.balance.quantity == 320)
    #expect(dayBalance.balance.instrument == .defaultTestInstrument)
  }
}
