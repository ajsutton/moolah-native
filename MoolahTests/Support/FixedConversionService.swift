import Foundation

@testable import Moolah

/// Test double for InstrumentConversionService. Returns fixed rates for non-profile instruments.
struct FixedConversionService: InstrumentConversionService {
  let rates: [String: Decimal]

  init(rates: [String: Decimal] = [:]) {
    self.rates = rates
  }

  func convert(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) async throws -> Decimal {
    if from.id == to.id { return quantity }
    guard let rate = rates[from.id] else {
      return quantity  // Default: 1:1
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
