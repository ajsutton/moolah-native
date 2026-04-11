# Australian Stock Price Service — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a price lookup service for ASX stocks that fetches daily adjusted close prices from Yahoo Finance and caches them to disk.

**Architecture:** Protocol-based client (`StockPriceClient`) fetches from Yahoo Finance. An `actor StockPriceService` owns in-memory and gzip-compressed disk caches (one file per ticker). Prices stored as `Decimal`; currency discovered from the API. Follows the same pattern as `ExchangeRateClient` / `ExchangeRateService`.

**Tech Stack:** Swift, Foundation (URLSession, JSONSerialization), Swift Testing framework.

**Spec:** `plans/au-stock-price-design.md`

**Reference files** (read these to understand existing patterns):
- `Domain/Repositories/ExchangeRateClient.swift` — protocol pattern
- `Domain/Models/ExchangeRateCache.swift` — cache model pattern
- `Shared/ExchangeRateService.swift` — service actor pattern (269 lines)
- `Backends/Frankfurter/FrankfurterClient.swift` — production client pattern
- `MoolahTests/Support/FixedRateClient.swift` — test double pattern
- `MoolahTests/Shared/ExchangeRateServiceTests.swift` — test suite pattern
- `App/ProfileSession.swift` — integration point

---

### Task 1: Domain Models — StockPriceCache and StockPriceClient Protocol

**Files:**
- Create: `Domain/Models/StockPriceCache.swift`
- Create: `Domain/Repositories/StockPriceClient.swift`

- [ ] **Step 1: Create StockPriceCache model**

Create `Domain/Models/StockPriceCache.swift`:

```swift
// Domain/Models/StockPriceCache.swift
import Foundation

/// On-disk cache for a single stock ticker. Contains adjusted close prices for every cached trading day.
struct StockPriceCache: Codable, Sendable, Equatable {
  let ticker: String        // e.g. "BHP.AX"
  let currency: Currency    // denomination discovered from API (e.g. .AUD)
  var earliestDate: String  // ISO date string "YYYY-MM-DD"
  var latestDate: String    // ISO date string "YYYY-MM-DD"
  var prices: [String: Decimal]  // date string -> adjusted close price
}
```

- [ ] **Step 2: Create StockPriceClient protocol**

Create `Domain/Repositories/StockPriceClient.swift`:

```swift
// Domain/Repositories/StockPriceClient.swift
import Foundation

/// Response from a stock price data source.
struct StockPriceResponse: Sendable {
  let currency: Currency
  let prices: [String: Decimal]  // date string -> adjusted close price
}

/// Abstraction for fetching stock prices from an external source.
/// Production: YahooFinanceClient. Tests: FixedStockPriceClient.
protocol StockPriceClient: Sendable {
  /// Fetch daily adjusted close prices for a ticker over a date range.
  func fetchDailyPrices(ticker: String, from: Date, to: Date) async throws -> StockPriceResponse
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `just build-mac`
Expected: BUILD SUCCEEDED with no warnings in new files.

- [ ] **Step 4: Commit**

```bash
git add Domain/Models/StockPriceCache.swift Domain/Repositories/StockPriceClient.swift
git commit -m "feat: add StockPriceCache model and StockPriceClient protocol"
```

---

### Task 2: Test Double — FixedStockPriceClient

**Files:**
- Create: `MoolahTests/Support/FixedStockPriceClient.swift`

- [ ] **Step 1: Create FixedStockPriceClient**

Create `MoolahTests/Support/FixedStockPriceClient.swift`:

```swift
// MoolahTests/Support/FixedStockPriceClient.swift
import Foundation

@testable import Moolah

/// Test double that returns pre-configured stock prices without network calls.
struct FixedStockPriceClient: StockPriceClient, Sendable {
  /// Pre-loaded responses keyed by ticker.
  let responses: [String: StockPriceResponse]

  /// If true, throws on any fetch call (simulates network failure).
  let shouldFail: Bool

  init(responses: [String: StockPriceResponse] = [:], shouldFail: Bool = false) {
    self.responses = responses
    self.shouldFail = shouldFail
  }

  func fetchDailyPrices(ticker: String, from: Date, to: Date) async throws -> StockPriceResponse {
    if shouldFail {
      throw URLError(.notConnectedToInternet)
    }
    guard let response = responses[ticker] else {
      return StockPriceResponse(currency: .AUD, prices: [:])
    }

    let calendar = Calendar(identifier: .gregorian)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]

    // Filter to only return prices within the requested date range
    var filtered: [String: Decimal] = [:]
    var current = from
    while current <= to {
      let key = formatter.string(from: current)
      if let price = response.prices[key] {
        filtered[key] = price
      }
      current = calendar.date(byAdding: .day, value: 1, to: current)!
    }
    return StockPriceResponse(currency: response.currency, prices: filtered)
  }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `just build-mac`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add MoolahTests/Support/FixedStockPriceClient.swift
git commit -m "test: add FixedStockPriceClient test double"
```

---

### Task 3: StockPriceService — Core Actor with Tests (TDD)

**Files:**
- Create: `MoolahTests/Shared/StockPriceServiceTests.swift`
- Create: `Shared/StockPriceService.swift`

This task follows TDD: write all tests first, verify they fail, then implement the service.

- [ ] **Step 1: Write the test file**

Create `MoolahTests/Shared/StockPriceServiceTests.swift`:

```swift
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
    let cacheDir = cacheDirectory ?? FileManager.default.temporaryDirectory
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
    StockPriceResponse(currency: .AUD, prices: [
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
    let currency = try await service.currency(for: "BHP.AX")
    #expect(currency == .AUD)
  }

  @Test func currencyThrowsForUnknownTicker() async throws {
    let service = makeService()
    await #expect(throws: (any Error).self) {
      try await service.currency(for: "UNKNOWN.AX")
    }
  }

  // MARK: - Date fallback (weekends/holidays)

  @Test func weekendFallsBackToFriday() async throws {
    let service = makeService(responses: ["BHP.AX": bhpResponse()])
    // 2026-04-11 is a Saturday, 2026-04-10 is a Friday with data
    // Actually, let's use explicit dates. Use the bhpResponse which has data for
    // 2026-04-07 through 2026-04-11.
    // Request 2026-04-12 (no data). Fetch succeeds but returns empty for that date.
    // Fallback should use 2026-04-11's price.
    _ = try await service.price(ticker: "BHP.AX", on: date("2026-04-07"))
    let price = try await service.price(ticker: "BHP.AX", on: date("2026-04-12"))
    #expect(price == Decimal(string: "38.60")!)
  }

  @Test func fallbackNeverUsesFutureDate() async throws {
    let futureOnly = StockPriceResponse(currency: .AUD, prices: [
      "2026-04-10": Decimal(string: "38.25")!,
    ])
    let service = makeService(responses: ["BHP.AX": futureOnly])
    // Fetch 2026-04-10 to populate cache
    _ = try await service.price(ticker: "BHP.AX", on: date("2026-04-10"))
    // Request earlier date — should NOT use the future 2026-04-10 price
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

    // First service: populate cache
    let service1 = makeService(responses: ["BHP.AX": bhpResponse()], cacheDirectory: tempDir)
    _ = try await service1.price(ticker: "BHP.AX", on: date("2026-04-07"))

    // Second service: failing client, same cache directory
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
    // Fetch a narrow range first
    _ = try await service.prices(
      ticker: "BHP.AX",
      in: date("2026-04-08")...date("2026-04-09")
    )
    // Expand to wider range
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
    // Request range including 2026-04-12 (no data). Should forward-fill with 2026-04-11.
    let results = try await service.prices(
      ticker: "BHP.AX",
      in: date("2026-04-10")...date("2026-04-12")
    )
    #expect(results.count == 3)
    #expect(results[0].price == Decimal(string: "38.25")!)  // Apr 10
    #expect(results[1].price == Decimal(string: "38.60")!)  // Apr 11
    #expect(results[2].price == Decimal(string: "38.60")!)  // Apr 12 (filled)
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

    // New service with failing client, same cache directory — must load from disk
    let service2 = makeService(shouldFail: true, cacheDirectory: tempDir)
    let cachedPrice = try await service2.price(ticker: "BHP.AX", on: date("2026-04-07"))
    #expect(cachedPrice == Decimal(string: "38.50")!)

    let currency = try await service2.currency(for: "BHP.AX")
    #expect(currency == .AUD)
  }

  // MARK: - Multiple tickers

  @Test func differentTickersAreCachedIndependently() async throws {
    let cbaResponse = StockPriceResponse(currency: .AUD, prices: [
      "2026-04-07": Decimal(string: "115.20")!,
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test`
Expected: FAIL — `StockPriceService` does not exist yet.

- [ ] **Step 3: Implement StockPriceService**

Create `Shared/StockPriceService.swift`:

```swift
// Shared/StockPriceService.swift
import Foundation

enum StockPriceError: Error, Equatable {
  case noPriceAvailable(ticker: String, date: String)
  case unknownTicker(String)
}

actor StockPriceService {
  private let client: StockPriceClient
  private var caches: [String: StockPriceCache] = [:]
  private let cacheDirectory: URL
  private let dateFormatter: ISO8601DateFormatter

  init(client: StockPriceClient, cacheDirectory: URL? = nil) {
    self.client = client
    self.cacheDirectory =
      cacheDirectory
      ?? FileManager.default.urls(
        for: .cachesDirectory, in: .userDomainMask
      ).first!.appendingPathComponent("stock-prices")
    self.dateFormatter = ISO8601DateFormatter()
    self.dateFormatter.formatOptions = [.withFullDate]
  }

  // MARK: - Public API

  func price(ticker: String, on date: Date) async throws -> Decimal {
    let dateString = dateFormatter.string(from: date)

    // Check in-memory cache
    if let cached = lookupPrice(ticker: ticker, dateString: dateString) {
      return cached
    }

    // Load from disk if not already loaded
    if caches[ticker] == nil {
      loadCacheFromDisk(ticker: ticker)
    }

    // Check again after disk load
    if let cached = lookupPrice(ticker: ticker, dateString: dateString) {
      return cached
    }

    // Fetch from client
    do {
      try await fetchAndMerge(ticker: ticker, from: date, to: date)
      if let cached = lookupPrice(ticker: ticker, dateString: dateString) {
        return cached
      }
    } catch {
      // Network failure — try fallback to most recent prior date
      if let fallback = fallbackPrice(ticker: ticker, dateString: dateString) {
        return fallback
      }
      throw error
    }

    // Fetch succeeded but no price for this date — try fallback
    if let fallback = fallbackPrice(ticker: ticker, dateString: dateString) {
      return fallback
    }

    throw StockPriceError.noPriceAvailable(ticker: ticker, date: dateString)
  }

  func prices(
    ticker: String, in range: ClosedRange<Date>
  ) async throws -> [(date: String, price: Decimal)] {
    // Load cache if not already in memory
    if caches[ticker] == nil {
      loadCacheFromDisk(ticker: ticker)
    }

    // Determine what we need to fetch
    let rangeStart = dateFormatter.string(from: range.lowerBound)
    let rangeEnd = dateFormatter.string(from: range.upperBound)

    if let cache = caches[ticker] {
      if rangeStart < cache.earliestDate {
        let fetchEnd = Calendar(identifier: .gregorian)
          .date(
            byAdding: .day, value: -1,
            to: dateFormatter.date(from: cache.earliestDate)!)!
        try await fetchInChunks(ticker: ticker, from: range.lowerBound, to: fetchEnd)
      }
      if rangeEnd > cache.latestDate {
        let fetchStart = Calendar(identifier: .gregorian)
          .date(
            byAdding: .day, value: 1,
            to: dateFormatter.date(from: cache.latestDate)!)!
        try await fetchInChunks(ticker: ticker, from: fetchStart, to: range.upperBound)
      }
    } else {
      try await fetchInChunks(ticker: ticker, from: range.lowerBound, to: range.upperBound)
    }

    // Build result series
    let dates = generateDateSeries(in: range)
    var results: [(date: String, price: Decimal)] = []
    var lastKnownPrice: Decimal?

    for date in dates {
      let dateString = dateFormatter.string(from: date)
      if let price = caches[ticker]?.prices[dateString] {
        lastKnownPrice = price
        results.append((dateString, price))
      } else if let fallback = lastKnownPrice {
        results.append((dateString, fallback))
      }
    }

    return results
  }

  func currency(for ticker: String) async throws -> Currency {
    if let cache = caches[ticker] {
      return cache.currency
    }
    loadCacheFromDisk(ticker: ticker)
    if let cache = caches[ticker] {
      return cache.currency
    }
    throw StockPriceError.unknownTicker(ticker)
  }

  // MARK: - Private helpers

  private func lookupPrice(ticker: String, dateString: String) -> Decimal? {
    caches[ticker]?.prices[dateString]
  }

  private func fallbackPrice(ticker: String, dateString: String) -> Decimal? {
    guard let cache = caches[ticker] else { return nil }
    let sortedDates = cache.prices.keys.sorted().reversed()
    for cachedDate in sortedDates {
      if cachedDate <= dateString {
        return cache.prices[cachedDate]
      }
    }
    return nil
  }

  private func generateDateSeries(in range: ClosedRange<Date>) -> [Date] {
    let calendar = Calendar(identifier: .gregorian)
    var dates: [Date] = []
    var current = range.lowerBound
    while current <= range.upperBound {
      dates.append(current)
      current = calendar.date(byAdding: .day, value: 1, to: current)!
    }
    return dates
  }

  private func fetchInChunks(ticker: String, from: Date, to: Date) async throws {
    let calendar = Calendar(identifier: .gregorian)
    var chunkStart = from
    while chunkStart <= to {
      let chunkEnd = min(
        calendar.date(byAdding: .year, value: 1, to: chunkStart)!,
        to
      )
      try await fetchAndMerge(ticker: ticker, from: chunkStart, to: chunkEnd)
      chunkStart = calendar.date(byAdding: .day, value: 1, to: chunkEnd)!
    }
  }

  private func fetchAndMerge(ticker: String, from: Date, to: Date) async throws {
    let response = try await client.fetchDailyPrices(ticker: ticker, from: from, to: to)
    merge(ticker: ticker, currency: response.currency, newPrices: response.prices)
    saveCacheToDisk(ticker: ticker)
  }

  private func merge(ticker: String, currency: Currency, newPrices: [String: Decimal]) {
    guard !newPrices.isEmpty else { return }
    let sortedDates = newPrices.keys.sorted()
    if var existing = caches[ticker] {
      for (dateKey, price) in newPrices {
        existing.prices[dateKey] = price
      }
      if let first = sortedDates.first, first < existing.earliestDate {
        existing.earliestDate = first
      }
      if let last = sortedDates.last, last > existing.latestDate {
        existing.latestDate = last
      }
      caches[ticker] = existing
    } else {
      caches[ticker] = StockPriceCache(
        ticker: ticker,
        currency: currency,
        earliestDate: sortedDates.first!,
        latestDate: sortedDates.last!,
        prices: newPrices
      )
    }
  }

  private func cacheFileURL(ticker: String) -> URL {
    cacheDirectory.appendingPathComponent("prices-\(ticker).json.gz")
  }

  private func loadCacheFromDisk(ticker: String) {
    let url = cacheFileURL(ticker: ticker)
    guard let compressed = try? Data(contentsOf: url) else { return }
    guard let data = decompress(compressed) else { return }
    guard let cache = try? JSONDecoder().decode(StockPriceCache.self, from: data) else { return }
    caches[ticker] = cache
  }

  private func saveCacheToDisk(ticker: String) {
    guard let cache = caches[ticker] else { return }
    guard let data = try? JSONEncoder().encode(cache) else { return }
    guard let compressed = compress(data) else { return }
    try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try? compressed.write(to: cacheFileURL(ticker: ticker), options: .atomic)
  }

  private func compress(_ data: Data) -> Data? {
    try? (data as NSData).compressed(using: .zlib) as Data
  }

  private func decompress(_ data: Data) -> Data? {
    try? (data as NSData).decompressed(using: .zlib) as Data
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test`
Expected: All `StockPriceServiceTests` pass.

- [ ] **Step 5: Commit**

```bash
git add MoolahTests/Shared/StockPriceServiceTests.swift Shared/StockPriceService.swift
git commit -m "feat: add StockPriceService with caching and TDD tests"
```

---

### Task 4: YahooFinanceClient Implementation

**Files:**
- Create: `MoolahTests/Support/Fixtures/yahoo-finance-chart-response.json`
- Create: `MoolahTests/Shared/YahooFinanceClientTests.swift`
- Create: `Backends/YahooFinance/YahooFinanceClient.swift`

- [ ] **Step 1: Create fixture JSON**

Create `MoolahTests/Support/Fixtures/yahoo-finance-chart-response.json`:

```json
{
  "chart": {
    "result": [
      {
        "meta": {
          "currency": "AUD",
          "symbol": "BHP.AX",
          "exchangeName": "ASX",
          "fullExchangeName": "ASX",
          "regularMarketPrice": 38.6,
          "gmtoffset": 36000,
          "timezone": "AEST"
        },
        "timestamp": [1649116800, 1649203200, 1649289600],
        "indicators": {
          "quote": [
            {
              "open": [38.50, 38.75, null],
              "high": [39.00, 39.10, null],
              "low": [38.20, 38.50, null],
              "close": [38.75, 39.00, null],
              "volume": [12345678, 9876543, null]
            }
          ],
          "adjclose": [
            {
              "adjclose": [37.80, 38.10, null]
            }
          ]
        }
      }
    ],
    "error": null
  }
}
```

Note: The three timestamps correspond to 2022-04-05, 2022-04-06, 2022-04-07 (UTC). The third entry has null values (trading halt) and should be skipped.

- [ ] **Step 2: Create fixture for error response**

Create `MoolahTests/Support/Fixtures/yahoo-finance-error-response.json`:

```json
{
  "chart": {
    "result": null,
    "error": {
      "code": "Not Found",
      "description": "No data found, symbol may be delisted"
    }
  }
}
```

- [ ] **Step 3: Write YahooFinanceClient tests**

Create `MoolahTests/Shared/YahooFinanceClientTests.swift`:

```swift
// MoolahTests/Shared/YahooFinanceClientTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("YahooFinanceClient")
struct YahooFinanceClientTests {
  private func loadFixture(_ name: String) throws -> Data {
    let url = Bundle(for: TestBundleMarker.self)
      .url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    return try Data(contentsOf: url)
  }

  private func makeClient(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  ) -> (YahooFinanceClient, URLSession) {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = YahooFinanceClient(session: session)
    URLProtocolStub.requestHandler = handler
    return (client, session)
  }

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter.date(from: string)!
  }

  @Test func requestURLContainsTickerAndDateRange() async throws {
    let fixtureData = try loadFixture("yahoo-finance-chart-response")
    var capturedRequest: URLRequest?

    let (client, _) = makeClient { request in
      capturedRequest = request
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      return (response, fixtureData)
    }

    _ = try await client.fetchDailyPrices(
      ticker: "BHP.AX", from: date("2022-04-05"), to: date("2022-04-07"))

    let url = capturedRequest!.url!
    #expect(url.path().contains("BHP.AX"))
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    let queryItems = components.queryItems ?? []
    #expect(queryItems.contains { $0.name == "interval" && $0.value == "1d" })
    #expect(queryItems.contains { $0.name == "period1" })
    #expect(queryItems.contains { $0.name == "period2" })
  }

  @Test func requestIncludesUserAgentHeader() async throws {
    let fixtureData = try loadFixture("yahoo-finance-chart-response")
    var capturedRequest: URLRequest?

    let (client, _) = makeClient { request in
      capturedRequest = request
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      return (response, fixtureData)
    }

    _ = try await client.fetchDailyPrices(
      ticker: "BHP.AX", from: date("2022-04-05"), to: date("2022-04-07"))

    let userAgent = capturedRequest!.value(forHTTPHeaderField: "User-Agent")
    #expect(userAgent != nil)
    #expect(userAgent!.isEmpty == false)
  }

  @Test func parsesAdjustedCloseAndCurrency() async throws {
    let fixtureData = try loadFixture("yahoo-finance-chart-response")

    let (client, _) = makeClient { request in
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      return (response, fixtureData)
    }

    let result = try await client.fetchDailyPrices(
      ticker: "BHP.AX", from: date("2022-04-05"), to: date("2022-04-07"))

    #expect(result.currency == .AUD)
    // Two entries (third has null adjclose and should be skipped)
    #expect(result.prices.count == 2)
    #expect(result.prices["2022-04-05"] == Decimal(string: "37.80")!)
    #expect(result.prices["2022-04-06"] == Decimal(string: "38.10")!)
  }

  @Test func skipsNullAdjcloseValues() async throws {
    let fixtureData = try loadFixture("yahoo-finance-chart-response")

    let (client, _) = makeClient { request in
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      return (response, fixtureData)
    }

    let result = try await client.fetchDailyPrices(
      ticker: "BHP.AX", from: date("2022-04-05"), to: date("2022-04-07"))

    // Third timestamp has null adjclose — should not appear
    #expect(result.prices["2022-04-07"] == nil)
  }

  @Test func errorResponseThrows() async throws {
    let fixtureData = try loadFixture("yahoo-finance-error-response")

    let (client, _) = makeClient { request in
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      return (response, fixtureData)
    }

    await #expect(throws: (any Error).self) {
      try await client.fetchDailyPrices(
        ticker: "INVALID.AX", from: date("2022-04-05"), to: date("2022-04-07"))
    }
  }

  @Test func httpErrorThrows() async throws {
    let (client, _) = makeClient { request in
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 404, httpVersion: nil,
        headerFields: nil)!
      return (response, Data())
    }

    await #expect(throws: (any Error).self) {
      try await client.fetchDailyPrices(
        ticker: "BHP.AX", from: date("2022-04-05"), to: date("2022-04-07"))
    }
  }
}

// MARK: - URLProtocol stub (same pattern as RemoteAccountRepositoryTests)

private class URLProtocolStub: URLProtocol {
  nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

  static func register() {
    URLProtocol.registerClass(URLProtocolStub.self)
  }

  override class func canInit(with request: URLRequest) -> Bool {
    return true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    return request
  }

  override func startLoading() {
    guard let handler = URLProtocolStub.requestHandler else {
      fatalError("Handler is not set.")
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `just test`
Expected: FAIL — `YahooFinanceClient` does not exist yet.

- [ ] **Step 5: Implement YahooFinanceClient**

Create `Backends/YahooFinance/YahooFinanceClient.swift`:

```swift
// Backends/YahooFinance/YahooFinanceClient.swift
import Foundation

enum YahooFinanceError: Error {
  case invalidResponse
  case apiError(code: String, description: String)
  case noData
}

struct YahooFinanceClient: StockPriceClient, Sendable {
  private static let baseURL = URL(string: "https://query2.finance.yahoo.com/v8/finance/chart/")!
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func fetchDailyPrices(ticker: String, from: Date, to: Date) async throws -> StockPriceResponse {
    let url = Self.baseURL.appendingPathComponent(ticker)
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "period1", value: String(Int(from.timeIntervalSince1970))),
      URLQueryItem(name: "period2", value: String(Int(to.timeIntervalSince1970))),
      URLQueryItem(name: "interval", value: "1d"),
    ]

    var request = URLRequest(url: components.url!)
    request.setValue(
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)",
      forHTTPHeaderField: "User-Agent"
    )

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse,
      (200...299).contains(httpResponse.statusCode)
    else {
      throw URLError(.badServerResponse)
    }

    return try Self.parseResponse(data)
  }

  static func parseResponse(_ data: Data) throws -> StockPriceResponse {
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let chart = json?["chart"] as? [String: Any] else {
      throw YahooFinanceError.invalidResponse
    }

    // Check for error response
    if let error = chart["error"] as? [String: Any],
      let code = error["code"] as? String
    {
      let description = error["description"] as? String ?? "Unknown error"
      throw YahooFinanceError.apiError(code: code, description: description)
    }

    guard let results = chart["result"] as? [[String: Any]],
      let result = results.first
    else {
      throw YahooFinanceError.noData
    }

    // Extract currency from meta
    guard let meta = result["meta"] as? [String: Any],
      let currencyCode = meta["currency"] as? String
    else {
      throw YahooFinanceError.invalidResponse
    }
    let currency = Currency.from(code: currencyCode)

    // Extract timestamps
    guard let timestamps = result["timestamp"] as? [Int] else {
      throw YahooFinanceError.noData
    }

    // Extract adjusted close prices
    guard let indicators = result["indicators"] as? [String: Any],
      let adjcloseArray = indicators["adjclose"] as? [[String: Any]],
      let adjcloseData = adjcloseArray.first,
      let adjcloseValues = adjcloseData["adjclose"] as? [Double?]
    else {
      throw YahooFinanceError.invalidResponse
    }

    // Zip timestamps with adjusted close, skipping nulls
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]

    var prices: [String: Decimal] = [:]
    for (index, timestamp) in timestamps.enumerated() {
      guard index < adjcloseValues.count,
        let value = adjcloseValues[index]
      else {
        continue
      }
      let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
      let dateString = formatter.string(from: date)
      prices[dateString] = Decimal(value)
    }

    return StockPriceResponse(currency: currency, prices: prices)
  }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `just test`
Expected: All `YahooFinanceClientTests` pass.

- [ ] **Step 7: Commit**

```bash
git add MoolahTests/Support/Fixtures/yahoo-finance-chart-response.json \
  MoolahTests/Support/Fixtures/yahoo-finance-error-response.json \
  MoolahTests/Shared/YahooFinanceClientTests.swift \
  Backends/YahooFinance/YahooFinanceClient.swift
git commit -m "feat: add YahooFinanceClient with URLProtocol-stubbed tests"
```

---

### Task 5: Wire into ProfileSession

**Files:**
- Modify: `App/ProfileSession.swift`

- [ ] **Step 1: Add stockPriceService property to ProfileSession**

In `App/ProfileSession.swift`, add the property declaration after `exchangeRateService` (line 18):

```swift
  let stockPriceService: StockPriceService
```

- [ ] **Step 2: Initialize stockPriceService in init**

In `App/ProfileSession.swift`, add initialization after the `exchangeRateService` line (line 58):

```swift
    self.stockPriceService = StockPriceService(client: YahooFinanceClient())
```

- [ ] **Step 3: Build to verify compilation**

Run: `just build-mac`
Expected: BUILD SUCCEEDED with no warnings.

- [ ] **Step 4: Run full test suite**

Run: `just test`
Expected: All tests pass, including all existing tests (no regressions).

- [ ] **Step 5: Check for compiler warnings**

Use Xcode MCP: `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"`
Expected: No warnings in user code (preview macro warnings can be ignored).

- [ ] **Step 6: Commit**

```bash
git add App/ProfileSession.swift
git commit -m "feat: wire StockPriceService into ProfileSession"
```

---

### Task 6: Regenerate Xcode Project

**Files:**
- Modify: `project.yml` (only if needed — sources use directory-based includes)

- [ ] **Step 1: Check if project.yml needs changes**

Read `project.yml` source paths. The app targets use directory-based includes (`- path: Domain`, `- path: Shared`, `- path: Backends`, `- path: App`). New files in these directories are automatically included. The `Backends/YahooFinance/` subdirectory is new, but it's under `Backends/` which is already included.

Test targets use `- path: MoolahTests` which includes all test files.

No changes to `project.yml` should be needed.

- [ ] **Step 2: Regenerate Xcode project**

Run: `just generate`
Expected: `Moolah.xcodeproj` regenerated successfully.

- [ ] **Step 3: Build and run full test suite**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 4: Commit (only if project.yml changed)**

If `project.yml` was modified:
```bash
git add project.yml
git commit -m "chore: update project.yml for stock price service files"
```
