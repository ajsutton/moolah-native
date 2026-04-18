import Foundation
import OSLog

/// Full conversion service supporting fiat-to-fiat, stock-to-fiat, and crypto conversions.
/// Stock-to-fiat routes through StockPriceService for price lookup, then ExchangeRateService
/// if the listing currency differs from the target fiat.
/// Crypto routes through CryptoPriceService (USD prices) then ExchangeRateService for non-USD fiat.
actor FullConversionService: InstrumentConversionService {
  private let exchangeRates: ExchangeRateService
  private let stockPrices: StockPriceService
  private let cryptoPrices: CryptoPriceService?
  private let providerMappings: @Sendable () async -> [CryptoProviderMapping]
  private let logger = Logger(subsystem: "com.moolah.app", category: "CurrencyConversion")

  /// - Parameter providerMappings: Closure invoked on each crypto conversion
  ///   to obtain the current set of provider mappings. Tokens registered via
  ///   `CryptoPriceService` after service construction become resolvable on
  ///   the next conversion without rebuilding the service.
  init(
    exchangeRates: ExchangeRateService,
    stockPrices: StockPriceService,
    cryptoPrices: CryptoPriceService? = nil,
    providerMappings: @Sendable @escaping () async -> [CryptoProviderMapping] = { [] }
  ) {
    self.exchangeRates = exchangeRates
    self.stockPrices = stockPrices
    self.cryptoPrices = cryptoPrices
    self.providerMappings = providerMappings
  }

  func convert(
    _ quantity: Decimal,
    from source: Instrument,
    to target: Instrument,
    on date: Date
  ) async throws -> Decimal {
    if source == target { return quantity }

    // Frankfurter (and the crypto/stock providers) have no future rates.
    // Forecast and scheduled-transaction call sites legitimately pass
    // `transaction.date` which can be in the future — clamp to today so
    // we resolve against the latest available rate instead of throwing.
    // See guides/INSTRUMENT_CONVERSION_GUIDE.md Rule 7.
    let effectiveDate = min(date, Date())

    logger.info(
      "Converting \(quantity, privacy: .public) from \(source.id, privacy: .public) (\(String(describing: source.kind), privacy: .public)) to \(target.id, privacy: .public) (\(String(describing: target.kind), privacy: .public))"
    )

    let result: Decimal
    switch (source.kind, target.kind) {
    case (.fiatCurrency, .fiatCurrency):
      let rate = try await exchangeRates.rate(from: source, to: target, on: effectiveDate)
      result = quantity * rate

    case (.stock, .fiatCurrency):
      result = try await convertStockToFiat(
        quantity, stock: source, fiat: target, on: effectiveDate)

    case (.cryptoToken, .fiatCurrency):
      result = try await convertCryptoToFiat(
        quantity, crypto: source, fiat: target, on: effectiveDate)

    case (.fiatCurrency, .cryptoToken):
      let oneUnitInFiat = try await convertCryptoToFiat(
        Decimal(1), crypto: target, fiat: source, on: effectiveDate)
      result = quantity / oneUnitInFiat

    case (.cryptoToken, .cryptoToken):
      let sourceUsdPrice = try await cryptoUsdPrice(for: source, on: effectiveDate)
      let targetUsdPrice = try await cryptoUsdPrice(for: target, on: effectiveDate)
      result = (quantity * sourceUsdPrice) / targetUsdPrice

    case (.stock, .cryptoToken), (.cryptoToken, .stock):
      // Chain through USD as intermediate
      let sourceUsd = try await toUsd(quantity, instrument: source, on: effectiveDate)
      result = try await fromUsd(sourceUsd, instrument: target, on: effectiveDate)

    case (.fiatCurrency, .stock), (.stock, .stock):
      throw ConversionError.unsupportedConversion(from: source.id, to: target.id)
    }

    logger.info("Conversion result: \(result, privacy: .public) \(target.id, privacy: .public)")
    return result
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
    let mappings = await providerMappings()
    guard let mapping = mappings.first(where: { $0.instrumentId == instrument.id }) else {
      throw ConversionError.noProviderMapping(instrumentId: instrument.id)
    }
    return try await cryptoPrices.price(for: instrument, mapping: mapping, on: date)
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
