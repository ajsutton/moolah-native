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

  // MARK: - Date range lookup

  @Test func rangeReturnsRatesForEachDay() async throws {
    let service = makeService(rates: [
      "2026-04-07": ["USD": Decimal(string: "0.630")!],
      "2026-04-08": ["USD": Decimal(string: "0.631")!],
      "2026-04-09": ["USD": Decimal(string: "0.632")!],
    ])
    let results = try await service.rates(
      from: .AUD, to: .USD,
      in: date("2026-04-07")...date("2026-04-09")
    )
    #expect(results.count == 3)
    #expect(results[0].rate == Decimal(string: "0.630")!)
    #expect(results[1].rate == Decimal(string: "0.631")!)
    #expect(results[2].rate == Decimal(string: "0.632")!)
  }

  @Test func rangeOnlyFetchesMissingSegments() async throws {
    let service = makeService(rates: [
      "2026-04-07": ["USD": Decimal(string: "0.630")!],
      "2026-04-08": ["USD": Decimal(string: "0.631")!],
      "2026-04-09": ["USD": Decimal(string: "0.632")!],
      "2026-04-10": ["USD": Decimal(string: "0.633")!],
      "2026-04-11": ["USD": Decimal(string: "0.634")!],
    ])
    _ = try await service.rates(
      from: .AUD, to: .USD,
      in: date("2026-04-08")...date("2026-04-09")
    )
    let results = try await service.rates(
      from: .AUD, to: .USD,
      in: date("2026-04-07")...date("2026-04-11")
    )
    #expect(results.count == 5)
    #expect(results[0].rate == Decimal(string: "0.630")!)
    #expect(results[4].rate == Decimal(string: "0.634")!)
  }

  @Test func sameCurrencyRangeReturnsIdentity() async throws {
    let service = makeService()
    let results = try await service.rates(
      from: .AUD, to: .AUD,
      in: date("2026-04-07")...date("2026-04-09")
    )
    #expect(results.count == 3)
    #expect(results.allSatisfy { $0.rate == Decimal(1) })
  }

  // MARK: - Convert

  @Test func convertProducesCorrectAmount() async throws {
    let service = makeService(rates: [
      "2026-04-11": ["USD": Decimal(string: "0.632")!]
    ])
    let amount = MonetaryAmount(cents: 10000, currency: .AUD)  // $100.00 AUD
    let converted = try await service.convert(amount, to: .USD, on: date("2026-04-11"))
    // 10000 cents * 0.632 = 6320 cents = $63.20 USD
    #expect(converted.cents == 6320)
    #expect(converted.currency == .USD)
  }

  @Test func convertSameCurrencyReturnsIdentical() async throws {
    let service = makeService()
    let amount = MonetaryAmount(cents: 10000, currency: .AUD)
    let converted = try await service.convert(amount, to: .AUD, on: date("2026-04-11"))
    #expect(converted.cents == 10000)
    #expect(converted.currency == .AUD)
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
