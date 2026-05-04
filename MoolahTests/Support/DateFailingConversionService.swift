import Foundation

@testable import Moolah

// Visibility is internal (was fileprivate) so sibling test files across the
// split AnalysisRepository* test suites can use this helper — `strict_fileprivate`
// disallows fileprivate in this codebase.
//
// Conversion service whose per-date failures can be specified at construction.
// Used to exercise Rule 11 scoping when a single day's rate is unavailable.
//
// `convert(_:from:to:on:)` throws `DateFailingConversionError.unavailable` when
// the requested conversion date (normalized to start-of-day) is in
// `failingDates`. Same-instrument conversions always succeed. Otherwise
// behaves like `DateBasedFixedConversionService`.
struct DateFailingConversionService: InstrumentConversionService {
  let rates: [Date: [String: Decimal]]
  /// Entries must be `Calendar.current.startOfDay`-normalised so
  /// they line up with how production callers compute their
  /// `dayKey` (`applyInvestmentValues`,
  /// `applyTradesModePositionValuations`). The service no longer
  /// re-normalises the `on:` argument inside `convert(...)` — a
  /// second `startOfDay` call with a non-Gregorian calendar would
  /// silently disagree with the caller's `Calendar.current`-keyed
  /// `failingDates`, turning Rule 10 regressions into false-greens.
  let failingDates: Set<Date>
  private let sortedRateEntries: [(date: Date, rates: [String: Decimal])]

  init(rates: [Date: [String: Decimal]], failingDates: Set<Date>) {
    self.rates = rates
    self.failingDates = failingDates
    self.sortedRateEntries =
      rates
      .map { (date: $0.key, rates: $0.value) }
      .sorted { $0.date > $1.date }
  }

  private func ratesAsOf(_ date: Date) -> [String: Decimal] {
    for entry in sortedRateEntries where entry.date <= date {
      return entry.rates
    }
    return [:]
  }

  func convert(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) async throws -> Decimal {
    if from.id == to.id { return quantity }
    if failingDates.contains(date) {
      throw DateFailingConversionError.unavailable(date: date)
    }
    let asOf = ratesAsOf(date)
    guard let rate = asOf[from.id] else {
      return quantity
    }
    return quantity * rate
  }

  func convertAmount(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> InstrumentAmount {
    guard amount.instrument != instrument else { return amount }
    let converted = try await convert(
      amount.quantity, from: amount.instrument, to: instrument, on: date)
    return InstrumentAmount(quantity: converted, instrument: instrument)
  }
}

enum DateFailingConversionError: Error, Equatable {
  case unavailable(date: Date)
}
