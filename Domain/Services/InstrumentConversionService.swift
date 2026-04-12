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

/// Full conversion service supporting fiat-to-fiat and stock-to-fiat conversions.
/// Stock-to-fiat routes through StockPriceService for price lookup, then ExchangeRateService
/// if the listing currency differs from the target fiat.
actor FullConversionService: InstrumentConversionService {
  private let exchangeRates: ExchangeRateService
  private let stockPrices: StockPriceService

  init(exchangeRates: ExchangeRateService, stockPrices: StockPriceService) {
    self.exchangeRates = exchangeRates
    self.stockPrices = stockPrices
  }

  func convert(
    _ quantity: Decimal,
    from source: Instrument,
    to target: Instrument,
    on date: Date
  ) async throws -> Decimal {
    // Fiat → Fiat
    if source.kind == .fiatCurrency && target.kind == .fiatCurrency {
      guard source != target else { return quantity }
      let rate = try await exchangeRates.rate(from: source, to: target, on: date)
      return quantity * rate
    }

    // Stock → Fiat: price lookup + optional FX
    if source.kind == .stock && target.kind == .fiatCurrency {
      guard let ticker = source.ticker else {
        throw ConversionError.unsupportedConversion(from: source.id, to: target.id)
      }
      let pricePerShare = try await stockPrices.price(ticker: ticker, on: date)
      let listingInstrument = try await stockPrices.instrument(for: ticker)
      let valueInListingCurrency = quantity * pricePerShare

      // If listing currency matches target, done
      if listingInstrument.id == target.id {
        return valueInListingCurrency
      }

      // Otherwise convert listing currency → target fiat
      let rate = try await exchangeRates.rate(from: listingInstrument, to: target, on: date)
      return valueInListingCurrency * rate
    }

    throw ConversionError.unsupportedConversion(from: source.id, to: target.id)
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
  case unsupportedConversion(from: String, to: String)
}
