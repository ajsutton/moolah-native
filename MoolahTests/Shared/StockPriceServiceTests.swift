// MoolahTests/Shared/StockPriceServiceTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("StockPriceService")
struct StockPriceServiceTests {
  private func makeService(
    responses: [String: StockPriceResponse] = [:],
    shouldFail: Bool = false,
    cacheDirectory: URL? = nil
  ) -> StockPriceService {
    let client = FixedStockPriceClient(responses: responses, shouldFail: shouldFail)
    let cacheDir =
      cacheDirectory
      ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("stock-price-tests")
      .appendingPathComponent(UUID().uuidString)
    return StockPriceService(client: client, cacheDirectory: cacheDir)
  }

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter.date(from: string)!
  }

  private func bhpResponse() -> StockPriceResponse {
    StockPriceResponse(
      instrument: .AUD,
      prices: [
        "2026-04-07": Decimal(string: "38.50")!,
        "2026-04-08": Decimal(string: "38.75")!,
        "2026-04-09": Decimal(string: "39.00")!,
        "2026-04-10": Decimal(string: "38.25")!,
        "2026-04-11": Decimal(string: "38.60")!,
      ])
  }

  // MARK: - Cache miss and cache hit

  @Test func cacheMissFetchesFromClient() async throws {
    let service = makeService(responses: ["BHP.AX": bhpResponse()])
    let price = try await service.price(ticker: "BHP.AX", on: date("2026-04-07"))
    #expect(price == Decimal(string: "38.50")!)
  }

  @Test func cacheHitDoesNotRefetch() async throws {
    let service = makeService(responses: ["BHP.AX": bhpResponse()])
    let first = try await service.price(ticker: "BHP.AX", on: date("2026-04-07"))
    let second = try await service.price(ticker: "BHP.AX", on: date("2026-04-07"))
    #expect(first == second)
    #expect(first == Decimal(string: "38.50")!)
  }

  // MARK: - Currency discovery

  @Test func currencyDiscoveredFromFirstFetch() async throws {
    let service = makeService(responses: ["BHP.AX": bhpResponse()])
    _ = try await service.price(ticker: "BHP.AX", on: date("2026-04-07"))
    let instrument = try await service.instrument(for: "BHP.AX")
    #expect(instrument == .AUD)
  }

  @Test func instrumentThrowsForUnknownTicker() async throws {
    let service = makeService()
    await #expect(throws: (any Error).self) {
      try await service.instrument(for: "UNKNOWN.AX")
    }
  }

  // MARK: - Date fallback (weekends/holidays)

  @Test func weekendFallsBackToFriday() async throws {
    let service = makeService(responses: ["BHP.AX": bhpResponse()])
    _ = try await service.price(ticker: "BHP.AX", on: date("2026-04-07"))
    let price = try await service.price(ticker: "BHP.AX", on: date("2026-04-12"))
    #expect(price == Decimal(string: "38.60")!)
  }

  @Test func fallbackNeverUsesFutureDate() async throws {
    let futureOnly = StockPriceResponse(
      instrument: .AUD,
      prices: [
        "2026-04-10": Decimal(string: "38.25")!
      ])
    let service = makeService(responses: ["BHP.AX": futureOnly])
    _ = try await service.price(ticker: "BHP.AX", on: date("2026-04-10"))
    await #expect(throws: (any Error).self) {
      try await service.price(ticker: "BHP.AX", on: date("2026-04-07"))
    }
  }

  // MARK: - Network failure

  @Test func networkFailureWithCacheReturnsCachedData() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("stock-price-tests")
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let service1 = makeService(responses: ["BHP.AX": bhpResponse()], cacheDirectory: tempDir)
    _ = try await service1.price(ticker: "BHP.AX", on: date("2026-04-07"))

    let service2 = makeService(shouldFail: true, cacheDirectory: tempDir)
    let price = try await service2.price(ticker: "BHP.AX", on: date("2026-04-07"))
    #expect(price == Decimal(string: "38.50")!)
  }

  @Test func networkFailureWithEmptyCacheThrows() async throws {
    let service = makeService(shouldFail: true)
    await #expect(throws: (any Error).self) {
      try await service.price(ticker: "BHP.AX", on: date("2026-04-07"))
    }
  }

  // MARK: - Date range lookup

  @Test func rangeReturnsOrderedPrices() async throws {
    let service = makeService(responses: ["BHP.AX": bhpResponse()])
    let results = try await service.prices(
      ticker: "BHP.AX",
      in: date("2026-04-07")...date("2026-04-09")
    )
    #expect(results.count == 3)
    #expect(results[0].price == Decimal(string: "38.50")!)
    #expect(results[1].price == Decimal(string: "38.75")!)
    #expect(results[2].price == Decimal(string: "39.00")!)
  }

  @Test func rangeExpandsFetchForMissingDates() async throws {
    let service = makeService(responses: ["BHP.AX": bhpResponse()])
    _ = try await service.prices(
      ticker: "BHP.AX",
      in: date("2026-04-08")...date("2026-04-09")
    )
    let results = try await service.prices(
      ticker: "BHP.AX",
      in: date("2026-04-07")...date("2026-04-11")
    )
    #expect(results.count == 5)
    #expect(results[0].price == Decimal(string: "38.50")!)
    #expect(results[4].price == Decimal(string: "38.60")!)
  }

  @Test func rangeFillsWeekendsWithLastKnownPrice() async throws {
    let service = makeService(responses: ["BHP.AX": bhpResponse()])
    let results = try await service.prices(
      ticker: "BHP.AX",
      in: date("2026-04-10")...date("2026-04-12")
    )
    #expect(results.count == 3)
    #expect(results[0].price == Decimal(string: "38.25")!)
    #expect(results[1].price == Decimal(string: "38.60")!)
    #expect(results[2].price == Decimal(string: "38.60")!)
  }

  // MARK: - Disk persistence (gzip round-trip)

  @Test func gzipRoundTripPreservesData() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("stock-price-tests")
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let service1 = makeService(responses: ["BHP.AX": bhpResponse()], cacheDirectory: tempDir)
    let price = try await service1.price(ticker: "BHP.AX", on: date("2026-04-07"))
    #expect(price == Decimal(string: "38.50")!)

    let service2 = makeService(shouldFail: true, cacheDirectory: tempDir)
    let cachedPrice = try await service2.price(ticker: "BHP.AX", on: date("2026-04-07"))
    #expect(cachedPrice == Decimal(string: "38.50")!)

    let instrument = try await service2.instrument(for: "BHP.AX")
    #expect(instrument == .AUD)
  }

  // MARK: - Multiple tickers

  @Test func differentTickersAreCachedIndependently() async throws {
    let cbaResponse = StockPriceResponse(
      instrument: .AUD,
      prices: [
        "2026-04-07": Decimal(string: "115.20")!
      ])
    let service = makeService(responses: [
      "BHP.AX": bhpResponse(),
      "CBA.AX": cbaResponse,
    ])
    let bhp = try await service.price(ticker: "BHP.AX", on: date("2026-04-07"))
    let cba = try await service.price(ticker: "CBA.AX", on: date("2026-04-07"))
    #expect(bhp == Decimal(string: "38.50")!)
    #expect(cba == Decimal(string: "115.20")!)
  }
}
