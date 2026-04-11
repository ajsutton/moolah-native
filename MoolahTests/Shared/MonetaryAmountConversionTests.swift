// MoolahTests/Shared/MonetaryAmountConversionTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("MonetaryAmount Conversion")
struct MonetaryAmountConversionTests {
  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter.date(from: string)!
  }

  @Test func convertedDelegatesToService() async throws {
    let client = FixedRateClient(rates: [
      "2026-04-11": ["GBP": Decimal(string: "0.497")!]
    ])
    let service = ExchangeRateService(client: client)
    let amount = MonetaryAmount(cents: 20000, currency: .AUD)

    let result = try await amount.converted(
      to: Currency.from(code: "GBP"), on: date("2026-04-11"), using: service)

    #expect(result.cents == 9940)
    #expect(result.currency.code == "GBP")
  }

  @Test func convertedSameCurrencyReturnsOriginal() async throws {
    let client = FixedRateClient()
    let service = ExchangeRateService(client: client)
    let amount = MonetaryAmount(cents: 12345, currency: .AUD)

    let result = try await amount.converted(to: .AUD, on: date("2026-04-11"), using: service)

    #expect(result.cents == 12345)
    #expect(result.currency == .AUD)
  }
}
