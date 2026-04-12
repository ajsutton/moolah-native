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

/// Full conversion service supporting fiat-to-fiat, stock-to-fiat, and crypto conversions.
/// Stock-to-fiat routes through StockPriceService for price lookup, then ExchangeRateService
/// if the listing currency differs from the target fiat.
/// Crypto routes through CryptoPriceService (USD prices) then ExchangeRateService for non-USD fiat.
actor FullConversionService: InstrumentConversionService {
  private let exchangeRates: ExchangeRateService
  private let stockPrices: StockPriceService
  private let cryptoPrices: CryptoPriceService?
  private let providerMappingsByInstrumentId: [String: CryptoProviderMapping]

  init(
    exchangeRates: ExchangeRateService,
    stockPrices: StockPriceService,
    cryptoPrices: CryptoPriceService? = nil,
    providerMappings: [CryptoProviderMapping] = []
  ) {
    self.exchangeRates = exchangeRates
    self.stockPrices = stockPrices
    self.cryptoPrices = cryptoPrices
    self.providerMappingsByInstrumentId = Dictionary(
      providerMappings.map { ($0.instrumentId, $0) },
      uniquingKeysWith: { _, last in last }
    )
  }

  func convert(
    _ quantity: Decimal,
    from source: Instrument,
    to target: Instrument,
    on date: Date
  ) async throws -> Decimal {
    if source == target { return quantity }

    switch (source.kind, target.kind) {
    case (.fiatCurrency, .fiatCurrency):
      let rate = try await exchangeRates.rate(from: source, to: target, on: date)
      return quantity * rate

    case (.stock, .fiatCurrency):
      return try await convertStockToFiat(quantity, stock: source, fiat: target, on: date)

    case (.cryptoToken, .fiatCurrency):
      return try await convertCryptoToFiat(quantity, crypto: source, fiat: target, on: date)

    case (.fiatCurrency, .cryptoToken):
      let oneUnitInFiat = try await convertCryptoToFiat(
        Decimal(1), crypto: target, fiat: source, on: date)
      return quantity / oneUnitInFiat

    case (.cryptoToken, .cryptoToken):
      let sourceUsdPrice = try await cryptoUsdPrice(for: source, on: date)
      let targetUsdPrice = try await cryptoUsdPrice(for: target, on: date)
      return (quantity * sourceUsdPrice) / targetUsdPrice

    case (.stock, .cryptoToken), (.cryptoToken, .stock):
      // Chain through USD as intermediate
      let sourceUsd = try await toUsd(quantity, instrument: source, on: date)
      return try await fromUsd(sourceUsd, instrument: target, on: date)

    case (.fiatCurrency, .stock), (.stock, .stock):
      throw ConversionError.unsupportedConversion(from: source.id, to: target.id)
    }
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

  // MARK: - Stock helpers

  private func convertStockToFiat(
    _ quantity: Decimal, stock: Instrument, fiat: Instrument, on date: Date
  ) async throws -> Decimal {
    guard let ticker = stock.ticker else {
      throw ConversionError.unsupportedConversion(from: stock.id, to: fiat.id)
    }
    let pricePerShare = try await stockPrices.price(ticker: ticker, on: date)
    let listingInstrument = try await stockPrices.instrument(for: ticker)
    let valueInListingCurrency = quantity * pricePerShare

    if listingInstrument.id == fiat.id {
      return valueInListingCurrency
    }

    let rate = try await exchangeRates.rate(from: listingInstrument, to: fiat, on: date)
    return valueInListingCurrency * rate
  }

  // MARK: - Crypto helpers

  private func convertCryptoToFiat(
    _ quantity: Decimal, crypto: Instrument, fiat: Instrument, on date: Date
  ) async throws -> Decimal {
    let usdPrice = try await cryptoUsdPrice(for: crypto, on: date)
    let usdValue = quantity * usdPrice
    if fiat.id == "USD" { return usdValue }
    let fiatRate = try await exchangeRates.rate(
      from: Instrument.USD, to: fiat, on: date
    )
    return usdValue * fiatRate
  }

  private func cryptoUsdPrice(for instrument: Instrument, on date: Date) async throws -> Decimal {
    guard let cryptoPrices else {
      throw ConversionError.noCryptoPriceService
    }
    guard let mapping = providerMappingsByInstrumentId[instrument.id] else {
      throw ConversionError.noProviderMapping(instrumentId: instrument.id)
    }
    let token = CryptoPriceService.bridgeToToken(instrument: instrument, mapping: mapping)
    return try await cryptoPrices.price(for: token, on: date)
  }

  // MARK: - USD intermediary helpers

  private func toUsd(
    _ quantity: Decimal, instrument: Instrument, on date: Date
  ) async throws -> Decimal {
    switch instrument.kind {
    case .fiatCurrency:
      if instrument.id == "USD" { return quantity }
      let rate = try await exchangeRates.rate(from: instrument, to: .USD, on: date)
      return quantity * rate
    case .cryptoToken:
      return try await convertCryptoToFiat(quantity, crypto: instrument, fiat: .USD, on: date)
    case .stock:
      return try await convertStockToFiat(quantity, stock: instrument, fiat: .USD, on: date)
    }
  }

  private func fromUsd(
    _ usdValue: Decimal, instrument: Instrument, on date: Date
  ) async throws -> Decimal {
    switch instrument.kind {
    case .fiatCurrency:
      if instrument.id == "USD" { return usdValue }
      let rate = try await exchangeRates.rate(from: .USD, to: instrument, on: date)
      return usdValue * rate
    case .cryptoToken:
      let oneUnitInUsd = try await cryptoUsdPrice(for: instrument, on: date)
      return usdValue / oneUnitInUsd
    case .stock:
      throw ConversionError.unsupportedConversion(from: "USD", to: instrument.id)
    }
  }
}

enum ConversionError: Error, Equatable {
  case unsupportedInstrumentKind
  case unsupportedConversion(from: String, to: String)
  case noCryptoPriceService
  case noProviderMapping(instrumentId: String)
}
