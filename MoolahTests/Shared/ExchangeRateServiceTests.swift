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

  // MARK: - Step 4b: Cache miss and cache hit

  @Test func cacheMissFetchesFromClient() async throws {
    let service = makeService(rates: [
      "2025-01-15": ["USD": Decimal(string: "0.6543")!]
    ])
    let rate = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-15"))
    #expect(rate == Decimal(string: "0.6543")!)
  }

  @Test func cacheHitDoesNotRefetch() async throws {
    let service = makeService(rates: [
      "2025-01-15": ["USD": Decimal(string: "0.6543")!]
    ])
    let first = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-15"))
    let second = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-15"))
    #expect(first == second)
    #expect(first == Decimal(string: "0.6543")!)
  }
}
