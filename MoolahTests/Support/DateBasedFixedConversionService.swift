import Foundation

@testable import Moolah

/// Test-only conversion service that returns date-aware fixed rates.
///
/// Unlike `FixedConversionService` (which is rate-per-currency only), this
/// service maps a date to a per-currency rate dict. Lookup picks the entry
/// whose date is the most recent date <= the requested date (i.e. the
/// effective rate "as of" that date). Used by analysis tests that exercise
/// "rate changes over time" scenarios.
///
/// Same-instrument conversions short-circuit to the input quantity.
/// Currencies with no rate at the requested date fall back 1:1.
struct DateBasedFixedConversionService: InstrumentConversionService {
  /// (date → (currencyCode → rate)) where the rate converts FROM that
  /// currency code TO the profile instrument.
  let rates: [Date: [String: Decimal]]
  private let sortedDates: [Date]

  /// - Parameter rates: Map of effective-from date to currency-code rates.
  init(rates: [Date: [String: Decimal]]) {
    self.rates = rates
    self.sortedDates = rates.keys.sorted(by: >)  // descending for fast lookup
  }

  /// Find the rate dict whose key is the most recent date <= the requested date.
  private func ratesAsOf(_ date: Date) -> [String: Decimal] {
    for d in sortedDates where d <= date {
      return rates[d]!
    }
    return [:]
  }

  func convert(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) async throws -> Decimal {
    if from.id == to.id { return quantity }
    let asOf = ratesAsOf(date)
    guard let rate = asOf[from.id] else {
      return quantity  // 1:1 fallback when no rate found
    }
    return quantity * rate
  }

  func convertAmount(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> InstrumentAmount {
    guard amount.instrument != instrument else { return amount }
    let converted = try await convert(
      amount.quantity, from: amount.instrument, to: instrument, on: date
    )
    return InstrumentAmount(quantity: converted, instrument: instrument)
  }
}
