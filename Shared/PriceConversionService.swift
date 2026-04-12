// Shared/PriceConversionService.swift
import Foundation

actor PriceConversionService {
  private let cryptoPrices: CryptoPriceService
  private let exchangeRates: ExchangeRateService

  init(cryptoPrices: CryptoPriceService, exchangeRates: ExchangeRateService) {
    self.cryptoPrices = cryptoPrices
    self.exchangeRates = exchangeRates
  }

  /// Convert a quantity of a crypto token to a fiat InstrumentAmount on a given date.
  func convert(
    amount: Decimal,
    token: CryptoToken,
    to instrument: Instrument,
    on date: Date
  ) async throws -> InstrumentAmount {
    let usdPrice = try await cryptoPrices.price(for: token, on: date)
    let usdValue = amount * usdPrice

    if instrument.id == "USD" {
      return InstrumentAmount(quantity: usdValue, instrument: instrument)
    }

    let fiatRate = try await exchangeRates.rate(from: .USD, to: instrument, on: date)
    let fiatValue = usdValue * fiatRate
    return InstrumentAmount(quantity: fiatValue, instrument: instrument)
  }

  /// Get the fiat value of one unit of a token on a given date.
  func unitPrice(
    for token: CryptoToken,
    in instrument: Instrument,
    on date: Date
  ) async throws -> Decimal {
    let usdPrice = try await cryptoPrices.price(for: token, on: date)
    if instrument.id == "USD" { return usdPrice }
    let fiatRate = try await exchangeRates.rate(from: .USD, to: instrument, on: date)
    return usdPrice * fiatRate
  }

  /// Get fiat values for one unit of a token over a date range (for charts).
  func priceHistory(
    for token: CryptoToken,
    in instrument: Instrument,
    over range: ClosedRange<Date>
  ) async throws -> [(date: Date, price: Decimal)] {
    let cryptoHistory = try await cryptoPrices.prices(for: token, in: range)

    if instrument.id == "USD" {
      return cryptoHistory
    }

    let fiatHistory = try await exchangeRates.rates(from: .USD, to: instrument, in: range)
    let fiatByDate = Dictionary(
      fiatHistory.map { ($0.date, $0.rate) },
      uniquingKeysWith: { first, _ in first }
    )

    var result: [(date: Date, price: Decimal)] = []
    for entry in cryptoHistory {
      if let fiatRate = fiatByDate[entry.date] {
        result.append((entry.date, entry.price * fiatRate))
      }
    }

    return result
  }
}
