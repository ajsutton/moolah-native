import Foundation

@testable import Moolah

/// Test double for InstrumentConversionService. Returns fixed rates for non-profile instruments.
///
/// Pass `knownZeroInstrumentIds` to mark source instruments whose
/// `convertResult(...)` should return `.knownZero` — modelling
/// `.unpriced` / `.spam` crypto registrations under issue #790. Their
/// `convert(...)` / `convertAmount(...)` calls still throw to keep the
/// "real provider failure" path distinct, mirroring how a registration
/// without a provider mapping behaves in production.
struct FixedConversionService: InstrumentConversionService {
  let rates: [String: Decimal]
  let knownZeroInstrumentIds: Set<String>

  init(rates: [String: Decimal] = [:], knownZeroInstrumentIds: Set<String> = []) {
    self.rates = rates
    self.knownZeroInstrumentIds = knownZeroInstrumentIds
  }

  func convert(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) async throws -> Decimal {
    if from.id == to.id { return quantity }
    if knownZeroInstrumentIds.contains(from.id) {
      throw FixedConversionError.knownZeroSource(instrumentId: from.id)
    }
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

  func convertResult(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> ConversionResult {
    if amount.instrument == instrument {
      return .value(amount)
    }
    if knownZeroInstrumentIds.contains(amount.instrument.id) {
      return .knownZero(targetInstrument: instrument)
    }
    let converted = try await convertAmount(amount, to: instrument, on: date)
    return .value(converted)
  }

  func invalidateCache(for instrument: Instrument) async {}
}

/// Surfaces only when a test marks an instrument as `.knownZero` and a
/// caller invokes `convert` / `convertAmount` rather than `convertResult`.
/// Mirrors the production "no provider mapping" failure for
/// `.unpriced` / `.spam` registrations.
enum FixedConversionError: Error, Equatable {
  case knownZeroSource(instrumentId: String)
}
