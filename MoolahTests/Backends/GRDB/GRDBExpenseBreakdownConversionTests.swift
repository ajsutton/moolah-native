// MoolahTests/Backends/GRDB/GRDBExpenseBreakdownConversionTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Date-sensitive conversion tests for `GRDBAnalysisRepository.fetchExpenseBreakdown`.
///
/// The SQL rewrite for §3.4.2 of the GRDB slice plan groups by
/// `(DATE(t.date), category_id, instrument_id)` so per-day grouping is
/// rate-equivalent to the per-leg conversion the SwiftData implementation
/// performed. These tests pin that the right calendar day is fed into the
/// `InstrumentConversionService` per row — a regression that drops the
/// `DATE(t.date)` projection (collapsing to per-month or per-range
/// grouping) would silently pass against constant-rate fixtures.
///
/// Uses `DateBasedFixedConversionService`, which returns a different rate
/// per calendar day, to detect such regressions.
@Suite("GRDBAnalysisRepository expense breakdown — date-sensitive conversion")
struct GRDBExpenseBreakdownConversionTests {

  /// UTC-anchored date constructor.
  ///
  /// Both the transaction dates **and** the
  /// `DateBasedFixedConversionService` seed keys must agree on which
  /// UTC calendar day they represent so the test produces the same
  /// answer in any local timezone. SQL's `DATE(t.date)` extracts the
  /// UTC date of the stored timestamp — anchoring the txn at
  /// UTC noon (`hour: 12`) keeps that UTC date stable regardless of
  /// viewer timezone, and the seeds use UTC midnight on the same day
  /// so `ratesAsOf`'s `<=` walk lands on the intended rate dict.
  private static func utcDate(
    year: Int, month: Int, day: Int, hour: Int = 0
  ) throws -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    return try #require(
      calendar.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour)))
  }

  @Test("expense breakdown converts each day's USD legs at that day's rate")
  func expenseBreakdownConvertsPerDayRate() async throws {
    // Two consecutive UTC days with different USD→AUD rates. The legs are
    // identical USD expenses; if SQL grouping collapses days into a single
    // bucket, both legs would convert at the same rate and the totals
    // would diverge from the per-day truth.
    let dayOne = try Self.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayTwo = try Self.utcDate(year: 2025, month: 6, day: 11, hour: 12)
    let rateOne = try AnalysisTestHelpers.decimal("1.5")
    let rateTwo = try AnalysisTestHelpers.decimal("2.0")

    // Seed at UTC midnight for each transaction's UTC calendar day so
    // `ratesAsOf`'s descending `<=` scan lands on the right rate per
    // parsed-day Date.
    let conversion = DateBasedFixedConversionService(
      rates: [
        try Self.utcDate(year: 2025, month: 6, day: 10): ["USD": rateOne],
        try Self.utcDate(year: 2025, month: 6, day: 11): ["USD": rateTwo],
      ])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let account = Account(
      id: UUID(), name: "USD Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(category)

    let usd = Instrument.fiat(code: "USD")

    _ = try await backend.transactions.create(
      Transaction(
        date: dayOne, payee: "US Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: -100, type: .expense, categoryId: category.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: dayTwo, payee: "US Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: -100, type: .expense, categoryId: category.id)
        ]))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    // Both transactions land in the same financial month (June, monthEnd
    // 25), so they collapse into one breakdown row. The total uses each
    // day's own rate: -100 * 1.5 + -100 * 2.0 = -350.
    #expect(breakdown.count == 1)
    #expect(breakdown[0].categoryId == category.id)
    #expect(breakdown[0].totalExpenses.quantity == -350)
    #expect(breakdown[0].totalExpenses.instrument == .defaultTestInstrument)
  }

  @Test("expense breakdown groups same-day legs into one conversion")
  func expenseBreakdownSameDaySingleConversion() async throws {
    // Three legs on the same day — the SQL `GROUP BY (day, category, instrument)`
    // sums their quantities into one bucket so the conversion runs once per
    // (day, category, instrument) tuple, not once per leg. Functionally
    // identical to per-leg conversion at this rate (same day = same rate).
    let day = try Self.utcDate(year: 2025, month: 7, day: 5, hour: 12)
    let rate = try AnalysisTestHelpers.decimal("1.5")
    let conversion = DateBasedFixedConversionService(
      rates: [try Self.utcDate(year: 2025, month: 7, day: 5): ["USD": rate]])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let account = Account(
      id: UUID(), name: "USD Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(category)

    let usd = Instrument.fiat(code: "USD")

    for index in 0..<3 {
      _ = try await backend.transactions.create(
        Transaction(
          date: day, payee: "Store \(index)",
          legs: [
            TransactionLeg(
              accountId: account.id, instrument: usd,
              quantity: -50, type: .expense, categoryId: category.id)
          ]))
    }

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    #expect(breakdown.count == 1)
    #expect(breakdown[0].categoryId == category.id)
    // Three -50 USD legs summed to -150 USD; converted at 1.5x = -225 AUD.
    #expect(breakdown[0].totalExpenses.quantity == -225)
  }
}
