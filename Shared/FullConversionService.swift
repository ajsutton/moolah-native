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
  private let cryptoRegistrations: @Sendable () async throws -> [CryptoRegistration]
  private let logger = Logger(subsystem: "com.moolah.app", category: "CurrencyConversion")

  /// - Parameter cryptoRegistrations: Closure invoked on each crypto
  ///   conversion to obtain the current set of crypto registrations. Tokens
  ///   registered via `CryptoPriceService` after service construction become
  ///   resolvable on the next conversion without rebuilding the service.
  ///   Errors thrown by the closure (e.g. registry read failures) propagate
  ///   through `convert(_:from:to:on:)` rather than collapsing silently to an
  ///   empty mapping table — see `guides/INSTRUMENT_CONVERSION_GUIDE.md`
  ///   Rule 11.
  ///
  ///   Returning the full `CryptoRegistration` (rather than just its
  ///   `mapping`) is required so `convertResult(...)` can honour the
  ///   `pricingStatus` (`.priced` / `.unpriced` / `.spam`) per the
  ///   discriminated `CryptoPriceLookup` flow.
  init(
    exchangeRates: ExchangeRateService,
    stockPrices: StockPriceService,
    cryptoPrices: CryptoPriceService? = nil,
    cryptoRegistrations: @Sendable @escaping () async throws -> [CryptoRegistration] = { [] }
  ) {
    self.exchangeRates = exchangeRates
    self.stockPrices = stockPrices
    self.cryptoPrices = cryptoPrices
    self.cryptoRegistrations = cryptoRegistrations
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

  /// Discriminated convert. When the source instrument is a crypto token
  /// whose registration carries a non-`.priced` `pricingStatus` (i.e.
  /// `.unpriced` or `.spam`), returns `.knownZero(targetInstrument:)`
  /// without invoking any price provider. Otherwise wraps the existing
  /// `convertAmount` in `.value(...)`. A real provider failure throws —
  /// per `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11, never collapsed
  /// to `.knownZero`.
  ///
  /// Same-instrument identity is a fast path — even for `.unpriced` /
  /// `.spam` tokens — because the position list still wants to render
  /// the native quantity for the user (the token isn't worth zero ETH
  /// of itself; its *fiat aggregation* contribution is zero).
  func convertResult(
    _ amount: InstrumentAmount,
    to instrument: Instrument,
    on date: Date
  ) async throws -> ConversionResult {
    if amount.instrument == instrument {
      return .value(amount)
    }
    if amount.instrument.kind == .cryptoToken {
      let registrations = try await cryptoRegistrations()
      if let registration = registrations.first(where: { $0.id == amount.instrument.id }),
        registration.pricingStatus != .priced
      {
        // `.unpriced` and `.spam` resolve to a clean zero in the
        // requested target instrument without a provider call.
        return .knownZero(targetInstrument: instrument)
      }
    }
    let converted = try await convertAmount(amount, to: instrument, on: date)
    return .value(converted)
  }

  /// Invalidate any cached state held about `instrument`. For crypto
  /// instruments this clears the in-memory and on-disk price rows in
  /// `CryptoPriceService` so the next conversion fetches fresh data —
  /// required after any user mutation that changes
  /// `pricingStatus` for the instrument's registration. No-op for
  /// fiat / stock instruments and when no `CryptoPriceService` is wired.
  func invalidateCache(for instrument: Instrument) async {
    guard instrument.kind == .cryptoToken, let cryptoPrices else { return }
    await cryptoPrices.purgeCache(instrumentId: instrument.id)
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
    let registrations = try await cryptoRegistrations()
    guard let registration = registrations.first(where: { $0.id == instrument.id }) else {
      throw ConversionError.noProviderMapping(instrumentId: instrument.id)
    }
    return try await cryptoPrices.price(
      for: registration.instrument, mapping: registration.mapping, on: date)
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
