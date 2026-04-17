import Foundation

@testable import Moolah

/// Test conversion service whose per-instrument failures can be toggled at
/// runtime. Used to exercise partial-success and retry behaviour in stores
/// that drive sidebar totals.
///
/// `convert(_:from:to:on:)` throws `FailingConversionError.unavailable` when
/// either side of the conversion involves an instrument id in
/// `failingInstrumentIds`. Same-instrument conversions always succeed.
/// Otherwise, behaves like `FixedConversionService` (rates lookup, 1:1 fallback).
actor FailingConversionService: InstrumentConversionService {
  private let rates: [String: Decimal]
  private(set) var failingInstrumentIds: Set<String>

  init(rates: [String: Decimal] = [:], failingInstrumentIds: Set<String> = []) {
    self.rates = rates
    self.failingInstrumentIds = failingInstrumentIds
  }

  func setFailing(_ ids: Set<String>) {
    failingInstrumentIds = ids
  }

  func convert(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) async throws -> Decimal {
    if from.id == to.id { return quantity }
    if failingInstrumentIds.contains(from.id) {
      throw FailingConversionError.unavailable(instrumentId: from.id)
    }
    if failingInstrumentIds.contains(to.id) {
      throw FailingConversionError.unavailable(instrumentId: to.id)
    }
    guard let rate = rates[from.id] else {
      return quantity
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

enum FailingConversionError: Error, Equatable {
  case unavailable(instrumentId: String)
}
