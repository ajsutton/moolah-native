# Sorted-Array Price/Rate Caches (Plan B — Performance) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the historic-series build fast by replacing the per-call `keys.sorted()` in `StockPriceService` / `ExchangeRateService` / `CryptoPriceService` with date-sorted contiguous arrays (O(log n) lookups), using less RAM than the current dictionaries.

**Architecture:** One shared generic `SortedDateSeries<Value>` (binary-search `exact` / `floor`, `upsert`, `merge`) plus an `Int32` `yyyymmdd` `DateKey` helper. The three `Codable` cache models swap their date-keyed dictionaries for `SortedDateSeries`. Each service's `lookup* / fallback* / range-builder / mergeReturningDelta / loadCache` is rewritten against the array. On-disk schema and GRDB records are unchanged — String↔Int32 conversion happens only at the persistence boundary.

**Tech Stack:** Swift 6, GRDB, Swift Testing (`import Testing`), `TestBackend`. Build/test via `just`.

**Scope note:** Plan B of two. Plan A (responsive two-phase load) is independent and ships separately. Plan B is behavior-preserving: every lookup returns exactly what the old sort-then-scan returned; only the data structure and complexity change.

**Spec:** `plans/2026-05-16-responsive-investment-load-design.md`

**Constraint:** Behavior-preserving. Write the behavior tests (Task 3/4/5 step 1) *before* touching the service. Never edit `.swiftlint-baseline.yml`.

---

### Task 1: `DateKey` — Int32 `yyyymmdd` conversion

**Files:**
- Create: `Shared/DateKey.swift`
- Test: `MoolahTests/Shared/DateKeyTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Shared/DateKeyTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("DateKey")
struct DateKeyTests {
  @Test("iso string round-trips through Int32 yyyymmdd")
  func roundTrip() {
    #expect(DateKey.from(isoString: "2024-01-15") == 20_240_115)
    #expect(DateKey.from(isoString: "1999-12-31") == 19_991_231)
    #expect(DateKey.isoString(20_240_115) == "2024-01-15")
    #expect(DateKey.isoString(19_991_231) == "1999-12-31")
  }

  @Test("malformed iso string returns nil")
  func malformed() {
    #expect(DateKey.from(isoString: "not-a-date") == nil)
    #expect(DateKey.from(isoString: "2024-13") == nil)
    #expect(DateKey.from(isoString: "") == nil)
  }

  @Test("yyyymmdd integer order equals chronological order")
  func ordering() {
    let a = DateKey.from(isoString: "2023-12-31")!
    let b = DateKey.from(isoString: "2024-01-01")!
    #expect(a < b)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac DateKeyTests 2>&1 | tee .agent-tmp/b1.txt`
Expected: FAIL — `cannot find 'DateKey' in scope`.

- [ ] **Step 3: Create `Shared/DateKey.swift`**

```swift
import Foundation

/// Compact comparable date key: a `yyyymmdd` `Int32` (e.g. `2024-01-15`
/// → `20240115`). Integer ordering equals chronological ordering, so a
/// binary search over `Int32` keys is correct. Used by the price/rate
/// caches instead of `"YYYY-MM-DD"` `String` keys: ~12 bytes smaller per
/// entry and integer-fast comparisons.
///
/// Conversion goes through the existing ISO `"YYYY-MM-DD"` string the
/// services already compute (`ISO8601DateFormatter` `.withFullDate`,
/// UTC), so day bucketing is identical to the previous behaviour — no
/// timezone/calendar re-derivation.
enum DateKey {
  /// Parses `"YYYY-MM-DD"` into `yyyymmdd`. Returns `nil` for any string
  /// that is not exactly three `-`-separated integer fields with a
  /// 1...12 month and 1...31 day.
  static func from(isoString: String) -> Int32? {
    let parts = isoString.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
      let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
      year > 0, (1...12).contains(month), (1...31).contains(day)
    else { return nil }
    return Int32(year * 10_000 + month * 100 + day)
  }

  /// Formats `yyyymmdd` back into a zero-padded `"YYYY-MM-DD"` string.
  static func isoString(_ key: Int32) -> String {
    let v = Int(key)
    let year = v / 10_000
    let month = (v / 100) % 100
    let day = v % 100
    return String(format: "%04d-%02d-%02d", year, month, day)
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac DateKeyTests 2>&1 | tee .agent-tmp/b1.txt`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git -C "$PWD" add Shared/DateKey.swift MoolahTests/Shared/DateKeyTests.swift
git -C "$PWD" commit -m "feat(cache): add DateKey Int32 yyyymmdd conversion helper"
```

---

### Task 2: `SortedDateSeries<Value>` generic store

**Files:**
- Create: `Shared/SortedDateSeries.swift`
- Test: `MoolahTests/Shared/SortedDateSeriesTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Shared/SortedDateSeriesTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("SortedDateSeries")
struct SortedDateSeriesTests {
  @Test("exact returns the value only for an exact key match")
  func exact() {
    var s = SortedDateSeries<Int>()
    s.upsert(20_240_101, 1)
    s.upsert(20_240_103, 3)
    #expect(s.exact(20_240_101) == 1)
    #expect(s.exact(20_240_103) == 3)
    #expect(s.exact(20_240_102) == nil)
  }

  @Test("floor returns the newest entry on or before the key")
  func floor() {
    var s = SortedDateSeries<Int>()
    s.upsert(20_240_101, 1)
    s.upsert(20_240_105, 5)
    s.upsert(20_240_110, 10)
    #expect(s.floor(20_240_100) == nil)         // before first
    #expect(s.floor(20_240_101) == 1)           // exact
    #expect(s.floor(20_240_107) == 5)           // gap → prior
    #expect(s.floor(20_240_999) == 10)          // after last → last
  }

  @Test("upsert keeps entries sorted and replaces duplicates")
  func upsertReplaces() {
    var s = SortedDateSeries<Int>()
    s.upsert(20_240_103, 3)
    s.upsert(20_240_101, 1)
    s.upsert(20_240_103, 33)  // replace
    #expect(s.sortedKeys == [20_240_101, 20_240_103])
    #expect(s.exact(20_240_103) == 33)
  }

  @Test("init(unsorted:) sorts and de-duplicates last-wins")
  func initUnsorted() {
    let s = SortedDateSeries<Int>(unsorted: [
      (20_240_103, 3), (20_240_101, 1), (20_240_103, 33),
    ])
    #expect(s.sortedKeys == [20_240_101, 20_240_103])
    #expect(s.exact(20_240_103) == 33)
  }

  @Test("first/last/isEmpty")
  func bounds() {
    var s = SortedDateSeries<Int>()
    #expect(s.isEmpty)
    s.upsert(20_240_105, 5)
    s.upsert(20_240_101, 1)
    #expect(s.first?.key == 20_240_101)
    #expect(s.last?.key == 20_240_105)
    #expect(!s.isEmpty)
  }

  @Test("plan-pin: floor does not scan linearly")
  func floorIsLogarithmic() {
    var s = SortedDateSeries<Int>()
    for d in 0..<4_000 { s.upsert(Int32(20_000_000 + d), d) }
    SortedDateSeries<Int>.probeCount = 0
    // 1,000 mixed queries (gaps + exacts) over a 4,000-entry series.
    for q in 0..<1_000 { _ = s.floor(Int32(20_000_000 + q * 4)) }
    // Linear-scan-after-sort would be >> 1_000 * 4_000 probes. A binary
    // search is ~1_000 * ceil(log2(4_000)) ≈ 12_000. Cap generously.
    #expect(SortedDateSeries<Int>.probeCount < 40_000)
  }

  @Test("Codable round-trips")
  func codable() throws {
    var s = SortedDateSeries<Int>()
    s.upsert(20_240_101, 1)
    s.upsert(20_240_103, 3)
    let data = try JSONEncoder().encode(s)
    let back = try JSONDecoder().decode(SortedDateSeries<Int>.self, from: data)
    #expect(back == s)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac SortedDateSeriesTests 2>&1 | tee .agent-tmp/b2.txt`
Expected: FAIL — `cannot find 'SortedDateSeries' in scope`.

- [ ] **Step 3: Create `Shared/SortedDateSeries.swift`**

```swift
import Foundation

/// A date-sorted contiguous store keyed by `DateKey` (`Int32` yyyymmdd).
/// Replaces the `[String: Value]` price/rate caches: O(log n) `exact`
/// and `floor` (the prior-trading-day fallback), strictly less RAM than
/// `Dictionary` (no hash slack, no duplicate key storage, no separate
/// sorted index), and a `Codable` shape that loads pre-sorted from an
/// `ORDER BY date` query.
///
/// Entries are kept sorted ascending by `key` at all times. `upsert`
/// replaces an existing same-key value (last-wins), matching the old
/// `dict[date] = value` overwrite semantics.
struct SortedDateSeries<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
  struct Entry: Codable, Sendable, Equatable {
    var key: Int32
    var value: Value
  }

  private(set) var entries: [Entry]

  /// Test-only probe counter incremented once per binary-search step in
  /// `exact` / `floor`. Lets the plan-pinning test assert logarithmic
  /// behaviour. Not used in production logic.
  nonisolated(unsafe) static var probeCount: Int = 0

  init() { self.entries = [] }

  /// Precondition: `entries` is already sorted ascending by key with no
  /// duplicate keys. Used by `loadCache` after an `ORDER BY date` fetch.
  init(sortedEntries: [Entry]) { self.entries = sortedEntries }

  /// Sorts and de-duplicates (last value wins for a repeated key).
  init(unsorted pairs: [(Int32, Value)]) {
    var map: [Int32: Value] = [:]
    for (k, v) in pairs { map[k] = v }
    self.entries = map.keys.sorted().map { Entry(key: $0, value: map[$0]!) }
  }

  var isEmpty: Bool { entries.isEmpty }
  var first: Entry? { entries.first }
  var last: Entry? { entries.last }
  var sortedKeys: [Int32] { entries.map(\.key) }

  /// Index of an exact key match, or `nil`. O(log n).
  private func index(of key: Int32) -> Int? {
    var lo = 0
    var hi = entries.count - 1
    while lo <= hi {
      Self.probeCount += 1
      let mid = (lo + hi) / 2
      let k = entries[mid].key
      if k == key { return mid }
      if k < key { lo = mid + 1 } else { hi = mid - 1 }
    }
    return nil
  }

  /// Index of the newest entry with `key <= target`, or `nil` when the
  /// target precedes every entry. O(log n).
  private func floorIndex(_ target: Int32) -> Int? {
    var lo = 0
    var hi = entries.count - 1
    var result: Int?
    while lo <= hi {
      Self.probeCount += 1
      let mid = (lo + hi) / 2
      if entries[mid].key <= target {
        result = mid
        lo = mid + 1
      } else {
        hi = mid - 1
      }
    }
    return result
  }

  /// Value for an exact key match, else `nil`.
  func exact(_ key: Int32) -> Value? {
    index(of: key).map { entries[$0].value }
  }

  /// Value of the newest entry on or before `key` (the prior-trading-day
  /// fallback), else `nil`.
  func floor(_ key: Int32) -> Value? {
    floorIndex(key).map { entries[$0].value }
  }

  /// Key of the newest entry on or before `target`, else `nil`.
  func floorKey(_ target: Int32) -> Int32? {
    floorIndex(target).map { entries[$0].key }
  }

  /// Inserts `value` at `key`, or replaces the existing same-key value.
  /// Keeps the array sorted. O(log n) search + O(n) shift on insert.
  mutating func upsert(_ key: Int32, _ value: Value) {
    var lo = 0
    var hi = entries.count - 1
    while lo <= hi {
      let mid = (lo + hi) / 2
      let k = entries[mid].key
      if k == key {
        entries[mid].value = value
        return
      }
      if k < key { lo = mid + 1 } else { hi = mid - 1 }
    }
    entries.insert(Entry(key: key, value: value), at: lo)
  }
}
```

> `floorKey` is included here (used by the FX fallback in Task 4). `nonisolated(unsafe)` on `probeCount` is acceptable: test-only instrumentation, never read/written by production code, single-actor tests. If `@concurrency-review` objects, gate behind `#if DEBUG` — do not remove the seam (the plan-pinning test depends on it).

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac SortedDateSeriesTests 2>&1 | tee .agent-tmp/b2.txt`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git -C "$PWD" add Shared/SortedDateSeries.swift MoolahTests/Shared/SortedDateSeriesTests.swift
git -C "$PWD" commit -m "feat(cache): add SortedDateSeries<Value> binary-search store"
```

---

### Task 3: Migrate `StockPriceCache` + `StockPriceService`

**Files:**
- Modify: `Domain/Models/StockPriceCache.swift`
- Modify: `Shared/StockPriceService.swift` (`lookupPrice`:192, `fallbackPrice`:196, `prices(ticker:in:)` result loop:122-130, `mergeReturningDelta`:253-288, `loadCache`:312-340)
- Test: `MoolahTests/Shared/StockPriceServiceFallbackTests.swift` (create)

- [ ] **Step 1: Write the behavior-preserving test (must be GREEN against current code)**

Create `MoolahTests/Shared/StockPriceServiceFallbackTests.swift`. This pins the externally observable contract (exact / gap / pre-history / post-latest) so the rewrite cannot drift:

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("StockPriceService fallback semantics")
struct StockPriceServiceFallbackTests {
  /// Client returning a fixed sparse series (trading days only) so the
  /// service must fall back for weekend/gap dates.
  private struct StubClient: StockPriceClient {
    let instrument: Instrument
    let prices: [String: Decimal]
    func fetchDailyPrices(
      ticker: String, from: Date, to: Date
    ) async throws -> StockPriceResponse {
      StockPriceResponse(instrument: instrument, prices: prices)
    }
  }

  private func d(_ iso: String) -> Date {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
    return f.date(from: iso)!
  }

  private func makeService(_ prices: [String: Decimal]) async throws -> StockPriceService {
    let dbQueue = try DatabaseQueue()
    try Schema.migrator.migrate(dbQueue)
    return StockPriceService(
      client: StubClient(instrument: .AUD, prices: prices),
      database: dbQueue,
      now: { self.d("2024-02-01") })
  }

  @Test("exact, gap (prior trading day), and post-latest all resolve")
  func behaviorMatrix() async throws {
    let svc = try await makeService([
      "2024-01-15": 10, "2024-01-16": 11, "2024-01-17": 12,
    ])
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    _ = try await svc.price(ticker: bhp.ticker!, on: d("2024-01-17"))   // seed
    #expect(try await svc.price(ticker: bhp.ticker!, on: d("2024-01-16")) == 11)  // exact
    #expect(try await svc.price(ticker: bhp.ticker!, on: d("2024-01-20")) == 12)  // gap
    #expect(try await svc.price(ticker: bhp.ticker!, on: d("2024-01-31")) == 12)  // post-latest
  }

  @Test("pre-history date has no fallback")
  func preHistory() async throws {
    let svc = try await makeService(["2024-01-15": 10])
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    _ = try await svc.price(ticker: bhp.ticker!, on: d("2024-01-15"))
    await #expect(throws: (any Error).self) {
      _ = try await svc.price(ticker: bhp.ticker!, on: d("2024-01-01"))
    }
  }
}
```

> Before writing, verify against source: `StockPriceClient.fetchDailyPrices` signature + `StockPriceResponse` field names (`Domain/Repositories/StockPriceClient.swift`); the `Schema.migrator` entry point used by sibling `MoolahTests/Shared` GRDB tests; whether an `ISO8601DateFormatter` date helper already exists in `MoolahTests`. Mirror an existing `MoolahTests/Shared` price-service test's harness. Do **not** change production signatures.

- [ ] **Step 2: Run — must PASS against current dictionary code**

Run: `just test-mac StockPriceServiceFallbackTests 2>&1 | tee .agent-tmp/b3.txt`
Expected: PASS. (It pins current behavior; it must be green *before* the rewrite so a regression is detectable. Fix the harness, not production, until green.)

- [ ] **Step 3: Migrate the model**

`Domain/Models/StockPriceCache.swift`:

```swift
struct StockPriceCache: Codable, Sendable, Equatable {
  let ticker: String
  let instrument: Instrument
  var earliestDate: String  // ISO "YYYY-MM-DD" (unchanged — meta bounds)
  var latestDate: String    // ISO "YYYY-MM-DD" (unchanged — meta bounds)
  var prices: SortedDateSeries<Decimal>
}
```

- [ ] **Step 4: Rewrite `lookupPrice` / `fallbackPrice` / range loop**

Replace `lookupPrice` (192-194) and `fallbackPrice` (196-203):

```swift
  private func lookupPrice(ticker: String, dateString: String) -> Decimal? {
    guard let key = DateKey.from(isoString: dateString) else { return nil }
    return caches[ticker]?.prices.exact(key)
  }

  private func fallbackPrice(ticker: String, dateString: String) -> Decimal? {
    guard let key = DateKey.from(isoString: dateString),
      let cache = caches[ticker]
    else { return nil }
    return cache.prices.floor(key)
  }
```

`prices(ticker:in:)` result-series loop (122-130):

```swift
    for date in dates {
      let dateString = dateFormatter.string(from: date)
      if let key = DateKey.from(isoString: dateString),
        let price = caches[ticker]?.prices.exact(key)
      {
        lastKnownPrice = price
        results.append((date, price))
      } else if let fallback = lastKnownPrice {
        results.append((date, fallback))
      }
    }
```

- [ ] **Step 5: Rewrite `mergeReturningDelta` (253-288)**

Delta-record + meta-bounds logic unchanged (records still take ISO `String` dates); only the in-memory write switches to `exact`/`upsert`:

```swift
  private func mergeReturningDelta(
    ticker: String, instrument: Instrument, newPrices: [String: Decimal]
  ) -> [StockPriceRecord] {
    guard !newPrices.isEmpty else { return [] }
    let sortedDates = newPrices.keys.sorted()
    guard let earliest = sortedDates.first, let latest = sortedDates.last else { return [] }

    var deltaRecords: [StockPriceRecord] = []

    if var existing = caches[ticker] {
      for (dateKey, price) in newPrices {
        guard let key = DateKey.from(isoString: dateKey) else { continue }
        if existing.prices.exact(key) != price {
          deltaRecords.append(priceRecord(ticker: ticker, date: dateKey, price: price))
          existing.prices.upsert(key, price)
        }
      }
      if earliest < existing.earliestDate { existing.earliestDate = earliest }
      if latest > existing.latestDate { existing.latestDate = latest }
      caches[ticker] = existing
    } else {
      var series = SortedDateSeries<Decimal>()
      for (dateKey, price) in newPrices {
        guard let key = DateKey.from(isoString: dateKey) else { continue }
        series.upsert(key, price)
        deltaRecords.append(priceRecord(ticker: ticker, date: dateKey, price: price))
      }
      caches[ticker] = StockPriceCache(
        ticker: ticker, instrument: instrument,
        earliestDate: earliest, latestDate: latest, prices: series)
    }

    return deltaRecords
  }
```

- [ ] **Step 6: Rewrite the persistence decode in `loadCache` (312-340)**

```swift
      let priceRecords =
        try StockPriceRecord
        .filter(StockPriceRecord.Columns.ticker == ticker)
        .order(StockPriceRecord.Columns.date)
        .fetchAll(database)
      var entries: [SortedDateSeries<Decimal>.Entry] = []
      entries.reserveCapacity(priceRecords.count)
      for record in priceRecords {
        guard let key = DateKey.from(isoString: record.date) else { continue }
        let value = Decimal(string: String(record.price)) ?? Decimal(record.price)
        entries.append(.init(key: key, value: value))
      }
      return StockPriceCache(
        ticker: ticker,
        instrument: Instrument.fiat(code: metaRecord.instrumentId),
        earliestDate: metaRecord.earliestDate,
        latestDate: metaRecord.latestDate,
        prices: SortedDateSeries(sortedEntries: entries)
      )
```

> `.order(date)` guarantees ascending so `init(sortedEntries:)`'s precondition holds. `priceRecord`, `persistDelta`, the GRDB `StockPriceRecord`/`StockTickerMetaRecord` shapes, and the on-disk schema are **unchanged**.

- [ ] **Step 7: Build + behavior test stays GREEN**

Run: `just build-mac 2>&1 | tail -5 && just test-mac StockPriceServiceFallbackTests 2>&1 | tee .agent-tmp/b3.txt`
Expected: build succeeds; `StockPriceServiceFallbackTests` still PASS. Also run any pre-existing `StockPriceServiceTests`; if none, run `just test-mac FullConversionServiceTests PositionsHistoryBuilderTests`.

- [ ] **Step 8: Commit**

```bash
git -C "$PWD" add Domain/Models/StockPriceCache.swift Shared/StockPriceService.swift MoolahTests/Shared/StockPriceServiceFallbackTests.swift
git -C "$PWD" commit -m "perf(stock-cache): sorted-array SortedDateSeries; O(log n) fallback"
```

---

### Task 4: Migrate `ExchangeRateCache` + `ExchangeRateService`

**Files:**
- Modify: `Domain/Models/ExchangeRateCache.swift`
- Modify: `Shared/ExchangeRateService.swift` (`lookupRate`:223, `fallbackRate`:227, `rates(...)` loop:196-204, `mergeReturningDelta`:285-324)
- Modify: `Shared/ExchangeRateService+Persistence.swift` (`loadCache` decode)
- Test: `MoolahTests/Shared/ExchangeRateServiceFallbackTests.swift` (create)

The FX cache is date → (quote → rate): `SortedDateSeries<[String: Decimal]>` (each entry is one day's quote map).

- [ ] **Step 1: Write the behavior-preserving test (GREEN against current code)**

Create `MoolahTests/Shared/ExchangeRateServiceFallbackTests.swift`:

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ExchangeRateService fallback semantics")
struct ExchangeRateServiceFallbackTests {
  private struct StubClient: ExchangeRateClient {
    let rates: [String: [String: Decimal]]
    func fetchRates(
      base: String, from: Date, to: Date
    ) async throws -> [String: [String: Decimal]] { rates }
  }

  private func d(_ iso: String) -> Date {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
    return f.date(from: iso)!
  }

  private func makeService(_ rates: [String: [String: Decimal]]) async throws
    -> ExchangeRateService
  {
    let dbQueue = try DatabaseQueue()
    try Schema.migrator.migrate(dbQueue)
    return ExchangeRateService(
      client: StubClient(rates: rates), database: dbQueue,
      now: { self.d("2024-02-01") })
  }

  @Test("exact / gap / post-latest match prior-implementation semantics")
  func behaviorMatrix() async throws {
    let usd = Instrument.fiat(code: "USD")
    let aud = Instrument.fiat(code: "AUD")
    let svc = try await makeService([
      "2024-01-15": ["AUD": 1.50], "2024-01-16": ["AUD": 1.51],
      "2024-01-17": ["AUD": 1.52],
    ])
    _ = try await svc.rate(from: usd, to: aud, on: d("2024-01-17"))
    #expect(try await svc.rate(from: usd, to: aud, on: d("2024-01-16")) == 1.51)
    #expect(try await svc.rate(from: usd, to: aud, on: d("2024-01-20")) == 1.52)
    #expect(try await svc.rate(from: usd, to: aud, on: d("2024-01-31")) == 1.52)
  }

  @Test("identity rate is 1 and pre-history throws")
  func identityAndPreHistory() async throws {
    let usd = Instrument.fiat(code: "USD")
    let aud = Instrument.fiat(code: "AUD")
    let svc = try await makeService(["2024-01-15": ["AUD": 1.50]])
    #expect(try await svc.rate(from: usd, to: usd, on: d("2024-01-15")) == 1)
    _ = try await svc.rate(from: usd, to: aud, on: d("2024-01-15"))
    await #expect(throws: (any Error).self) {
      _ = try await svc.rate(from: usd, to: aud, on: d("2024-01-01"))
    }
  }
}
```

> Verify `ExchangeRateClient.fetchRates` signature + `Schema.migrator` entry point against existing `MoolahTests/Shared` FX tests; mirror their harness.

- [ ] **Step 2: Run — must PASS against current code**

Run: `just test-mac ExchangeRateServiceFallbackTests 2>&1 | tee .agent-tmp/b4.txt`
Expected: PASS (pins existing behavior).

- [ ] **Step 3: Migrate the model**

`Domain/Models/ExchangeRateCache.swift`:

```swift
struct ExchangeRateCache: Codable, Sendable, Equatable {
  let base: String
  var earliestDate: String  // ISO "YYYY-MM-DD" (unchanged — meta bounds)
  var latestDate: String    // ISO "YYYY-MM-DD" (unchanged — meta bounds)
  var rates: SortedDateSeries<[String: Decimal]>
}
```

- [ ] **Step 4: Rewrite `lookupRate` / `fallbackRate` / range loop**

`lookupRate` (223-225) and `fallbackRate` (227-236). The original `fallbackRate` scans the newest day ≤ target that actually carries `quote` (a day map may exist without that quote), so step day-by-day using `floorKey`:

```swift
  private func lookupRate(base: String, quote: String, dateString: String) -> Decimal? {
    guard let key = DateKey.from(isoString: dateString) else { return nil }
    return caches[base]?.rates.exact(key)?[quote]
  }

  private func fallbackRate(base: String, quote: String, dateString: String) -> Decimal? {
    guard let key = DateKey.from(isoString: dateString),
      let cache = caches[base]
    else { return nil }
    var probe = key
    while let dayKey = cache.rates.floorKey(probe) {
      if let rate = cache.rates.exact(dayKey)?[quote] { return rate }
      probe = dayKey - 1
    }
    return nil
  }
```

`rates(from:to:in:)` result loop (196-204):

```swift
    for date in dates {
      let dateString = dateFormatter.string(from: date)
      if let key = DateKey.from(isoString: dateString),
        let rate = caches[base]?.rates.exact(key)?[quote]
      {
        lastKnownRate = rate
        results.append((date, rate))
      } else if let fallback = lastKnownRate {
        results.append((date, fallback))
      }
    }
```

- [ ] **Step 5: Rewrite `mergeReturningDelta` (285-324)**

Per-(date,quote) delta unchanged; whole-day replace becomes `upsert` of the day map (mirrors original `existing.rates[dateKey] = dayRates`):

```swift
  private func mergeReturningDelta(
    base: String, newRates: [String: [String: Decimal]]
  ) -> [ExchangeRateRecord] {
    guard !newRates.isEmpty else { return [] }
    let sortedDates = newRates.keys.sorted()
    guard let earliest = sortedDates.first, let latest = sortedDates.last else { return [] }

    var deltaRecords: [ExchangeRateRecord] = []

    if var existing = caches[base] {
      for (dateKey, dayRates) in newRates {
        guard let key = DateKey.from(isoString: dateKey) else { continue }
        let existingDayRates = existing.rates.exact(key) ?? [:]
        for (quote, rate) in dayRates where existingDayRates[quote] != rate {
          deltaRecords.append(rateRecord(base: base, quote: quote, date: dateKey, rate: rate))
        }
        existing.rates.upsert(key, dayRates)
      }
      if earliest < existing.earliestDate { existing.earliestDate = earliest }
      if latest > existing.latestDate { existing.latestDate = latest }
      caches[base] = existing
    } else {
      var series = SortedDateSeries<[String: Decimal]>()
      for (dateKey, dayRates) in newRates {
        guard let key = DateKey.from(isoString: dateKey) else { continue }
        series.upsert(key, dayRates)
        for (quote, rate) in dayRates {
          deltaRecords.append(rateRecord(base: base, quote: quote, date: dateKey, rate: rate))
        }
      }
      caches[base] = ExchangeRateCache(
        base: base, earliestDate: earliest, latestDate: latest, rates: series)
    }

    return deltaRecords
  }
```

- [ ] **Step 6: Rewrite the persistence decode in `ExchangeRateService+Persistence.swift` `loadCache`**

```swift
      let rateRecords =
        try ExchangeRateRecord
        .filter(ExchangeRateRecord.Columns.base == base)
        .order(ExchangeRateRecord.Columns.date)
        .fetchAll(database)
      var byKey: [Int32: [String: Decimal]] = [:]
      var orderedKeys: [Int32] = []
      for record in rateRecords {
        guard let key = DateKey.from(isoString: record.date) else { continue }
        let value = Decimal(string: String(record.rate)) ?? Decimal(record.rate)
        if byKey[key] == nil { orderedKeys.append(key) }
        byKey[key, default: [:]][record.quote] = value
      }
      let entries = orderedKeys.map {
        SortedDateSeries<[String: Decimal]>.Entry(key: $0, value: byKey[$0]!)
      }
      return ExchangeRateCache(
        base: base,
        earliestDate: metaRecord.earliestDate,
        latestDate: metaRecord.latestDate,
        rates: SortedDateSeries(sortedEntries: entries)
      )
```

> `.order(date)` → ascending records → `orderedKeys` ascending/unique → `init(sortedEntries:)` precondition holds. `rateRecord`, `persistDelta`, GRDB records, schema unchanged.

- [ ] **Step 7: Build + behavior test GREEN**

Run: `just build-mac 2>&1 | tail -5 && just test-mac ExchangeRateServiceFallbackTests SortedDateSeriesTests 2>&1 | tee .agent-tmp/b4.txt`
Expected: build succeeds; both PASS.

- [ ] **Step 8: Commit**

```bash
git -C "$PWD" add Domain/Models/ExchangeRateCache.swift Shared/ExchangeRateService.swift Shared/ExchangeRateService+Persistence.swift MoolahTests/Shared/ExchangeRateServiceFallbackTests.swift
git -C "$PWD" commit -m "perf(fx-cache): sorted-array SortedDateSeries; O(log n) fallback"
```

---

### Task 5: Migrate `CryptoPriceCache` + `CryptoPriceService`

**Files:**
- Modify: `Domain/Models/CryptoPriceCache.swift`
- Modify: `Shared/CryptoPriceService.swift` (`lookupPrice`:341, `fallbackPrice`:345, `prices(...)` loop:283-291)
- Modify: `Shared/CryptoPriceService+Merge.swift` (`mergeReturningDelta`)
- Modify: `Shared/CryptoPriceService+Persistence.swift` (`loadCache` decode)
- Test: `MoolahTests/Shared/CryptoPriceServiceFallbackTests.swift` (create)

- [ ] **Step 1: Read the crypto merge site**

Run: `grep -n "func mergeReturningDelta" Shared/CryptoPriceService*.swift`
Then read that method in full. It mirrors the stock/FX merge (dict iteration, per-date delta, cold-vs-warm branch). The Task 3 Step 5 transformation applies with `tokenId`/`symbol`/`CryptoPriceRecord`/`CryptoPriceCache(tokenId:symbol:earliestDate:latestDate:prices:)` substituted. Note its exact current parameter names/labels before editing.

- [ ] **Step 2: Write the behavior-preserving test (GREEN against current code)**

Create `MoolahTests/Shared/CryptoPriceServiceFallbackTests.swift`, mirroring the stock matrix (exact / gap / post-latest / pre-history) through the crypto API `price(for:mapping:on:)`. Reuse the project's existing crypto test harness: grep `MoolahTests` for a `CryptoPriceService` test and copy its stub-client + `CryptoProviderMapping` + `Schema.migrator` setup verbatim (do not invent a client shape). Four assertions:

```text
exact date            → that day's price
weekend/gap date      → most recent prior cached price
post-latest date      → latest cached price (service caps at yesterday)
pre-history date      → throws (no fallback)
```

- [ ] **Step 3: Run — must PASS against current code**

Run: `just test-mac CryptoPriceServiceFallbackTests 2>&1 | tee .agent-tmp/b5.txt`
Expected: PASS (pins existing behavior).

- [ ] **Step 4: Migrate the model**

`Domain/Models/CryptoPriceCache.swift`:

```swift
struct CryptoPriceCache: Codable, Sendable, Equatable {
  let tokenId: String
  let symbol: String
  var earliestDate: String  // ISO "YYYY-MM-DD" (unchanged — meta bounds)
  var latestDate: String    // ISO "YYYY-MM-DD" (unchanged — meta bounds)
  var prices: SortedDateSeries<Decimal>
}
```

- [ ] **Step 5: Rewrite `lookupPrice` / `fallbackPrice` / range loop**

`lookupPrice` (341-343) and `fallbackPrice` (345-352):

```swift
  private func lookupPrice(tokenId: String, dateString: String) -> Decimal? {
    guard let key = DateKey.from(isoString: dateString) else { return nil }
    return caches[tokenId]?.prices.exact(key)
  }

  private func fallbackPrice(tokenId: String, dateString: String) -> Decimal? {
    guard let key = DateKey.from(isoString: dateString),
      let cache = caches[tokenId]
    else { return nil }
    return cache.prices.floor(key)
  }
```

`prices(for:mapping:in:)` result loop (283-291):

```swift
    for date in dates {
      let dateString = dateFormatter.string(from: date)
      if let key = DateKey.from(isoString: dateString),
        let price = caches[tokenId]?.prices.exact(key)
      {
        lastKnownPrice = price
        results.append((date, price))
      } else if let fallback = lastKnownPrice {
        results.append((date, fallback))
      }
    }
```

- [ ] **Step 6: Rewrite `mergeReturningDelta` in `CryptoPriceService+Merge.swift`**

Port the Task 3 Step 5 (stock) implementation line-for-line into the crypto method's current structure, substituting: `ticker`→`tokenId`, the `instrument` param→`symbol` (whatever the current crypto signature uses — preserve it), `StockPriceRecord`→`CryptoPriceRecord`, `priceRecord(ticker:date:price:)`→ the crypto record builder it currently calls, and the cold-cache initializer →`CryptoPriceCache(tokenId:symbol:earliestDate:latestDate:prices:)`. The control flow (warm branch: `exact` compare then `upsert` + append delta; cold branch: build `SortedDateSeries<Decimal>` via `upsert`, append all deltas; meta-bounds `earliest`/`latest` String compare unchanged) is identical to stock.

- [ ] **Step 7: Rewrite the persistence decode in `CryptoPriceService+Persistence.swift` `loadCache`**

```swift
      let priceRecords =
        try CryptoPriceRecord
        .filter(CryptoPriceRecord.Columns.tokenId == tokenId)
        .order(CryptoPriceRecord.Columns.date)
        .fetchAll(database)
      var entries: [SortedDateSeries<Decimal>.Entry] = []
      entries.reserveCapacity(priceRecords.count)
      for record in priceRecords {
        guard let key = DateKey.from(isoString: record.date) else { continue }
        let value = Decimal(string: String(record.priceUsd)) ?? Decimal(record.priceUsd)
        entries.append(.init(key: key, value: value))
      }
      return CryptoPriceCache(
        tokenId: tokenId,
        symbol: metaRecord.symbol,
        earliestDate: metaRecord.earliestDate,
        latestDate: metaRecord.latestDate,
        prices: SortedDateSeries(sortedEntries: entries)
      )
```

- [ ] **Step 8: Build + behavior test GREEN**

Run: `just build-mac 2>&1 | tail -5 && just test-mac CryptoPriceServiceFallbackTests 2>&1 | tee .agent-tmp/b5.txt`
Expected: build succeeds; suite PASS.

- [ ] **Step 9: Commit**

```bash
git -C "$PWD" add Domain/Models/CryptoPriceCache.swift Shared/CryptoPriceService.swift Shared/CryptoPriceService+Merge.swift Shared/CryptoPriceService+Persistence.swift MoolahTests/Shared/CryptoPriceServiceFallbackTests.swift
git -C "$PWD" commit -m "perf(crypto-cache): sorted-array SortedDateSeries; O(log n) fallback"
```

---

### Task 6: Full verification, format, agent reviews, re-profile

**Files:** none (verification only)

- [ ] **Step 1: Format**

Run: `just format` then `just format-check`
Expected: exits 0. Fix underlying code on any violation — never edit `.swiftlint-baseline.yml`.

- [ ] **Step 2: Warnings**

Run: `just build-mac 2>&1 | grep -i "warning:" | grep -v "#Preview" || echo "no warnings"`
Expected: `no warnings`.

- [ ] **Step 3: Full cache + conversion + investment sweep, both platforms**

Run: `just test DateKeyTests SortedDateSeriesTests StockPriceServiceFallbackTests ExchangeRateServiceFallbackTests CryptoPriceServiceFallbackTests FullConversionServiceTests PositionsHistoryBuilderTests InvestmentStorePositionsInputTests 2>&1 | tee .agent-tmp/b6.txt`
Then: `grep -i 'failed\|error:' .agent-tmp/b6.txt || echo "all green"`
Expected: `all green`.

- [ ] **Step 4: Agent reviews — address every finding (Critical/Important/Minor)**

- `@database-code-review` — `loadCache` decode changes in all three services / persistence files (record mapping, `.order(date)`, String↔Int32 boundary, confirm no schema/PRAGMA change).
- `@concurrency-review` — `SortedDateSeries.probeCount` seam; actors' isolated cache-mutation shape unchanged.
- `@code-review` — `SortedDateSeries`/`DateKey` API design, naming, optional discipline, the three rewrites.

- [ ] **Step 5: Re-profile the original repro (speed verification)**

Via `profile-performance` + `automate-app` (worktree app build): `just run-mac-with-logs`, open "Shares" in "Large Test Profile", capture a stack sample during the chart build. Confirm:
- `StockPriceService.fallbackPrice` / `Sequence.sorted()` no longer dominates.
- `[CurrencyConversion]` / "Conversion factor" log volume during the load is dramatically lower than the spec's ~10k-line baseline.
- The `.all` historic chart populates quickly.
Record the before/after summary for the PR body.

- [ ] **Step 6: Commit review fixes**

```bash
git -C "$PWD" add -A
git -C "$PWD" commit -m "chore(cache): address review findings for sorted-array caches"
```

---

### Task 7: Open PR and queue it

- [ ] **Step 1: Push**

```bash
git -C "$PWD" push origin $(git -C "$PWD" rev-parse --abbrev-ref HEAD):$(git -C "$PWD" rev-parse --abbrev-ref HEAD)
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --title "perf(cache): sorted-array Int32-date price/rate caches (O(log n) fallback)" \
  --body "$(cat <<'EOF'
Replaces the per-call keys.sorted() in StockPriceService /
ExchangeRateService / CryptoPriceService with a shared sorted-array
SortedDateSeries<Value> keyed by Int32 yyyymmdd. O(log n) exact/floor
lookups, less RAM than the dictionaries, on-disk schema unchanged.
Behavior-preserving (table-driven fallback tests pin exact/gap/
pre-history/post-latest for all three services). Approach 2, Plan B.

Spec: plans/2026-05-16-responsive-investment-load-design.md
Plan: plans/2026-05-16-responsive-investment-load-plan-B-caches.md

Before/after profile (Shares / Large Test Profile):
<paste Task 6 Step 5 summary>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Add to merge queue** via the `merge-queue` skill (never merge manually).

---

### Task 8: Move spec + plan to `plans/completed/` when merged

- [ ] **Step 1: After this PR merges, move Plan B**

```bash
git -C "$PWD" mv plans/2026-05-16-responsive-investment-load-plan-B-caches.md plans/completed/
```

- [ ] **Step 2: Move the shared spec (both plans now done)**

Responsiveness-first sequencing means Plan A is merged before Plan B. Move the spec (the last of the two plans moves it):

```bash
git -C "$PWD" mv plans/2026-05-16-responsive-investment-load-design.md plans/completed/
```

If Plan A is somehow not yet merged, leave the spec and note that whichever plan merges last moves it (Plan A's Task 9 has the symmetric guard — exactly one of the two performs the move).

- [ ] **Step 3: Ship the docs move via the normal PR + merge-queue flow**

```bash
git -C "$PWD" commit -m "chore(plans): move responsive investment load plan B + spec to completed"
```

---

## Self-Review

**Spec coverage (Plan B subset):**
- Spec §3 sorted-array caches: `Int32` yyyymmdd, `SortedDateSeries`, `earliestDate`/`latestDate` stay `String`, on-disk schema unchanged, all three services → Tasks 1–5. ✓
- Spec §3 helpers `exactIndex`/`floorIndex`/`merge` → `SortedDateSeries.exact`/`floor`/`floorKey`/`upsert` (Task 2). ✓
- Spec §5 all three `fallback*` behavior-preserving table-driven → Tasks 3/4/5 Step 1 (green-before-rewrite gate). ✓
- Spec §5 plan-pinning perf test → Task 2 `floorIsLogarithmic`. ✓
- Spec "routes through database-code-review" → Task 6 Step 4. ✓
- Spec Verification re-profile → Task 6 Step 5. ✓
- Spec §1/§2 responsiveness → out of scope (Plan A); stated in header. ✓
- User instruction "move plans + spec to completed" → Task 8. ✓

**Placeholder scan:** No "TBD"/"implement later"/"add error handling". Task 5 Steps 1/2/6 reference a named, in-this-plan transformation (Task 3 Step 5) and named source files to read first, with explicit symbol substitutions — not deferred work. Full code is written out per service for the load-bearing differences (model / lookup / fallback / range / persistence); only the structurally-identical crypto `mergeReturningDelta` references the fully-written stock version with explicit substitutions, because the project's "no cosmetic divergence" + DRY conventions make a verbatim re-port the correct instruction.

**Type consistency:** `DateKey.from(isoString:) -> Int32?` / `DateKey.isoString(Int32) -> String` (Task 1) used identically in 3/4/5. `SortedDateSeries<Value>` API (`exact`/`floor`/`floorKey`/`upsert`/`init(sortedEntries:)`/`init(unsorted:)`/`first`/`last`/`isEmpty`/`sortedKeys`/`Entry`/`probeCount`) defined Task 2, consumed with matching signatures in 3/4/5. Models use `SortedDateSeries<Decimal>` (stock/crypto) / `SortedDateSeries<[String: Decimal]>` (FX) consistently across model + service + persistence. `earliestDate`/`latestDate` remain `String` everywhere. ✓
