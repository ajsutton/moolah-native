// MoolahTests/Shared/ExchangeRateServiceTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("ExchangeRateService")
struct ExchangeRateServiceTests {
  private func makeService(
    rates: [String: [String: Decimal]] = [:],
    shouldFail: Bool = false
  ) -> ExchangeRateService {
    let client = FixedRateClient(rates: rates, shouldFail: shouldFail)
    return ExchangeRateService(client: client)
  }

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter.date(from: string)!
  }

  // MARK: - Step 4a: Same-currency short-circuit

  @Test func sameCurrencyReturnsIdentityRate() async throws {
    let service = makeService()
    let rate = try await service.rate(from: .AUD, to: .AUD, on: date("2025-01-15"))
    #expect(rate == Decimal(1))
  }
}
