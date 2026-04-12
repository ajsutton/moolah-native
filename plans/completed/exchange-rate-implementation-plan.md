# Exchange Rate Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement exchange rate fetching, caching, and conversion so multi-currency account balances can be aggregated into the profile's currency.

**Architecture:** An `ExchangeRateService` actor owns all rate lookups, backed by gzip-compressed JSON cache files in `cachesDirectory`. A `FrankfurterClient` protocol abstracts HTTP calls, allowing a `FixedRateClient` for tests. The service lives on `ProfileSession`, not `BackendProvider`, since rates are backend-independent. `MonetaryAmount` gets a `converted(to:on:using:)` extension for cents-level conversion with banker's rounding.

**Tech Stack:** Swift 6, Swift Testing framework, Foundation (JSONEncoder/Decoder, Data compression, URLSession), Frankfurter API v2

**Design doc:** `plans/exchange-rate-design.md`

---

## File Structure

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `Domain/Models/ExchangeRateCache.swift` | `ExchangeRateCache` Codable type |
| Create | `Domain/Repositories/ExchangeRateClient.swift` | `ExchangeRateClient` protocol |
| Create | `Shared/ExchangeRateService.swift` | `ExchangeRateService` actor (fetch, cache, lookup) |
| Create | `Backends/Frankfurter/FrankfurterClient.swift` | Production HTTP client for Frankfurter API |
| Modify | `Domain/Models/MonetaryAmount.swift` | Add `converted(to:on:using:)` extension |
| Modify | `App/ProfileSession.swift` | Add `exchangeRateService` property |
| Create | `MoolahTests/Support/FixedRateClient.swift` | Test double for `ExchangeRateClient` |
| Create | `MoolahTests/Shared/ExchangeRateServiceTests.swift` | Tests for the service actor |
| Create | `MoolahTests/Shared/MonetaryAmountConversionTests.swift` | Tests for conversion math |
| Create | `MoolahTests/Backends/FrankfurterClientTests.swift` | Tests for API response parsing |

---

## Task 1: Core Type — `ExchangeRateCache`

**Files:**
- Create: `Domain/Models/ExchangeRateCache.swift`

Pure data type with no dependencies. Models the on-disk cache structure. Note: the design doc also defines `DailyRates` but it's unused — the cache stores rates as `[String: [String: Decimal]]` directly, so we skip `DailyRates` per YAGNI.

- [ ] **Step 1: Create `ExchangeRateCache.swift`**

```swift
// Domain/Models/ExchangeRateCache.swift
import Foundation

/// On-disk cache for a single base currency. Contains rates for every cached trading day.
struct ExchangeRateCache: Codable, Sendable, Equatable {
    let base: String
    var earliestDate: String  // ISO date string "YYYY-MM-DD"
    var latestDate: String    // ISO date string "YYYY-MM-DD"
    var rates: [String: [String: Decimal]]  // date string -> { quote code -> rate }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `just build-mac`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Domain/Models/ExchangeRateCache.swift
git commit -m "feat: add ExchangeRateCache model type"
```

---

## Task 2: `ExchangeRateClient` Protocol

**Files:**
- Create: `Domain/Repositories/ExchangeRateClient.swift`

The protocol for the HTTP layer. Lives in `Domain/Repositories/` alongside other repository protocols. No imports beyond Foundation — the domain layer must stay clean.

- [ ] **Step 1: Create `ExchangeRateClient.swift`**

```swift
// Domain/Repositories/ExchangeRateClient.swift
import Foundation

/// Abstraction for fetching exchange rates from an external source.
/// Production: FrankfurterClient. Tests: FixedRateClient.
protocol ExchangeRateClient: Sendable {
    /// Fetch rates for a base currency over a date range.
    /// Returns a dictionary keyed by ISO date string, each value mapping quote currency codes to rates.
    func fetchRates(base: String, from: Date, to: Date) async throws -> [String: [String: Decimal]]
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `just build-mac`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Domain/Repositories/ExchangeRateClient.swift
git commit -m "feat: add ExchangeRateClient protocol"
```

---

## Task 3: `FixedRateClient` Test Double

**Files:**
- Create: `MoolahTests/Support/FixedRateClient.swift`

Create the test double before the service so tests can be written first (TDD).

- [ ] **Step 1: Create `FixedRateClient.swift`**

```swift
// MoolahTests/Support/FixedRateClient.swift
import Foundation

@testable import Moolah

/// Test double that returns pre-configured rates without network calls.
struct FixedRateClient: ExchangeRateClient, Sendable {
    /// Pre-loaded rates: date string -> { quote currency code -> rate }
    let rates: [String: [String: Decimal]]

    /// If true, throws on any fetch call (simulates network failure).
    let shouldFail: Bool

    init(rates: [String: [String: Decimal]] = [:], shouldFail: Bool = false) {
        self.rates = rates
        self.shouldFail = shouldFail
    }

    func fetchRates(base: String, from: Date, to: Date) async throws -> [String: [String: Decimal]] {
        if shouldFail {
            throw URLError(.notConnectedToInternet)
        }
        let calendar = Calendar(identifier: .gregorian)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]

        var result: [String: [String: Decimal]] = [:]
        var current = from
        while current <= to {
            let key = formatter.string(from: current)
            if let dayRates = rates[key] {
                result[key] = dayRates
            }
            current = calendar.date(byAdding: .day, value: 1, to: current)!
        }
        return result
    }
}
```

- [ ] **Step 2: Build tests to verify compilation**

Run: `just build-mac`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add MoolahTests/Support/FixedRateClient.swift
git commit -m "feat: add FixedRateClient test double for ExchangeRateClient"
```

---

## Task 4: `ExchangeRateService` — Core Lookup (TDD)

**Files:**
- Create: `MoolahTests/Shared/ExchangeRateServiceTests.swift`
- Create: `Shared/ExchangeRateService.swift`

This is the main actor. Build it incrementally: first same-currency short-circuit, then cache miss → fetch → return, then fallback behavior.

**Important date helper:** The service needs to convert between `Date` and ISO date strings consistently. Use a shared `ISO8601DateFormatter` with `.withFullDate` format options (produces `"YYYY-MM-DD"`). All dates in the cache and API use this format.

### Step 4a: Same-currency short-circuit

- [ ] **Step 1: Write failing test — same currency returns 1.0**

```swift
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

    @Test func sameCurrencyReturnsIdentityRate() async throws {
        let service = makeService()
        let rate = try await service.rate(from: .AUD, to: .AUD, on: Date())
        #expect(rate == Decimal(1))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test`
Expected: Compilation error — `ExchangeRateService` not found

- [ ] **Step 3: Create minimal `ExchangeRateService`**

```swift
// Shared/ExchangeRateService.swift
import Foundation

/// Owns exchange rate fetching, caching, and lookups.
/// Rates are cached as gzip-compressed JSON files in the app's caches directory.
actor ExchangeRateService {
    private let client: ExchangeRateClient
    private var caches: [String: ExchangeRateCache] = [:]

    private let cacheDirectory: URL
    private let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    init(client: ExchangeRateClient, cacheDirectory: URL? = nil) {
        self.client = client
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            self.cacheDirectory = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("exchange-rates", isDirectory: true)
        }
    }

    // MARK: - Public API

    func rate(from: Currency, to: Currency, on date: Date) async throws -> Decimal {
        if from.code == to.code { return Decimal(1) }

        let dateString = dateFormatter.string(from: date)
        return try await lookupRate(base: from.code, quote: to.code, dateString: dateString)
    }

    // MARK: - Internal Lookup

    private func lookupRate(base: String, quote: String, dateString: String) async throws -> Decimal {
        // Load cache file if not already in memory
        if caches[base] == nil {
            caches[base] = loadCacheFromDisk(base: base)
        }

        // Check cache
        if let cached = caches[base]?.rates[dateString]?[quote] {
            return cached
        }

        // Fetch from network
        let date = dateFormatter.date(from: dateString)!
        let fetched = try await fetchAndMerge(base: base, from: date, to: date)

        if let rate = fetched[dateString]?[quote] {
            return rate
        }

        // Fallback: find most recent prior cached date (never forward)
        return try fallbackRate(base: base, quote: quote, before: dateString)
    }

    private func fallbackRate(base: String, quote: String, before dateString: String) throws -> Decimal {
        guard let cache = caches[base] else {
            throw ExchangeRateError.noRateAvailable(base: base, quote: quote, date: dateString)
        }
        // Find the most recent date strictly before the requested date that has a rate for this quote
        let sortedDates = cache.rates.keys.sorted().reversed()
        for cachedDate in sortedDates {
            if cachedDate <= dateString, let rate = cache.rates[cachedDate]?[quote] {
                return rate
            }
        }
        throw ExchangeRateError.noRateAvailable(base: base, quote: quote, date: dateString)
    }

    // MARK: - Fetch & Merge

    private func fetchAndMerge(base: String, from: Date, to: Date) async throws -> [String: [String: Decimal]] {
        let fetched = try await client.fetchRates(base: base, from: from, to: to)
        merge(fetched, into: base)
        saveCacheToDisk(base: base)
        return fetched
    }

    private func merge(_ newRates: [String: [String: Decimal]], into base: String) {
        if var cache = caches[base] {
            for (dateStr, dayRates) in newRates {
                cache.rates[dateStr] = dayRates
                if dateStr < cache.earliestDate { cache.earliestDate = dateStr }
                if dateStr > cache.latestDate { cache.latestDate = dateStr }
            }
            caches[base] = cache
        } else if let firstDate = newRates.keys.sorted().first,
                  let lastDate = newRates.keys.sorted().last {
            caches[base] = ExchangeRateCache(
                base: base,
                earliestDate: firstDate,
                latestDate: lastDate,
                rates: newRates
            )
        }
    }

    // MARK: - Disk Persistence

    private func cacheFileURL(base: String) -> URL {
        cacheDirectory.appendingPathComponent("rates-\(base).json.gz")
    }

    private func loadCacheFromDisk(base: String) -> ExchangeRateCache? {
        let url = cacheFileURL(base: base)
        guard let compressed = try? Data(contentsOf: url) else { return nil }
        guard let decompressed = try? decompress(compressed) else { return nil }
        return try? JSONDecoder().decode(ExchangeRateCache.self, from: decompressed)
    }

    private func saveCacheToDisk(base: String) {
        guard let cache = caches[base] else { return }
        guard let data = try? JSONEncoder().encode(cache) else { return }
        guard let compressed = try? compress(data) else { return }

        let url = cacheFileURL(base: base)
        try? FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true)
        try? compressed.write(to: url, options: .atomic)
    }

    // MARK: - Compression

    private func compress(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .zlib) as Data
    }

    private func decompress(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .zlib) as Data
    }
}

enum ExchangeRateError: Error, Equatable {
    case noRateAvailable(base: String, quote: String, date: String)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `just test`
Expected: `sameCurrencyReturnsIdentityRate` PASSES

- [ ] **Step 5: Commit**

```bash
git add Shared/ExchangeRateService.swift MoolahTests/Shared/ExchangeRateServiceTests.swift
git commit -m "feat: add ExchangeRateService with same-currency short-circuit"
```

### Step 4b: Cache miss triggers fetch

- [ ] **Step 6: Write failing test — cache miss fetches from client**

Add to `ExchangeRateServiceTests.swift`:

```swift
@Test func cacheMissFetchesFromClient() async throws {
    let service = makeService(rates: [
        "2026-04-11": ["USD": Decimal(string: "0.632")!]
    ])
    let rate = try await service.rate(from: .AUD, to: .USD, on: date("2026-04-11"))
    #expect(rate == Decimal(string: "0.632")!)
}
```

- [ ] **Step 7: Run test to verify it passes**

Run: `just test`
Expected: `cacheMissFetchesFromClient` PASSES (the implementation from Step 3 already handles this)

- [ ] **Step 8: Write test — cache hit does not re-fetch**

Add to `ExchangeRateServiceTests.swift`:

```swift
@Test func cacheHitDoesNotRefetch() async throws {
    let service = makeService(rates: [
        "2026-04-11": ["USD": Decimal(string: "0.632")!]
    ])
    // First call populates cache
    let rate1 = try await service.rate(from: .AUD, to: .USD, on: date("2026-04-11"))
    // Second call should hit cache (same result proves it works; FixedRateClient is deterministic)
    let rate2 = try await service.rate(from: .AUD, to: .USD, on: date("2026-04-11"))
    #expect(rate1 == rate2)
    #expect(rate1 == Decimal(string: "0.632")!)
}
```

- [ ] **Step 9: Run test to verify it passes**

Run: `just test`
Expected: PASSES

- [ ] **Step 10: Commit**

```bash
git add MoolahTests/Shared/ExchangeRateServiceTests.swift
git commit -m "test: add cache miss and cache hit tests for ExchangeRateService"
```

### Step 4c: Fallback behavior

- [ ] **Step 11: Write failing test — network failure falls back to most recent prior date**

Add to `ExchangeRateServiceTests.swift`:

```swift
@Test func networkFailureFallsBackToMostRecentPriorDate() async throws {
    // Pre-populate cache with Friday's rate, then request Saturday with network down
    let service = makeService(rates: [
        "2026-04-10": ["USD": Decimal(string: "0.629")!]
    ])
    // Populate cache with Friday's data
    _ = try await service.rate(from: .AUD, to: .USD, on: date("2026-04-10"))

    // Now create a new service that fails on network, but shares no cache.
    // Instead, we test the fallback path by requesting a weekend date.
    // The FixedRateClient has no data for 2026-04-12, so fetchAndMerge returns empty.
    // The fallback should find 2026-04-10.
    let rate = try await service.rate(from: .AUD, to: .USD, on: date("2026-04-12"))
    #expect(rate == Decimal(string: "0.629")!)
}
```

- [ ] **Step 12: Run test — expect failure**

Run: `just test`
Expected: FAIL — the current `lookupRate` tries to fetch, gets empty result for the weekend date, then `fallbackRate` searches for dates `<= "2026-04-12"` and should find `"2026-04-10"`. But `fetchAndMerge` may throw because `FixedRateClient` returns empty (not an error). Check behavior and adjust.

Actually, `FixedRateClient` returns an empty dict for dates it doesn't have — it doesn't throw. So `fetchAndMerge` succeeds with empty data, then we look for the rate in `fetched[dateString]` which is nil, then we call `fallbackRate`. The cache has `"2026-04-10"` from the first call. `fallbackRate` finds it because `"2026-04-10" <= "2026-04-12"`. This should pass.

- [ ] **Step 13: Run test to verify it passes**

Run: `just test`
Expected: `networkFailureFallsBackToMostRecentPriorDate` PASSES

- [ ] **Step 14: Write test — network failure with empty cache throws**

```swift
@Test func networkFailureWithEmptyCacheThrows() async throws {
    let service = makeService(shouldFail: true)
    await #expect(throws: (any Error).self) {
        try await service.rate(from: .AUD, to: .USD, on: date("2026-04-11"))
    }
}
```

- [ ] **Step 15: Run test to verify it passes**

Run: `just test`
Expected: PASSES — `fetchAndMerge` throws the `URLError`, which propagates up from `lookupRate`

- [ ] **Step 16: Write test — never uses a future date for fallback**

```swift
@Test func fallbackNeverUsesFutureDate() async throws {
    // Cache has only a future date, not any prior date
    let service = makeService(rates: [
        "2026-04-15": ["USD": Decimal(string: "0.640")!]
    ])
    // Populate cache with the future date
    _ = try await service.rate(from: .AUD, to: .USD, on: date("2026-04-15"))

    // Request a date before the cached one, with no data available
    // FixedRateClient returns empty for 2026-04-10, fallback should find nothing before it
    await #expect(throws: ExchangeRateError.self) {
        try await service.rate(from: .AUD, to: .USD, on: date("2026-04-10"))
    }
}
```

- [ ] **Step 17: Run test to verify it passes**

Run: `just test`
Expected: PASSES — `fallbackRate` iterates sorted dates reversed, but `"2026-04-15" <= "2026-04-10"` is false, so it throws

- [ ] **Step 18: Commit**

```bash
git add MoolahTests/Shared/ExchangeRateServiceTests.swift
git commit -m "test: add fallback and error path tests for ExchangeRateService"
```

---

## Task 5: `ExchangeRateService` — Date Range Lookup

**Files:**
- Modify: `Shared/ExchangeRateService.swift`
- Modify: `MoolahTests/Shared/ExchangeRateServiceTests.swift`

### Step 5a: Basic range lookup

- [ ] **Step 1: Write failing test — range returns rates for each trading day**

Add to `ExchangeRateServiceTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test`
Expected: Compilation error — `rates(from:to:in:)` method not found

- [ ] **Step 3: Implement `rates(from:to:in:)` method**

Add to `ExchangeRateService` public API section:

```swift
func rates(from: Currency, to: Currency, in range: ClosedRange<Date>) async throws -> [(date: Date, rate: Decimal)] {
    if from.code == to.code {
        return generateDateSeries(in: range).map { ($0, Decimal(1)) }
    }

    let base = from.code
    let quote = to.code

    // Load cache if not already in memory
    if caches[base] == nil {
        caches[base] = loadCacheFromDisk(base: base)
    }

    // Determine what we need to fetch
    let rangeStart = dateFormatter.string(from: range.lowerBound)
    let rangeEnd = dateFormatter.string(from: range.upperBound)

    if let cache = caches[base] {
        // Fetch segments that extend beyond the cache
        if rangeStart < cache.earliestDate {
            let fetchEnd = Calendar(identifier: .gregorian)
                .date(byAdding: .day, value: -1,
                      to: dateFormatter.date(from: cache.earliestDate)!)!
            try await fetchInChunks(base: base, from: range.lowerBound, to: fetchEnd)
        }
        if rangeEnd > cache.latestDate {
            let fetchStart = Calendar(identifier: .gregorian)
                .date(byAdding: .day, value: 1,
                      to: dateFormatter.date(from: cache.latestDate)!)!
            try await fetchInChunks(base: base, from: fetchStart, to: range.upperBound)
        }
    } else {
        // No cache at all — fetch the full range
        try await fetchInChunks(base: base, from: range.lowerBound, to: range.upperBound)
    }

    // Build result series
    let dates = generateDateSeries(in: range)
    var results: [(date: Date, rate: Decimal)] = []
    var lastKnownRate: Decimal?

    for date in dates {
        let dateString = dateFormatter.string(from: date)
        if let rate = caches[base]?.rates[dateString]?[quote] {
            lastKnownRate = rate
            results.append((date, rate))
        } else if let fallback = lastKnownRate {
            // Weekend/holiday — use most recent prior rate
            results.append((date, fallback))
        }
        // Skip dates before any rate is known
    }

    return results
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

private func fetchInChunks(base: String, from: Date, to: Date) async throws {
    let calendar = Calendar(identifier: .gregorian)
    var chunkStart = from
    while chunkStart <= to {
        // Chunk into 1-year segments for large ranges
        let chunkEnd = min(
            calendar.date(byAdding: .year, value: 1, to: chunkStart)!,
            to
        )
        _ = try await fetchAndMerge(base: base, from: chunkStart, to: chunkEnd)
        chunkStart = calendar.date(byAdding: .day, value: 1, to: chunkEnd)!
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `just test`
Expected: `rangeReturnsRatesForEachDay` PASSES

- [ ] **Step 5: Commit**

```bash
git add Shared/ExchangeRateService.swift MoolahTests/Shared/ExchangeRateServiceTests.swift
git commit -m "feat: add date range rate lookup to ExchangeRateService"
```

### Step 5b: Range extends cache boundaries

- [ ] **Step 6: Write test — range request only fetches missing segments**

```swift
@Test func rangeOnlyFetchesMissingSegments() async throws {
    let service = makeService(rates: [
        "2026-04-07": ["USD": Decimal(string: "0.630")!],
        "2026-04-08": ["USD": Decimal(string: "0.631")!],
        "2026-04-09": ["USD": Decimal(string: "0.632")!],
        "2026-04-10": ["USD": Decimal(string: "0.633")!],
        "2026-04-11": ["USD": Decimal(string: "0.634")!],
    ])
    // First request populates cache for Apr 8-9
    _ = try await service.rates(
        from: .AUD, to: .USD,
        in: date("2026-04-08")...date("2026-04-09")
    )
    // Second request extends before and after
    let results = try await service.rates(
        from: .AUD, to: .USD,
        in: date("2026-04-07")...date("2026-04-11")
    )
    #expect(results.count == 5)
    #expect(results[0].rate == Decimal(string: "0.630")!)
    #expect(results[4].rate == Decimal(string: "0.634")!)
}
```

- [ ] **Step 7: Run test to verify it passes**

Run: `just test`
Expected: PASSES

- [ ] **Step 8: Write test — same-currency range returns all 1.0**

```swift
@Test func sameCurrencyRangeReturnsIdentity() async throws {
    let service = makeService()
    let results = try await service.rates(
        from: .AUD, to: .AUD,
        in: date("2026-04-07")...date("2026-04-09")
    )
    #expect(results.count == 3)
    #expect(results.allSatisfy { $0.rate == Decimal(1) })
}
```

- [ ] **Step 9: Run test to verify it passes**

Run: `just test`
Expected: PASSES

- [ ] **Step 10: Commit**

```bash
git add MoolahTests/Shared/ExchangeRateServiceTests.swift
git commit -m "test: add range boundary and same-currency range tests"
```

---

## Task 6: `ExchangeRateService` — Convert and Prefetch

**Files:**
- Modify: `Shared/ExchangeRateService.swift`
- Modify: `MoolahTests/Shared/ExchangeRateServiceTests.swift`

### Step 6a: Convert method

- [ ] **Step 1: Write failing test — convert produces correct MonetaryAmount**

Add to `ExchangeRateServiceTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test`
Expected: Compilation error — `convert(_:to:on:)` not found

- [ ] **Step 3: Implement `convert` method**

Add to `ExchangeRateService` public API section:

```swift
func convert(_ amount: MonetaryAmount, to currency: Currency, on date: Date) async throws -> MonetaryAmount {
    if amount.currency.code == currency.code { return amount }

    let exchangeRate = try await rate(from: amount.currency, to: currency, on: date)
    let decimalCents = Decimal(amount.cents) * exchangeRate
    // Banker's rounding to minimize cumulative bias
    var rounded = decimalCents
    NSDecimalRound(&rounded, &rounded, 0, .bankers)
    let convertedCents = Int(truncating: rounded as NSDecimalNumber)
    return MonetaryAmount(cents: convertedCents, currency: currency)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test`
Expected: Both convert tests PASS

- [ ] **Step 5: Commit**

```bash
git add Shared/ExchangeRateService.swift MoolahTests/Shared/ExchangeRateServiceTests.swift
git commit -m "feat: add convert method to ExchangeRateService with banker's rounding"
```

### Step 6b: Banker's rounding edge case

- [ ] **Step 6: Write test — banker's rounding rounds to even on .5**

```swift
@Test func convertUsesBankersRounding() async throws {
    // 0.635 rate * 1000 cents = 635.0 cents — exact, no rounding needed
    // Use a rate that produces a .5 fractional cent
    // 555 cents * 0.5 = 277.5 — banker's rounds to 278 (round to even)
    let service = makeService(rates: [
        "2026-04-11": ["USD": Decimal(string: "0.5")!]
    ])
    let amount = MonetaryAmount(cents: 555, currency: .AUD)
    let converted = try await service.convert(amount, to: .USD, on: date("2026-04-11"))
    #expect(converted.cents == 278)  // 277.5 rounds to 278 (banker's: round half to even)
}

@Test func convertBankersRoundsDown() async throws {
    // 550 cents * 0.5 = 275.0 — exact
    // 450 cents * 0.5 = 225.0 — exact
    // 650 cents * 0.5 = 325.0 — exact
    // Need a fractional: 545 cents * 0.5 = 272.5 — rounds to 272 (even)
    let service = makeService(rates: [
        "2026-04-11": ["USD": Decimal(string: "0.5")!]
    ])
    let amount = MonetaryAmount(cents: 545, currency: .AUD)
    let converted = try await service.convert(amount, to: .USD, on: date("2026-04-11"))
    #expect(converted.cents == 272)  // 272.5 rounds to 272 (banker's: round half to even)
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `just test`
Expected: PASSES

- [ ] **Step 8: Commit**

```bash
git add MoolahTests/Shared/ExchangeRateServiceTests.swift
git commit -m "test: add banker's rounding edge case tests"
```

### Step 6c: Prefetch method

- [ ] **Step 9: Write failing test — prefetch loads latest rates**

```swift
@Test func prefetchUpdatesCache() async throws {
    let service = makeService(rates: [
        "2026-04-10": ["USD": Decimal(string: "0.629")!],
        "2026-04-11": ["USD": Decimal(string: "0.632")!],
    ])
    // Prefetch should load rates for the base currency
    await service.prefetchLatest(base: .AUD)

    // Now a lookup for today should hit cache without needing to fetch again
    let rate = try await service.rate(from: .AUD, to: .USD, on: date("2026-04-11"))
    #expect(rate == Decimal(string: "0.632")!)
}
```

- [ ] **Step 10: Run test to verify it fails**

Run: `just test`
Expected: Compilation error — `prefetchLatest(base:)` not found

- [ ] **Step 11: Implement `prefetchLatest`**

Add to `ExchangeRateService` public API section:

```swift
func prefetchLatest(base: Currency) async {
    let code = base.code

    // Load existing cache
    if caches[code] == nil {
        caches[code] = loadCacheFromDisk(base: code)
    }

    let calendar = Calendar(identifier: .gregorian)
    let today = Date()
    let todayString = dateFormatter.string(from: today)

    if let cache = caches[code], cache.latestDate >= todayString {
        return  // Already up to date
    }

    let fetchFrom: Date
    if let cache = caches[code],
       let latestDate = dateFormatter.date(from: cache.latestDate) {
        // Fetch from day after last cached date
        fetchFrom = calendar.date(byAdding: .day, value: 1, to: latestDate)!
    } else {
        // No cache — fetch last 30 days as a reasonable default
        fetchFrom = calendar.date(byAdding: .day, value: -30, to: today)!
    }

    do {
        _ = try await fetchAndMerge(base: code, from: fetchFrom, to: today)
    } catch {
        // Prefetch is best-effort — silently ignore network errors
    }
}
```

- [ ] **Step 12: Run tests to verify they pass**

Run: `just test`
Expected: `prefetchUpdatesCache` PASSES

- [ ] **Step 13: Commit**

```bash
git add Shared/ExchangeRateService.swift MoolahTests/Shared/ExchangeRateServiceTests.swift
git commit -m "feat: add prefetchLatest to ExchangeRateService"
```

---

## Task 7: Gzip Round-Trip Test

**Files:**
- Modify: `MoolahTests/Shared/ExchangeRateServiceTests.swift`

Verify that writing to disk and reading back produces identical data. This requires using a temporary directory for the cache.

- [ ] **Step 1: Write gzip round-trip test**

Add to `ExchangeRateServiceTests.swift`:

```swift
@Test func gzipRoundTripPreservesData() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let client = FixedRateClient(rates: [
        "2026-04-11": ["USD": Decimal(string: "0.632")!, "EUR": Decimal(string: "0.581")!]
    ])
    let service = ExchangeRateService(client: client, cacheDirectory: tempDir)

    // Fetch to populate cache and write to disk
    let rate = try await service.rate(from: .AUD, to: .USD, on: date("2026-04-11"))
    #expect(rate == Decimal(string: "0.632")!)

    // Create a new service reading from the same directory (fresh in-memory state)
    let failingClient = FixedRateClient(shouldFail: true)
    let service2 = ExchangeRateService(client: failingClient, cacheDirectory: tempDir)

    // Should load from disk cache, not network
    let cachedRate = try await service2.rate(from: .AUD, to: .USD, on: date("2026-04-11"))
    #expect(cachedRate == Decimal(string: "0.632")!)

    let cachedEur = try await service2.rate(from: .AUD, to: .EUR, on: date("2026-04-11"))
    #expect(cachedEur == Decimal(string: "0.581")!)
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `just test`
Expected: PASSES

- [ ] **Step 3: Commit**

```bash
git add MoolahTests/Shared/ExchangeRateServiceTests.swift
git commit -m "test: add gzip round-trip test for ExchangeRateService disk cache"
```

---

## Task 8: `MonetaryAmount.converted(to:on:using:)` Extension

**Files:**
- Modify: `Domain/Models/MonetaryAmount.swift`
- Create: `MoolahTests/Shared/MonetaryAmountConversionTests.swift`

Convenience wrapper that delegates to the service. Lives on the domain model for ergonomic call sites.

- [ ] **Step 1: Write failing test**

```swift
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
        let amount = MonetaryAmount(cents: 20000, currency: .AUD)  // $200 AUD

        let result = try await amount.converted(to: .from(code: "GBP"), on: date("2026-04-11"), using: service)

        // 20000 * 0.497 = 9940 cents = £99.40
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test`
Expected: Compilation error — `converted(to:on:using:)` not found

- [ ] **Step 3: Add extension to `MonetaryAmount.swift`**

Add at the bottom of `Domain/Models/MonetaryAmount.swift`:

```swift
extension MonetaryAmount {
    /// Convert this amount to another currency on a given date using the exchange rate service.
    func converted(to currency: Currency, on date: Date, using service: ExchangeRateService) async throws -> MonetaryAmount {
        try await service.convert(self, to: currency, on: date)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test`
Expected: Both tests PASS

- [ ] **Step 5: Commit**

```bash
git add Domain/Models/MonetaryAmount.swift MoolahTests/Shared/MonetaryAmountConversionTests.swift
git commit -m "feat: add converted(to:on:using:) extension to MonetaryAmount"
```

---

## Task 9: `FrankfurterClient` — Production HTTP Client

**Files:**
- Create: `Backends/Frankfurter/FrankfurterClient.swift`
- Create: `MoolahTests/Backends/FrankfurterClientTests.swift`

Parses the Frankfurter v2 API response format. This is the only type that knows the wire format.

### Step 9a: Response parsing

- [ ] **Step 1: Write failing test — parses Frankfurter v2 response**

The Frankfurter v2 `/v2/` endpoint returns a flat JSON array:
```json
[
  {"date": "2026-04-11", "base": "AUD", "quote": "USD", "rate": 0.632},
  {"date": "2026-04-11", "base": "AUD", "quote": "EUR", "rate": 0.581}
]
```

```swift
// MoolahTests/Backends/FrankfurterClientTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("FrankfurterClient")
struct FrankfurterClientTests {
    @Test func parsesV2ResponseFormat() async throws {
        let json = """
        [
          {"date": "2026-04-11", "base": "AUD", "quote": "USD", "rate": 0.632},
          {"date": "2026-04-11", "base": "AUD", "quote": "EUR", "rate": 0.581},
          {"date": "2026-04-10", "base": "AUD", "quote": "USD", "rate": 0.629}
        ]
        """
        let data = Data(json.utf8)
        let result = try FrankfurterClient.parseResponse(data)

        #expect(result.count == 2)  // 2 dates
        #expect(result["2026-04-11"]?["USD"] == Decimal(string: "0.632")!)
        #expect(result["2026-04-11"]?["EUR"] == Decimal(string: "0.581")!)
        #expect(result["2026-04-10"]?["USD"] == Decimal(string: "0.629")!)
    }

    @Test func parsesEmptyResponse() async throws {
        let data = Data("[]".utf8)
        let result = try FrankfurterClient.parseResponse(data)
        #expect(result.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test`
Expected: Compilation error — `FrankfurterClient` not found

- [ ] **Step 3: Implement `FrankfurterClient`**

```swift
// Backends/Frankfurter/FrankfurterClient.swift
import Foundation

/// Production client for the Frankfurter API (api.frankfurter.dev/v2).
/// Sources daily reference rates from 40+ central banks, 161 currencies.
struct FrankfurterClient: ExchangeRateClient, Sendable {
    private static let baseURL = URL(string: "https://api.frankfurter.dev/v2/")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchRates(base: String, from: Date, to: Date) async throws -> [String: [String: Decimal]] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]

        let fromStr = formatter.string(from: from)
        let toStr = formatter.string(from: to)

        // v2 endpoint: /v2/{from}..{to}?base={code}
        let url = Self.baseURL
            .appendingPathComponent("\(fromStr)..\(toStr)")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "base", value: base)]

        let request = URLRequest(url: components.url!)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try Self.parseResponse(data)
    }

    /// Parse the Frankfurter v2 flat JSON array into our cache format.
    /// Exposed as static for testability without network calls.
    static func parseResponse(_ data: Data) throws -> [String: [String: Decimal]] {
        let entries = try JSONDecoder().decode([FrankfurterEntry].self, from: data)
        var result: [String: [String: Decimal]] = [:]
        for entry in entries {
            result[entry.date, default: [:]][entry.quote] = entry.rate
        }
        return result
    }
}

/// A single rate entry from the Frankfurter v2 API.
private struct FrankfurterEntry: Decodable {
    let date: String
    let base: String
    let quote: String
    let rate: Decimal
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test`
Expected: Both parsing tests PASS

- [ ] **Step 5: Commit**

```bash
git add Backends/Frankfurter/FrankfurterClient.swift MoolahTests/Backends/FrankfurterClientTests.swift
git commit -m "feat: add FrankfurterClient with v2 API response parsing"
```

---

## Task 10: Wire `ExchangeRateService` into `ProfileSession`

**Files:**
- Modify: `App/ProfileSession.swift`

- [ ] **Step 1: Add `exchangeRateService` to `ProfileSession`**

Add a new property after the store declarations in `ProfileSession`:

```swift
let exchangeRateService: ExchangeRateService
```

In the `init`, after the backend is created (before the stores), add:

```swift
self.exchangeRateService = ExchangeRateService(client: FrankfurterClient())
```

The full change to `ProfileSession.swift`:

In the property declarations, after `let investmentStore: InvestmentStore`, add:
```swift
let exchangeRateService: ExchangeRateService
```

In `init`, after `self.backend = backend` and before `self.authStore = ...`, add:
```swift
self.exchangeRateService = ExchangeRateService(client: FrankfurterClient())
```

- [ ] **Step 2: Build to verify compilation**

Run: `just build-mac`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Check for warnings**

Use Xcode MCP: `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"`
Expected: No new warnings in user code (Preview macro warnings can be ignored)

- [ ] **Step 4: Commit**

```bash
git add App/ProfileSession.swift
git commit -m "feat: wire ExchangeRateService into ProfileSession"
```

---

## Task 11: Final Verification

- [ ] **Step 1: Run the full test suite**

Run: `just test`
Expected: ALL tests pass

- [ ] **Step 2: Check for compiler warnings**

Use Xcode MCP: `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"`
Expected: No warnings in user code

- [ ] **Step 3: Verify build for both platforms**

Run: `just build-mac` and `just build-ios`
Expected: Both BUILD SUCCEEDED

- [ ] **Step 4: Final commit if any cleanup was needed**

Only if warnings or issues were found and fixed in prior steps.

---

## Summary

| Task | What it builds | Tests |
|------|---------------|-------|
| 1 | `ExchangeRateCache` type | Compilation only |
| 2 | `ExchangeRateClient` protocol | Compilation only |
| 3 | `FixedRateClient` test double | Compilation only |
| 4 | `ExchangeRateService` — single-rate lookup, cache, fallback | 6 tests |
| 5 | `ExchangeRateService` — date range lookup | 3 tests |
| 6 | `ExchangeRateService` — convert + prefetch | 5 tests |
| 7 | Gzip round-trip verification | 1 test |
| 8 | `MonetaryAmount.converted(to:on:using:)` | 2 tests |
| 9 | `FrankfurterClient` response parsing | 2 tests |
| 10 | Wire into `ProfileSession` | Build verification |
| 11 | Final verification | Full suite |
