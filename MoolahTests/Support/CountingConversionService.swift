import Foundation

@testable import Moolah

/// Test conversion service that records every `convertAmount` call for
/// assertions about how many round-trips a caller makes. Math behaves like
/// `FixedConversionService` (rates keyed by source instrument id, 1:1
/// fallback).
actor CountingConversionService: InstrumentConversionService {
  private let rates: [String: Decimal]
  private(set) var convertAmountCallCount: Int = 0

  init(rates: [String: Decimal] = [:]) {
    self.rates = rates
  }

  func convert(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) async throws -> Decimal {
    if from.id == to.id { return quantity }
    guard let rate = rates[from.id] else { return quantity }
    return quantity * rate
  }

  func convertAmount(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> InstrumentAmount {
    convertAmountCallCount += 1
    guard amount.instrument != instrument else { return amount }
    let converted = try await convert(
      amount.quantity, from: amount.instrument, to: instrument, on: date
    )
    return InstrumentAmount(quantity: converted, instrument: instrument)
  }
}
