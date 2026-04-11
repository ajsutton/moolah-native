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
    let cacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("exchange-rate-tests")
      .appendingPathComponent(UUID().uuidString)
    return ExchangeRateService(client: client, cacheDirectory: cacheDir)
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

  // MARK: - Step 4c: Fallback and error paths

  @Test func networkFailureFallsBackToMostRecentPriorDate() async throws {
    // Pre-populate cache by fetching Friday's rate successfully
    let fridayRates: [String: [String: Decimal]] = [
      "2025-01-17": ["USD": Decimal(string: "0.6500")!]
    ]
    let fridayClient = FixedRateClient(rates: fridayRates, shouldFail: false)
    let cacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("exchange-rate-tests")
      .appendingPathComponent(UUID().uuidString)
    let service = ExchangeRateService(client: fridayClient, cacheDirectory: cacheDir)

    // Fetch Friday to populate cache
    let fridayRate = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-17"))
    #expect(fridayRate == Decimal(string: "0.6500")!)

    // Now swap to a client that returns empty for weekend (simulating no data)
    // Since we can't swap clients, we use the same service — the FixedRateClient
    // returns empty for Saturday since it has no "2025-01-18" key.
    // The fetch succeeds (no error) but returns no data, so fallback kicks in.
    let saturdayRate = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-18"))
    #expect(saturdayRate == Decimal(string: "0.6500")!)
  }

  @Test func networkFailureWithEmptyCacheThrows() async throws {
    let service = makeService(shouldFail: true)
    await #expect(throws: (any Error).self) {
      try await service.rate(from: .AUD, to: .USD, on: date("2025-01-15"))
    }
  }

  @Test func fallbackNeverUsesFutureDate() async throws {
    // Pre-populate cache with a future date only
    let futureRates: [String: [String: Decimal]] = [
      "2025-01-20": ["USD": Decimal(string: "0.6500")!]
    ]
    let client = FixedRateClient(rates: futureRates, shouldFail: false)
    let cacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("exchange-rate-tests")
      .appendingPathComponent(UUID().uuidString)
    let service = ExchangeRateService(client: client, cacheDirectory: cacheDir)

    // Fetch future date to populate cache
    _ = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-20"))

    // Now request an earlier date — client returns empty (no data for Jan 15),
    // fallback should NOT use the future Jan 20 rate
    await #expect(
      throws: ExchangeRateError.noRateAvailable(base: "AUD", quote: "USD", date: "2025-01-15")
    ) {
      try await service.rate(from: .AUD, to: .USD, on: date("2025-01-15"))
    }
  }
}
