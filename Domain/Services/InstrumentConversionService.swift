import Foundation

/// Converts quantities between instruments. Phase 2: fiat-to-fiat only.
/// Phase 3+ will add stock and crypto conversion paths.
protocol InstrumentConversionService: Sendable {
  /// Convert a raw quantity from one instrument to another on a given date.
  func convert(
    _ quantity: Decimal,
    from: Instrument,
    to: Instrument,
    on date: Date
  ) async throws -> Decimal

  /// Convenience: convert an InstrumentAmount to a different instrument.
  func convertAmount(
    _ amount: InstrumentAmount,
    to instrument: Instrument,
    on date: Date
  ) async throws -> InstrumentAmount
}

/// Fiat-to-fiat conversion backed by ExchangeRateService.
actor FiatConversionService: InstrumentConversionService {
  private let exchangeRates: ExchangeRateService

  init(exchangeRates: ExchangeRateService) {
    self.exchangeRates = exchangeRates
  }

  func convert(
    _ quantity: Decimal,
    from: Instrument,
    to: Instrument,
    on date: Date
  ) async throws -> Decimal {
    guard from != to else { return quantity }
    guard from.kind == .fiatCurrency, to.kind == .fiatCurrency else {
      throw ConversionError.unsupportedInstrumentKind
    }
    let rate = try await exchangeRates.rate(from: from, to: to, on: date)
    return quantity * rate
  }

  func convertAmount(
    _ amount: InstrumentAmount,
    to instrument: Instrument,
    on date: Date
  ) async throws -> InstrumentAmount {
    guard amount.instrument != instrument else { return amount }
    let converted = try await convert(
      amount.quantity, from: amount.instrument, to: instrument, on: date
    )
    return InstrumentAmount(quantity: converted, instrument: instrument)
  }
}

enum ConversionError: Error, Equatable {
  case unsupportedInstrumentKind
}
