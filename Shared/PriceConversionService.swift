// Shared/PriceConversionService.swift
import Foundation

actor PriceConversionService {
  private let cryptoPrices: CryptoPriceService
  private let exchangeRates: ExchangeRateService

  init(cryptoPrices: CryptoPriceService, exchangeRates: ExchangeRateService) {
    self.cryptoPrices = cryptoPrices
    self.exchangeRates = exchangeRates
  }

  /// Convert a quantity of a crypto token to a fiat MonetaryAmount on a given date.
  func convert(
    amount: Decimal,
    token: CryptoToken,
    to currency: Currency,
    on date: Date
  ) async throws -> MonetaryAmount {
    let usdPrice = try await cryptoPrices.price(for: token, on: date)
    let usdValue = amount * usdPrice

    if currency == .USD {
      return centsFromDecimal(usdValue, currency: currency)
    }

    let fiatRate = try await exchangeRates.rate(from: .USD, to: currency, on: date)
    let fiatValue = usdValue * fiatRate
    return centsFromDecimal(fiatValue, currency: currency)
  }

  /// Get the fiat value of one unit of a token on a given date.
  func unitPrice(
    for token: CryptoToken,
    in currency: Currency,
    on date: Date
  ) async throws -> Decimal {
    let usdPrice = try await cryptoPrices.price(for: token, on: date)
    if currency == .USD { return usdPrice }
    let fiatRate = try await exchangeRates.rate(from: .USD, to: currency, on: date)
    return usdPrice * fiatRate
  }

  /// Get fiat values for one unit of a token over a date range (for charts).
  func priceHistory(
    for token: CryptoToken,
    in currency: Currency,
    over range: ClosedRange<Date>
  ) async throws -> [(date: Date, price: Decimal)] {
    let cryptoHistory = try await cryptoPrices.prices(for: token, in: range)

    if currency == .USD {
      return cryptoHistory
    }

    let fiatHistory = try await exchangeRates.rates(from: .USD, to: currency, in: range)
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

  // MARK: - Private

  private func centsFromDecimal(_ value: Decimal, currency: Currency) -> MonetaryAmount {
    var centValue = value * Decimal(100)
    var rounded = Decimal()
    NSDecimalRound(&rounded, &centValue, 0, .bankers)
    let cents = Int(truncating: rounded as NSDecimalNumber)
    return MonetaryAmount(cents: cents, currency: currency)
  }
}
