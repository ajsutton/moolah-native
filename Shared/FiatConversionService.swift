import Foundation

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
    // Frankfurter has no future rates. Forecast and scheduled-transaction
    // call sites legitimately pass `transaction.date` which can be in the
    // future — clamp to today so we resolve against the latest available
    // rate instead of throwing. See guides/INSTRUMENT_CONVERSION_GUIDE.md
    // Rule 7.
    let effectiveDate = min(date, Date())
    let rate = try await exchangeRates.rate(from: from, to: to, on: effectiveDate)
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
