# Phase 5: Reporting — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Multi-instrument net worth performance, capital gains tracking, profit/loss reporting, and tax integration. The app can show accurate historical net worth across fiat, stocks, and crypto positions, compute capital gains for Australian tax reporting, and display per-instrument P&L.

**Completed:** `4c19ae6` on `feature/multi-instrument` — 697 tests passing on macOS. Note: Task 3 (CloudKitAnalysisRepository wiring) deferred — NetWorthCalculator is ready but needs careful integration.

**Architecture:** Phase 5 builds on Phases 1-4 (Instrument, InstrumentAmount, TransactionLeg, InstrumentConversionService). The analysis layer evolves from single-currency accumulation to multi-instrument position tracking with daily price conversion. Capital gains use FIFO lot tracking on sell legs. Tax integration feeds computed capital gains into TaxYearAdjustments.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, CloudKit, Swift Testing

**Key files to read before starting:**
- `plans/2026-04-12-multi-instrument-design.md` — the multi-instrument design this phase builds on
- `plans/2026-04-11-australian-tax-reporting-design.md` — tax reporting design consuming capital gains
- `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift` — current analysis implementation
- `Domain/Repositories/AnalysisRepository.swift` — protocol to extend
- `Shared/ExchangeRateService.swift`, `Shared/StockPriceService.swift`, `Shared/CryptoPriceService.swift` — price services with batch range APIs and local caches
- `CLAUDE.md` (build/test instructions, architecture constraints), `CONCURRENCY_GUIDE.md`

**Dependencies:** Phases 1-4 must be complete. The `InstrumentConversionService`, `TransactionLeg`, `Position`, and `Instrument` types must exist and be working.

---

## File Structure

### New Files
- `Domain/Models/CostBasisLot.swift` — FIFO lot for cost basis tracking
- `Domain/Models/CapitalGainEvent.swift` — realized gain/loss from a sell leg
- `Domain/Models/InstrumentProfitLoss.swift` — per-instrument P&L summary
- `Domain/Models/NetWorthPoint.swift` — single data point in the net worth time series
- `Shared/CostBasisEngine.swift` — FIFO lot matching engine (pure, no async)
- `Shared/NetWorthCalculator.swift` — multi-instrument daily net worth computation
- `Features/Reports/ReportingStore.swift` — store for P&L and capital gains views
- `MoolahTests/Shared/CostBasisEngineTests.swift` — FIFO engine tests
- `MoolahTests/Shared/NetWorthCalculatorTests.swift` — net worth computation tests
- `MoolahTests/Features/ReportingStoreTests.swift` — reporting store tests

### Major Modifications
- `Domain/Repositories/AnalysisRepository.swift` — add `fetchNetWorth(dateRange:resolution:)` method
- `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift` — implement multi-instrument net worth
- `Features/Analysis/AnalysisStore.swift` — wire new net worth computation into daily balances
- `plans/2026-04-11-australian-tax-reporting-design.md` — update capital gains section (no longer "summary import only")

---

## Task 1: Performance Spike — Multi-Instrument Net Worth

This is an **investigation task**. The goal is to measure actual performance with realistic data volumes and determine the right approach, not to commit to an architecture upfront.

**Context:** The current `CloudKitAnalysisRepository.computeDailyBalances` accumulates single-currency deltas. Post-Phase 4, net worth requires converting every non-profile-currency position to profile currency for each day in the date range. For 20 years of daily data with, say, 5 stocks, 3 crypto tokens, and 2 foreign currencies, that is ~7,300 days x 10 instruments = 73,000 price lookups.

**Key insight from existing code:** All three price services (`ExchangeRateService`, `StockPriceService`, `CryptoPriceService`) support batch date-range fetching that populates local in-memory caches. After a single `prices(ticker:in:)` call for a date range, individual date lookups are pure dictionary reads with no async overhead. The question is whether the initial batch fetch + in-memory iteration is fast enough, or whether we need resolution reduction, persistent caching, or lazy evaluation.

### Benchmark Harness

- [ ] **Step 1: Create benchmark test file**

```swift
// MoolahTests/Shared/NetWorthBenchmarkTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("Net Worth Benchmark")
struct NetWorthBenchmarkTests {
  // Helpers to generate synthetic data
  static func makeLegs(
    days: Int,
    instruments: [Instrument],
    accountId: UUID
  ) -> [TransactionLeg] {
    let calendar = Calendar(identifier: .gregorian)
    let startDate = calendar.date(byAdding: .year, value: -days / 365, to: Date())!
    var legs: [TransactionLeg] = []

    for dayOffset in 0..<days {
      let date = calendar.date(byAdding: .day, value: dayOffset, to: startDate)!
      // One leg per instrument per week (simulating periodic activity)
      if dayOffset % 7 == 0 {
        for instrument in instruments {
          legs.append(TransactionLeg(
            accountId: accountId,
            instrument: instrument,
            quantity: Decimal(Int.random(in: 1...100)),
            type: .transfer,
            categoryId: nil,
            earmarkId: nil
          ))
        }
      }
    }
    return legs
  }

  @Test func measurePositionAccumulation_20Years_10Instruments() {
    // Pure in-memory position accumulation (no price lookups)
    let accountId = UUID()
    let instruments: [Instrument] = (0..<10).map { i in
      Instrument.fiat(code: "T\(String(format: "%02d", i))")
    }
    let legs = Self.makeLegs(days: 7300, instruments: instruments, accountId: accountId)

    let start = ContinuousClock.now
    var positions: [String: Decimal] = [:]
    for leg in legs {
      positions[leg.instrument.id, default: 0] += leg.quantity
    }
    let elapsed = ContinuousClock.now - start

    // Position accumulation should be < 50ms for 10K+ legs
    #expect(elapsed < .milliseconds(500), "Position accumulation took \(elapsed)")
    #expect(!positions.isEmpty)
  }
}
```

- [ ] **Step 2: Run benchmark and record baseline**

```bash
just test 2>&1 | tee .agent-tmp/bench-baseline.txt
grep -A5 'measurePosition' .agent-tmp/bench-baseline.txt
```

Record the elapsed time. This establishes the cost of pure in-memory iteration without any price lookups.

### Measure Batch Price Fetch + Conversion

- [ ] **Step 3: Add benchmark for batch price lookup simulation**

Add a test that simulates the full pipeline: accumulate positions per day, then for each day with a position change, convert all non-profile-currency positions to profile currency using pre-populated price maps.

```swift
@Test func measureDailyConversion_5Years_5Instruments() {
  // Simulate the conversion step using in-memory price maps (no network)
  let days = 1825 // 5 years
  let instrumentCount = 5
  let calendar = Calendar(identifier: .gregorian)
  let startDate = calendar.date(byAdding: .day, value: -days, to: Date())!

  // Pre-build price maps (simulating what batch fetch would produce)
  var priceMaps: [String: [String: Decimal]] = [:]
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withFullDate]

  for i in 0..<instrumentCount {
    let id = "INST\(i)"
    var prices: [String: Decimal] = [:]
    for d in 0..<days {
      let date = calendar.date(byAdding: .day, value: d, to: startDate)!
      let dateStr = formatter.string(from: date)
      prices[dateStr] = Decimal(Double.random(in: 10...1000))
    }
    priceMaps[id] = prices
  }

  // Simulate daily conversion
  let start = ContinuousClock.now
  var dailyNetWorth: [(date: Date, value: Decimal)] = []
  var positions: [String: Decimal] = [:]

  for d in 0..<days {
    let date = calendar.date(byAdding: .day, value: d, to: startDate)!
    let dateStr = formatter.string(from: date)

    // Simulate some position changes
    if d % 7 == 0 {
      for i in 0..<instrumentCount {
        positions["INST\(i)", default: 0] += Decimal(10)
      }
    }

    // Convert all positions to profile currency
    var total: Decimal = 0
    for (instrumentId, qty) in positions {
      if let price = priceMaps[instrumentId]?[dateStr] {
        total += qty * price
      }
    }
    dailyNetWorth.append((date, total))
  }
  let elapsed = ContinuousClock.now - start

  // Full daily conversion over 5 years should be < 1 second in-memory
  #expect(elapsed < .seconds(2), "Daily conversion took \(elapsed)")
  #expect(dailyNetWorth.count == days)
}
```

- [ ] **Step 4: Run and record**

```bash
just test 2>&1 | tee .agent-tmp/bench-conversion.txt
grep -A5 'measureDailyConversion' .agent-tmp/bench-conversion.txt
```

### Decision Point

- [ ] **Step 5: Evaluate results and choose approach**

Based on benchmark results, choose ONE of:

**Option A: Direct computation (if < 2s for 20 years x 10 instruments)**
- Batch-fetch all price ranges upfront via existing service APIs
- Iterate days in-memory, multiply positions by cached prices
- No new caching layer needed — the price services already cache to disk
- This is the simplest approach and should be tried first

**Option B: Resolution reduction (if Option A is 2-10s)**
- Daily resolution for ranges < 1 year
- Weekly for 1-5 years
- Monthly for 5+ years
- Sampling logic in `NetWorthCalculator` — pick representative days, skip the rest
- Still uses batch-fetched prices, just evaluates fewer days

**Option C: Persistent daily cache (if Option A is > 10s or batch fetch is the bottleneck)**
- SwiftData entity: `DailyNetWorthCache(date, profileCurrencyTotal)`
- Invalidated when transactions change (flag on TransactionRepository mutation)
- Incrementally updated: only recompute from the earliest changed date forward
- Most complex — only pursue if measurements demand it

**Document the decision** in a comment at the top of `NetWorthCalculator.swift` with measured numbers.

- [ ] **Step 6: Clean up benchmark temp files**

```bash
rm .agent-tmp/bench-baseline.txt .agent-tmp/bench-conversion.txt
```

Delete `MoolahTests/Shared/NetWorthBenchmarkTests.swift` if the benchmarks are no longer needed as ongoing tests. If they serve as regression guards, keep them.

---

## Task 2: NetWorthCalculator

Implements the chosen approach from Task 1. The code below assumes Option A (direct computation) since the price caches make in-memory lookups fast. If benchmarks dictate otherwise, adapt accordingly.

**Files:**
- Create: `Shared/NetWorthCalculator.swift`
- Create: `MoolahTests/Shared/NetWorthCalculatorTests.swift`
- Create: `Domain/Models/NetWorthPoint.swift`

- [ ] **Step 1: Write failing tests**

```swift
// MoolahTests/Shared/NetWorthCalculatorTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("NetWorthCalculator")
struct NetWorthCalculatorTests {
  let profileCurrency = Instrument.fiat(code: "AUD")
  let usd = Instrument.fiat(code: "USD")

  @Test func singleCurrencyMatchingProfile_noPriceLookupsNeeded() async throws {
    // All positions in profile currency — net worth equals position sum
    let legs = [
      makeLeg(accountId: UUID(), instrument: profileCurrency, quantity: 1000, date: day(0)),
      makeLeg(accountId: UUID(), instrument: profileCurrency, quantity: 500, date: day(1)),
    ]
    let calculator = NetWorthCalculator(
      profileCurrency: profileCurrency,
      conversionService: FixedConversionService()
    )
    let points = try await calculator.compute(
      legs: legs,
      dateRange: day(0)...day(1)
    )
    #expect(points.count == 2)
    #expect(points.last?.value == InstrumentAmount(quantity: 1500, instrument: profileCurrency))
  }

  @Test func multiCurrency_convertsToProfileCurrency() async throws {
    let accountId = UUID()
    let legs = [
      makeLeg(accountId: accountId, instrument: usd, quantity: 100, date: day(0)),
    ]
    // Fixed rate: 1 USD = 1.5 AUD
    let service = FixedConversionService(rates: ["USD": Decimal(string: "1.5")!])
    let calculator = NetWorthCalculator(
      profileCurrency: profileCurrency,
      conversionService: service
    )
    let points = try await calculator.compute(
      legs: legs,
      dateRange: day(0)...day(0)
    )
    #expect(points.count == 1)
    #expect(points[0].value == InstrumentAmount(quantity: 150, instrument: profileCurrency))
  }

  @Test func emptyLegs_returnsZeroPoints() async throws {
    let calculator = NetWorthCalculator(
      profileCurrency: profileCurrency,
      conversionService: FixedConversionService()
    )
    let points = try await calculator.compute(legs: [], dateRange: day(0)...day(5))
    #expect(points.isEmpty)
  }

  // MARK: - Helpers

  private func day(_ offset: Int) -> Date {
    Calendar(identifier: .gregorian).date(
      byAdding: .day, value: offset,
      to: Calendar(identifier: .gregorian).startOfDay(for: Date())
    )!
  }

  private func makeLeg(
    accountId: UUID, instrument: Instrument, quantity: Decimal, date: Date
  ) -> DatedLeg {
    DatedLeg(
      leg: TransactionLeg(
        accountId: accountId,
        instrument: instrument,
        quantity: quantity,
        type: .income,
        categoryId: nil,
        earmarkId: nil
      ),
      date: date
    )
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
just test 2>&1 | tee .agent-tmp/test-nwcalc.txt
grep -i 'failed\|error:' .agent-tmp/test-nwcalc.txt
```

- [ ] **Step 3: Implement NetWorthPoint model**

```swift
// Domain/Models/NetWorthPoint.swift
import Foundation

/// A single point in a net worth time series, with all positions converted to profile currency.
struct NetWorthPoint: Sendable, Hashable {
  let date: Date
  let value: InstrumentAmount  // Always in profile currency
}
```

- [ ] **Step 4: Implement DatedLeg helper and NetWorthCalculator**

```swift
// Shared/NetWorthCalculator.swift
import Foundation

/// A transaction leg paired with its transaction date, for time-series computation.
struct DatedLeg: Sendable {
  let leg: TransactionLeg
  let date: Date
}

/// Computes daily net worth across multiple instruments by converting positions to profile currency.
///
/// Performance approach: [DOCUMENT DECISION FROM TASK 1 HERE]
/// Measured: [X]ms for [Y] days x [Z] instruments on [date].
struct NetWorthCalculator: Sendable {
  let profileCurrency: Instrument
  let conversionService: InstrumentConversionService

  /// Compute net worth time series from dated legs over a date range.
  ///
  /// Legs must be sorted by date. Only days where a leg occurs produce a data point.
  /// Each point represents cumulative position value in profile currency as of that date.
  func compute(
    legs: [DatedLeg],
    dateRange: ClosedRange<Date>
  ) async throws -> [NetWorthPoint] {
    guard !legs.isEmpty else { return [] }

    let calendar = Calendar(identifier: .gregorian)
    let sortedLegs = legs
      .filter { dateRange.contains($0.date) }
      .sorted { $0.date < $1.date }
    guard !sortedLegs.isEmpty else { return [] }

    // Group legs by day
    var legsByDay: [(date: Date, legs: [TransactionLeg])] = []
    var currentDay = calendar.startOfDay(for: sortedLegs[0].date)
    var currentDayLegs: [TransactionLeg] = []

    for dated in sortedLegs {
      let day = calendar.startOfDay(for: dated.date)
      if day != currentDay {
        legsByDay.append((currentDay, currentDayLegs))
        currentDay = day
        currentDayLegs = []
      }
      currentDayLegs.append(dated.leg)
    }
    legsByDay.append((currentDay, currentDayLegs))

    // Accumulate positions and convert daily
    var positions: [String: Decimal] = [:]  // instrumentId -> quantity
    var points: [NetWorthPoint] = []

    for (date, dayLegs) in legsByDay {
      for leg in dayLegs {
        positions[leg.instrument.id, default: 0] += leg.quantity
      }

      // Convert all non-zero positions to profile currency
      var totalValue: Decimal = 0
      for (instrumentId, quantity) in positions where quantity != 0 {
        if instrumentId == profileCurrency.id {
          totalValue += quantity
        } else {
          // Look up instrument details — in practice this comes from a registry
          // For now, use the leg's instrument directly (available from the legs we've seen)
          let converted = try await conversionService.convert(
            quantity, from: instrumentForId(instrumentId, in: sortedLegs),
            to: profileCurrency, on: date
          )
          totalValue += converted
        }
      }

      points.append(NetWorthPoint(
        date: date,
        value: InstrumentAmount(quantity: totalValue, instrument: profileCurrency)
      ))
    }

    return points
  }

  private func instrumentForId(_ id: String, in legs: [DatedLeg]) -> Instrument {
    legs.first { $0.leg.instrument.id == id }!.leg.instrument
  }
}
```

- [ ] **Step 5: Implement FixedConversionService test double**

```swift
// MoolahTests/Support/FixedConversionService.swift
import Foundation
@testable import Moolah

/// Test double for InstrumentConversionService. Returns fixed rates for non-profile instruments.
struct FixedConversionService: InstrumentConversionService {
  let rates: [String: Decimal]  // instrumentId -> rate to profile currency

  init(rates: [String: Decimal] = [:]) {
    self.rates = rates
  }

  func convert(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) async throws -> Decimal {
    if from.id == to.id { return quantity }
    guard let rate = rates[from.id] else {
      return quantity  // Default: 1:1
    }
    return quantity * rate
  }
}
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
just test 2>&1 | tee .agent-tmp/test-nwcalc.txt
grep -i 'failed\|error:' .agent-tmp/test-nwcalc.txt
```

- [ ] **Step 7: Clean up and commit**

```bash
rm .agent-tmp/test-nwcalc.txt
```

---

## Task 3: Wire NetWorthCalculator into CloudKitAnalysisRepository

Replace the single-currency net worth accumulation with the multi-instrument `NetWorthCalculator`.

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift`
- Modify: `Domain/Repositories/AnalysisRepository.swift` (if adding new method)
- Add tests to existing analysis repository contract tests

- [ ] **Step 1: Write failing test**

Add a test to the analysis repository contract tests that creates transactions with multiple instruments and verifies the net worth reflects converted values.

```swift
@Test func dailyBalances_multiInstrument_netWorthConvertsToProfileCurrency() async throws {
  // Create account, add a USD income leg and an AUD income leg
  // Verify the daily balance net worth is the sum in profile currency
  // (specific test code depends on Phase 1-4 API shapes)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test 2>&1 | tee .agent-tmp/test-analysis-multi.txt
```

- [ ] **Step 3: Implement multi-instrument net worth in CloudKitAnalysisRepository**

Modify `computeDailyBalances` to:
1. Collect `DatedLeg` values from all transaction legs (not just the single `amount` field).
2. Group instruments by kind and batch-fetch price ranges via the appropriate service.
3. Use `NetWorthCalculator.compute()` to produce `NetWorthPoint` array.
4. Merge results into the existing `DailyBalance` structure (the `netWorth` field).

The `CloudKitAnalysisRepository` needs the `InstrumentConversionService` injected at init time (alongside `modelContainer` and `currency`).

- [ ] **Step 4: Run test to verify it passes**

```bash
just test 2>&1 | tee .agent-tmp/test-analysis-multi.txt
grep -i 'failed\|error:' .agent-tmp/test-analysis-multi.txt
```

- [ ] **Step 5: Clean up and commit**

```bash
rm .agent-tmp/test-analysis-multi.txt
```

---

## Task 4: CostBasisEngine — FIFO Lot Tracking

A pure, synchronous engine that processes buy/sell legs in chronological order and computes cost basis via FIFO.

**Files:**
- Create: `Domain/Models/CostBasisLot.swift`
- Create: `Domain/Models/CapitalGainEvent.swift`
- Create: `Shared/CostBasisEngine.swift`
- Create: `MoolahTests/Shared/CostBasisEngineTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// MoolahTests/Shared/CostBasisEngineTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CostBasisEngine")
struct CostBasisEngineTests {

  let aud = Instrument.fiat(code: "AUD")

  // MARK: - Buy lots

  @Test func singleBuy_createsOneLot() {
    let bhp = Instrument(id: "ASX:BHP", kind: .stock, name: "BHP", decimals: 0,
                          ticker: "BHP.AX", exchange: "ASX", chainId: nil, contractAddress: nil)
    var engine = CostBasisEngine()
    engine.processBuy(instrument: bhp, quantity: 100, costPerUnit: Decimal(42), date: date(0))

    let lots = engine.openLots(for: bhp)
    #expect(lots.count == 1)
    #expect(lots[0].remainingQuantity == 100)
    #expect(lots[0].costPerUnit == 42)
  }

  @Test func multipleBuys_createsMultipleLots() {
    let bhp = stockInstrument("BHP")
    var engine = CostBasisEngine()
    engine.processBuy(instrument: bhp, quantity: 100, costPerUnit: 40, date: date(0))
    engine.processBuy(instrument: bhp, quantity: 50, costPerUnit: 45, date: date(30))

    let lots = engine.openLots(for: bhp)
    #expect(lots.count == 2)
    #expect(lots[0].costPerUnit == 40)  // First lot
    #expect(lots[1].costPerUnit == 45)  // Second lot
  }

  // MARK: - FIFO sells

  @Test func sellAll_fromSingleLot_producesOneGainEvent() {
    let bhp = stockInstrument("BHP")
    var engine = CostBasisEngine()
    engine.processBuy(instrument: bhp, quantity: 100, costPerUnit: 40, date: date(0))

    let events = engine.processSell(
      instrument: bhp, quantity: 100, proceedsPerUnit: 50, date: date(365)
    )

    #expect(events.count == 1)
    #expect(events[0].quantity == 100)
    #expect(events[0].costBasis == 4000)   // 100 * 40
    #expect(events[0].proceeds == 5000)    // 100 * 50
    #expect(events[0].gain == 1000)
    #expect(events[0].holdingDays >= 365)
    #expect(engine.openLots(for: bhp).isEmpty)
  }

  @Test func partialSell_FIFO_consumesFirstLotFirst() {
    let bhp = stockInstrument("BHP")
    var engine = CostBasisEngine()
    engine.processBuy(instrument: bhp, quantity: 100, costPerUnit: 40, date: date(0))
    engine.processBuy(instrument: bhp, quantity: 50, costPerUnit: 45, date: date(30))

    let events = engine.processSell(
      instrument: bhp, quantity: 120, proceedsPerUnit: 50, date: date(365)
    )

    // FIFO: first 100 from lot 1 (cost 40), next 20 from lot 2 (cost 45)
    #expect(events.count == 2)
    #expect(events[0].quantity == 100)
    #expect(events[0].costBasis == 4000)
    #expect(events[1].quantity == 20)
    #expect(events[1].costBasis == 900)  // 20 * 45

    // Remaining: 30 units in lot 2
    let remaining = engine.openLots(for: bhp)
    #expect(remaining.count == 1)
    #expect(remaining[0].remainingQuantity == 30)
    #expect(remaining[0].costPerUnit == 45)
  }

  @Test func sellAtLoss_negativeGain() {
    let bhp = stockInstrument("BHP")
    var engine = CostBasisEngine()
    engine.processBuy(instrument: bhp, quantity: 100, costPerUnit: 50, date: date(0))

    let events = engine.processSell(
      instrument: bhp, quantity: 100, proceedsPerUnit: 30, date: date(180)
    )

    #expect(events.count == 1)
    #expect(events[0].gain == -2000)  // (30 - 50) * 100
    #expect(events[0].holdingDays >= 180)
  }

  @Test func holdingPeriod_underOneYear_shortTerm() {
    let bhp = stockInstrument("BHP")
    var engine = CostBasisEngine()
    engine.processBuy(instrument: bhp, quantity: 10, costPerUnit: 100, date: date(0))

    let events = engine.processSell(
      instrument: bhp, quantity: 10, proceedsPerUnit: 120, date: date(364)
    )

    #expect(events[0].isLongTerm == false)  // < 365 days
  }

  @Test func holdingPeriod_overOneYear_longTerm() {
    let bhp = stockInstrument("BHP")
    var engine = CostBasisEngine()
    engine.processBuy(instrument: bhp, quantity: 10, costPerUnit: 100, date: date(0))

    let events = engine.processSell(
      instrument: bhp, quantity: 10, proceedsPerUnit: 120, date: date(366)
    )

    #expect(events[0].isLongTerm == true)  // > 365 days
  }

  @Test func multipleInstruments_trackedSeparately() {
    let bhp = stockInstrument("BHP")
    let cba = stockInstrument("CBA")
    var engine = CostBasisEngine()
    engine.processBuy(instrument: bhp, quantity: 100, costPerUnit: 40, date: date(0))
    engine.processBuy(instrument: cba, quantity: 50, costPerUnit: 100, date: date(0))

    let bhpEvents = engine.processSell(
      instrument: bhp, quantity: 50, proceedsPerUnit: 50, date: date(365)
    )
    #expect(bhpEvents.count == 1)
    #expect(bhpEvents[0].quantity == 50)

    // CBA lots unaffected
    let cbaLots = engine.openLots(for: cba)
    #expect(cbaLots.count == 1)
    #expect(cbaLots[0].remainingQuantity == 50)
  }

  @Test func sellMoreThanOwned_processesAvailableOnly() {
    let bhp = stockInstrument("BHP")
    var engine = CostBasisEngine()
    engine.processBuy(instrument: bhp, quantity: 50, costPerUnit: 40, date: date(0))

    let events = engine.processSell(
      instrument: bhp, quantity: 100, proceedsPerUnit: 50, date: date(365)
    )

    // Can only sell what we have
    #expect(events.count == 1)
    #expect(events[0].quantity == 50)
    #expect(engine.openLots(for: bhp).isEmpty)
  }

  // MARK: - Helpers

  private func stockInstrument(_ name: String) -> Instrument {
    Instrument(id: "ASX:\(name)", kind: .stock, name: name, decimals: 0,
               ticker: "\(name).AX", exchange: "ASX", chainId: nil, contractAddress: nil)
  }

  private func date(_ daysFromNow: Int) -> Date {
    let base = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2024, month: 1, day: 1))!
    return Calendar(identifier: .gregorian).date(byAdding: .day, value: daysFromNow, to: base)!
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
just test 2>&1 | tee .agent-tmp/test-costbasis.txt
```

- [ ] **Step 3: Implement CostBasisLot model**

```swift
// Domain/Models/CostBasisLot.swift
import Foundation

/// A lot (tax parcel) of an instrument acquired at a specific cost on a specific date.
/// Used by the FIFO cost basis engine to track open positions.
struct CostBasisLot: Sendable, Hashable, Identifiable {
  let id: UUID
  let instrument: Instrument
  let acquiredDate: Date
  let costPerUnit: Decimal       // In the currency the instrument was purchased with
  let originalQuantity: Decimal
  var remainingQuantity: Decimal

  var totalCost: Decimal { originalQuantity * costPerUnit }
  var remainingCost: Decimal { remainingQuantity * costPerUnit }
}
```

- [ ] **Step 4: Implement CapitalGainEvent model**

```swift
// Domain/Models/CapitalGainEvent.swift
import Foundation

/// A realized capital gain or loss from selling (part of) a lot.
struct CapitalGainEvent: Sendable, Hashable {
  let instrument: Instrument
  let sellDate: Date
  let acquiredDate: Date
  let quantity: Decimal
  let costBasis: Decimal          // quantity * costPerUnit from the lot
  let proceeds: Decimal           // quantity * proceedsPerUnit
  let holdingDays: Int

  /// Gain or loss. Positive = gain, negative = loss.
  var gain: Decimal { proceeds - costBasis }

  /// Australian CGT: assets held > 12 months qualify for 50% discount.
  var isLongTerm: Bool { holdingDays > 365 }
}
```

- [ ] **Step 5: Implement CostBasisEngine**

```swift
// Shared/CostBasisEngine.swift
import Foundation

/// Pure synchronous engine for FIFO cost basis tracking.
///
/// Feed buy and sell events in chronological order. The engine maintains open lots
/// per instrument and produces CapitalGainEvent values on sells.
///
/// Not async, no repository dependencies — all data passed in. Highly testable.
struct CostBasisEngine: Sendable {
  /// Open lots grouped by instrument ID, in acquisition order (FIFO).
  private var lots: [String: [CostBasisLot]] = [:]

  /// Record a buy: adds a new lot for the instrument.
  mutating func processBuy(
    instrument: Instrument,
    quantity: Decimal,
    costPerUnit: Decimal,
    date: Date
  ) {
    let lot = CostBasisLot(
      id: UUID(),
      instrument: instrument,
      acquiredDate: date,
      costPerUnit: costPerUnit,
      originalQuantity: quantity,
      remainingQuantity: quantity
    )
    lots[instrument.id, default: []].append(lot)
  }

  /// Record a sell: consume lots in FIFO order, return gain/loss events.
  ///
  /// If sell quantity exceeds available lots, only the available quantity is processed.
  mutating func processSell(
    instrument: Instrument,
    quantity: Decimal,
    proceedsPerUnit: Decimal,
    date: Date
  ) -> [CapitalGainEvent] {
    var remaining = quantity
    var events: [CapitalGainEvent] = []
    let calendar = Calendar(identifier: .gregorian)

    while remaining > 0 {
      guard var openLots = lots[instrument.id], !openLots.isEmpty else { break }

      var lot = openLots[0]
      let consumed = min(remaining, lot.remainingQuantity)

      let holdingDays = calendar.dateComponents(
        [.day], from: lot.acquiredDate, to: date
      ).day ?? 0

      events.append(CapitalGainEvent(
        instrument: instrument,
        sellDate: date,
        acquiredDate: lot.acquiredDate,
        quantity: consumed,
        costBasis: consumed * lot.costPerUnit,
        proceeds: consumed * proceedsPerUnit,
        holdingDays: holdingDays
      ))

      lot.remainingQuantity -= consumed
      remaining -= consumed

      if lot.remainingQuantity <= 0 {
        openLots.removeFirst()
      } else {
        openLots[0] = lot
      }
      lots[instrument.id] = openLots
    }

    return events
  }

  /// Return open (unsold) lots for an instrument, in FIFO order.
  func openLots(for instrument: Instrument) -> [CostBasisLot] {
    lots[instrument.id] ?? []
  }

  /// All open lots across all instruments.
  func allOpenLots() -> [CostBasisLot] {
    lots.values.flatMap { $0 }
  }

  /// All realized gain events (not tracked internally — caller accumulates from processSell returns).
  /// This method is intentionally not provided; the caller collects events as they process legs.
}
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
just test 2>&1 | tee .agent-tmp/test-costbasis.txt
grep -i 'failed\|error:' .agent-tmp/test-costbasis.txt
```

- [ ] **Step 7: Clean up and commit**

```bash
rm .agent-tmp/test-costbasis.txt
```

---

## Task 5: Compute Capital Gains from Transaction Legs

Wire the `CostBasisEngine` to process real transaction legs, identifying buy/sell events from transfer legs in investment accounts.

**Files:**
- Create: `Shared/CapitalGainsCalculator.swift`
- Create: `MoolahTests/Shared/CapitalGainsCalculatorTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// MoolahTests/Shared/CapitalGainsCalculatorTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CapitalGainsCalculator")
struct CapitalGainsCalculatorTests {
  let aud = Instrument.fiat(code: "AUD")

  @Test func stockPurchase_thenSale_producesGainEvent() async throws {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    // Buy: transfer AUD out, BHP in
    let buyLegs = [
      TransactionLeg(accountId: accountId, instrument: aud, quantity: -4000, type: .transfer,
                     categoryId: nil, earmarkId: nil),
      TransactionLeg(accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
                     categoryId: nil, earmarkId: nil),
    ]
    let buyTx = LegTransaction(date: date(0), legs: buyLegs)

    // Sell: BHP out, AUD in
    let sellLegs = [
      TransactionLeg(accountId: accountId, instrument: bhp, quantity: -100, type: .transfer,
                     categoryId: nil, earmarkId: nil),
      TransactionLeg(accountId: accountId, instrument: aud, quantity: 5000, type: .transfer,
                     categoryId: nil, earmarkId: nil),
    ]
    let sellTx = LegTransaction(date: date(400), legs: sellLegs)

    let result = CapitalGainsCalculator.compute(
      transactions: [buyTx, sellTx],
      profileCurrency: aud
    )

    #expect(result.events.count == 1)
    #expect(result.events[0].gain == 1000)       // 5000 - 4000
    #expect(result.events[0].isLongTerm == true)  // 400 days
    #expect(result.totalRealizedGain == 1000)
  }

  @Test func noSales_noGainEvents() async throws {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    let buyLegs = [
      TransactionLeg(accountId: accountId, instrument: aud, quantity: -4000, type: .transfer,
                     categoryId: nil, earmarkId: nil),
      TransactionLeg(accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
                     categoryId: nil, earmarkId: nil),
    ]
    let buyTx = LegTransaction(date: date(0), legs: buyLegs)

    let result = CapitalGainsCalculator.compute(
      transactions: [buyTx],
      profileCurrency: aud
    )

    #expect(result.events.isEmpty)
    #expect(result.openLots.count == 1)
    #expect(result.openLots[0].remainingQuantity == 100)
  }

  @Test func cryptoSwap_tracksGainOnSoldToken() async throws {
    let eth = cryptoInstrument("ETH")
    let uni = cryptoInstrument("UNI")
    let accountId = UUID()

    // Buy ETH with AUD
    let buyTx = LegTransaction(date: date(0), legs: [
      TransactionLeg(accountId: accountId, instrument: aud, quantity: -3000, type: .transfer,
                     categoryId: nil, earmarkId: nil),
      TransactionLeg(accountId: accountId, instrument: eth, quantity: 1, type: .transfer,
                     categoryId: nil, earmarkId: nil),
    ])

    // Swap ETH for UNI (ETH out at AUD equivalent of 4000)
    // The calculator needs the AUD proceeds to calculate gain
    // In a real swap, the conversion service provides the AUD value
    let swapTx = LegTransaction(date: date(200), legs: [
      TransactionLeg(accountId: accountId, instrument: eth, quantity: -1, type: .transfer,
                     categoryId: nil, earmarkId: nil),
      TransactionLeg(accountId: accountId, instrument: uni, quantity: 500, type: .transfer,
                     categoryId: nil, earmarkId: nil),
    ])

    let service = FixedConversionService(rates: ["ETH": 4000, "UNI": 8])
    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, swapTx],
      profileCurrency: aud,
      conversionService: service
    )

    // ETH sold: cost basis 3000, proceeds 4000 (1 ETH at AUD 4000 on swap date)
    #expect(result.events.count == 1)
    #expect(result.events[0].instrument.id == eth.id)
    #expect(result.events[0].gain == 1000)
  }

  @Test func financialYearFilter_onlyIncludesEventsInRange() async throws {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    let buyTx = LegTransaction(date: date(0), legs: [
      TransactionLeg(accountId: accountId, instrument: aud, quantity: -4000, type: .transfer,
                     categoryId: nil, earmarkId: nil),
      TransactionLeg(accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
                     categoryId: nil, earmarkId: nil),
    ])

    let sellTx = LegTransaction(date: date(400), legs: [
      TransactionLeg(accountId: accountId, instrument: bhp, quantity: -100, type: .transfer,
                     categoryId: nil, earmarkId: nil),
      TransactionLeg(accountId: accountId, instrument: aud, quantity: 5000, type: .transfer,
                     categoryId: nil, earmarkId: nil),
    ])

    let allResult = CapitalGainsCalculator.compute(
      transactions: [buyTx, sellTx],
      profileCurrency: aud
    )
    #expect(allResult.events.count == 1)

    let earlyResult = CapitalGainsCalculator.compute(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      sellDateRange: date(0)...date(100)
    )
    // Sale on day 400 is outside the range — no events returned
    // (but the buy is still processed to build lots)
    #expect(earlyResult.events.isEmpty)
  }

  // MARK: - Helpers

  private func stockInstrument(_ name: String) -> Instrument {
    Instrument(id: "ASX:\(name)", kind: .stock, name: name, decimals: 0,
               ticker: "\(name).AX", exchange: "ASX", chainId: nil, contractAddress: nil)
  }

  private func cryptoInstrument(_ symbol: String) -> Instrument {
    Instrument(id: "1:\(symbol.lowercased())", kind: .cryptoToken, name: symbol, decimals: 8,
               ticker: nil, exchange: nil, chainId: 1, contractAddress: nil)
  }

  private func date(_ daysFromBase: Int) -> Date {
    let base = Calendar(identifier: .gregorian).date(
      from: DateComponents(year: 2024, month: 1, day: 1))!
    return Calendar(identifier: .gregorian).date(byAdding: .day, value: daysFromBase, to: base)!
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
just test 2>&1 | tee .agent-tmp/test-capgains-calc.txt
```

- [ ] **Step 3: Implement CapitalGainsCalculator**

```swift
// Shared/CapitalGainsCalculator.swift
import Foundation

/// Input type: a transaction's legs with its date.
struct LegTransaction: Sendable {
  let date: Date
  let legs: [TransactionLeg]
}

/// Result of capital gains computation over a set of transactions.
struct CapitalGainsResult: Sendable {
  let events: [CapitalGainEvent]
  let openLots: [CostBasisLot]

  var totalRealizedGain: Decimal {
    events.reduce(Decimal(0)) { $0 + $1.gain }
  }

  var shortTermGain: Decimal {
    events.filter { !$0.isLongTerm }.reduce(Decimal(0)) { $0 + $1.gain }
  }

  var longTermGain: Decimal {
    events.filter { $0.isLongTerm }.reduce(Decimal(0)) { $0 + $1.gain }
  }
}

/// Processes transaction legs to extract buy/sell events and compute capital gains.
///
/// **Buy detection:** A non-fiat instrument leg with positive quantity, paired with a
/// fiat outflow leg in the same transaction. Cost per unit = fiat amount / quantity.
///
/// **Sell detection:** A non-fiat instrument leg with negative quantity, paired with a
/// fiat inflow leg. Proceeds per unit = fiat amount / quantity.
///
/// **Crypto-to-crypto swaps:** Both legs are non-fiat. Requires conversion service to
/// determine AUD-equivalent proceeds. Use `computeWithConversion` for these cases.
enum CapitalGainsCalculator {

  /// Compute capital gains from fiat-paired trades (no conversion needed).
  static func compute(
    transactions: [LegTransaction],
    profileCurrency: Instrument,
    sellDateRange: ClosedRange<Date>? = nil
  ) -> CapitalGainsResult {
    var engine = CostBasisEngine()
    var allEvents: [CapitalGainEvent] = []

    let sorted = transactions.sorted { $0.date < $1.date }

    for tx in sorted {
      let (buys, sells) = classifyLegs(
        legs: tx.legs, date: tx.date, profileCurrency: profileCurrency
      )

      for buy in buys {
        engine.processBuy(
          instrument: buy.instrument,
          quantity: buy.quantity,
          costPerUnit: buy.costPerUnit,
          date: tx.date
        )
      }

      for sell in sells {
        // Only include sell events within the date range (if specified)
        let inRange = sellDateRange.map { $0.contains(tx.date) } ?? true
        let events = engine.processSell(
          instrument: sell.instrument,
          quantity: sell.quantity,
          proceedsPerUnit: sell.proceedsPerUnit,
          date: tx.date
        )
        if inRange {
          allEvents.append(contentsOf: events)
        }
      }
    }

    return CapitalGainsResult(events: allEvents, openLots: engine.allOpenLots())
  }

  /// Compute capital gains including non-fiat swaps, using conversion service for AUD-equivalent.
  static func computeWithConversion(
    transactions: [LegTransaction],
    profileCurrency: Instrument,
    conversionService: InstrumentConversionService,
    sellDateRange: ClosedRange<Date>? = nil
  ) async throws -> CapitalGainsResult {
    var engine = CostBasisEngine()
    var allEvents: [CapitalGainEvent] = []

    let sorted = transactions.sorted { $0.date < $1.date }

    for tx in sorted {
      let (buys, sells) = try await classifyLegsWithConversion(
        legs: tx.legs, date: tx.date,
        profileCurrency: profileCurrency,
        conversionService: conversionService
      )

      for buy in buys {
        engine.processBuy(
          instrument: buy.instrument,
          quantity: buy.quantity,
          costPerUnit: buy.costPerUnit,
          date: tx.date
        )
      }

      for sell in sells {
        let inRange = sellDateRange.map { $0.contains(tx.date) } ?? true
        let events = engine.processSell(
          instrument: sell.instrument,
          quantity: sell.quantity,
          proceedsPerUnit: sell.proceedsPerUnit,
          date: tx.date
        )
        if inRange {
          allEvents.append(contentsOf: events)
        }
      }
    }

    return CapitalGainsResult(events: allEvents, openLots: engine.allOpenLots())
  }

  // MARK: - Leg classification

  private struct BuyEvent {
    let instrument: Instrument
    let quantity: Decimal
    let costPerUnit: Decimal
  }

  private struct SellEvent {
    let instrument: Instrument
    let quantity: Decimal
    let proceedsPerUnit: Decimal
  }

  /// Classify legs into buy/sell events using fiat legs for cost/proceeds.
  private static func classifyLegs(
    legs: [TransactionLeg],
    date: Date,
    profileCurrency: Instrument
  ) -> (buys: [BuyEvent], sells: [SellEvent]) {
    let fiatLegs = legs.filter { $0.instrument.kind == .fiatCurrency }
    let nonFiatLegs = legs.filter { $0.instrument.kind != .fiatCurrency }

    // Total fiat outflow (negative = money spent) and inflow (positive = money received)
    let fiatOutflow = fiatLegs.filter { $0.quantity < 0 }
      .reduce(Decimal(0)) { $0 + abs($1.quantity) }
    let fiatInflow = fiatLegs.filter { $0.quantity > 0 }
      .reduce(Decimal(0)) { $0 + $1.quantity }

    var buys: [BuyEvent] = []
    var sells: [SellEvent] = []

    for leg in nonFiatLegs {
      if leg.quantity > 0 && fiatOutflow > 0 {
        // Buying: non-fiat inflow paired with fiat outflow
        let costPerUnit = fiatOutflow / leg.quantity
        buys.append(BuyEvent(instrument: leg.instrument, quantity: leg.quantity,
                             costPerUnit: costPerUnit))
      } else if leg.quantity < 0 && fiatInflow > 0 {
        // Selling: non-fiat outflow paired with fiat inflow
        let proceedsPerUnit = fiatInflow / abs(leg.quantity)
        sells.append(SellEvent(instrument: leg.instrument, quantity: abs(leg.quantity),
                               proceedsPerUnit: proceedsPerUnit))
      }
    }

    return (buys, sells)
  }

  /// Classify legs including non-fiat swaps, using conversion for AUD-equivalent value.
  private static func classifyLegsWithConversion(
    legs: [TransactionLeg],
    date: Date,
    profileCurrency: Instrument,
    conversionService: InstrumentConversionService
  ) async throws -> (buys: [BuyEvent], sells: [SellEvent]) {
    // First try fiat-paired classification
    let (fiatBuys, fiatSells) = classifyLegs(
      legs: legs, date: date, profileCurrency: profileCurrency
    )
    if !fiatBuys.isEmpty || !fiatSells.isEmpty {
      return (fiatBuys, fiatSells)
    }

    // Non-fiat swap: both sides are non-fiat
    let nonFiatLegs = legs.filter { $0.instrument.kind != .fiatCurrency }
    guard nonFiatLegs.count >= 2 else { return ([], []) }

    var buys: [BuyEvent] = []
    var sells: [SellEvent] = []

    for leg in nonFiatLegs {
      let profileValue = try await conversionService.convert(
        abs(leg.quantity), from: leg.instrument, to: profileCurrency, on: date
      )
      let valuePerUnit = profileValue / abs(leg.quantity)

      if leg.quantity > 0 {
        buys.append(BuyEvent(instrument: leg.instrument, quantity: leg.quantity,
                             costPerUnit: valuePerUnit))
      } else {
        sells.append(SellEvent(instrument: leg.instrument, quantity: abs(leg.quantity),
                               proceedsPerUnit: valuePerUnit))
      }
    }

    return (buys, sells)
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
just test 2>&1 | tee .agent-tmp/test-capgains-calc.txt
grep -i 'failed\|error:' .agent-tmp/test-capgains-calc.txt
```

- [ ] **Step 5: Clean up and commit**

```bash
rm .agent-tmp/test-capgains-calc.txt
```

---

## Task 6: InstrumentProfitLoss Model and Computation

Per-instrument summary: total invested, current value, unrealized gain/loss, realized gain/loss.

**Files:**
- Create: `Domain/Models/InstrumentProfitLoss.swift`
- Add to: `Shared/CapitalGainsCalculator.swift` (or new `Shared/ProfitLossCalculator.swift`)
- Create: `MoolahTests/Shared/ProfitLossCalculatorTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// MoolahTests/Shared/ProfitLossCalculatorTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("ProfitLossCalculator")
struct ProfitLossCalculatorTests {
  let aud = Instrument.fiat(code: "AUD")

  @Test func singleInstrument_noSales_unrealizedOnly() async throws {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    let buyTx = LegTransaction(date: date(0), legs: [
      TransactionLeg(accountId: accountId, instrument: aud, quantity: -4000, type: .transfer,
                     categoryId: nil, earmarkId: nil),
      TransactionLeg(accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
                     categoryId: nil, earmarkId: nil),
    ])

    // BHP now worth $50/share
    let service = FixedConversionService(rates: ["ASX:BHP": 50])
    let results = try await ProfitLossCalculator.compute(
      transactions: [buyTx],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(365)
    )

    #expect(results.count == 1)
    let bhpPL = results[0]
    #expect(bhpPL.instrument.id == "ASX:BHP")
    #expect(bhpPL.totalInvested == 4000)
    #expect(bhpPL.currentValue == 5000)     // 100 * 50
    #expect(bhpPL.unrealizedGain == 1000)   // 5000 - 4000
    #expect(bhpPL.realizedGain == 0)
    #expect(bhpPL.currentQuantity == 100)
  }

  @Test func partialSale_showsBothRealizedAndUnrealized() async throws {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    let buyTx = LegTransaction(date: date(0), legs: [
      TransactionLeg(accountId: accountId, instrument: aud, quantity: -4000, type: .transfer,
                     categoryId: nil, earmarkId: nil),
      TransactionLeg(accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
                     categoryId: nil, earmarkId: nil),
    ])

    let sellTx = LegTransaction(date: date(200), legs: [
      TransactionLeg(accountId: accountId, instrument: bhp, quantity: -50, type: .transfer,
                     categoryId: nil, earmarkId: nil),
      TransactionLeg(accountId: accountId, instrument: aud, quantity: 3000, type: .transfer,
                     categoryId: nil, earmarkId: nil),
    ])

    // BHP now worth $50/share
    let service = FixedConversionService(rates: ["ASX:BHP": 50])
    let results = try await ProfitLossCalculator.compute(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(365)
    )

    #expect(results.count == 1)
    let bhpPL = results[0]
    #expect(bhpPL.currentQuantity == 50)
    #expect(bhpPL.totalInvested == 4000)       // Total ever invested
    #expect(bhpPL.currentValue == 2500)        // 50 * 50
    #expect(bhpPL.realizedGain == 1000)        // 3000 - (50 * 40)
    // Unrealized: current value of remaining - cost basis of remaining
    // Remaining cost basis: 50 * 40 = 2000. Current value: 2500. Unrealized: 500.
    #expect(bhpPL.unrealizedGain == 500)
  }

  @Test func fullySold_onlyRealizedGain() async throws {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    let buyTx = LegTransaction(date: date(0), legs: [
      TransactionLeg(accountId: accountId, instrument: aud, quantity: -4000, type: .transfer,
                     categoryId: nil, earmarkId: nil),
      TransactionLeg(accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
                     categoryId: nil, earmarkId: nil),
    ])

    let sellTx = LegTransaction(date: date(200), legs: [
      TransactionLeg(accountId: accountId, instrument: bhp, quantity: -100, type: .transfer,
                     categoryId: nil, earmarkId: nil),
      TransactionLeg(accountId: accountId, instrument: aud, quantity: 5000, type: .transfer,
                     categoryId: nil, earmarkId: nil),
    ])

    let service = FixedConversionService(rates: [:])
    let results = try await ProfitLossCalculator.compute(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(365)
    )

    // Fully sold instruments should still appear (realized gain exists)
    #expect(results.count == 1)
    #expect(results[0].currentQuantity == 0)
    #expect(results[0].currentValue == 0)
    #expect(results[0].unrealizedGain == 0)
    #expect(results[0].realizedGain == 1000)
  }

  @Test func fiatOnlyTransactions_excludedFromResults() async throws {
    let accountId = UUID()
    let tx = LegTransaction(date: date(0), legs: [
      TransactionLeg(accountId: accountId, instrument: aud, quantity: -500, type: .expense,
                     categoryId: nil, earmarkId: nil),
    ])

    let service = FixedConversionService(rates: [:])
    let results = try await ProfitLossCalculator.compute(
      transactions: [tx],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(0)
    )
    #expect(results.isEmpty)
  }

  // MARK: - Helpers

  private func stockInstrument(_ name: String) -> Instrument {
    Instrument(id: "ASX:\(name)", kind: .stock, name: name, decimals: 0,
               ticker: "\(name).AX", exchange: "ASX", chainId: nil, contractAddress: nil)
  }

  private func date(_ daysFromBase: Int) -> Date {
    let base = Calendar(identifier: .gregorian).date(
      from: DateComponents(year: 2024, month: 1, day: 1))!
    return Calendar(identifier: .gregorian).date(byAdding: .day, value: daysFromBase, to: base)!
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
just test 2>&1 | tee .agent-tmp/test-pnl.txt
```

- [ ] **Step 3: Implement InstrumentProfitLoss model**

```swift
// Domain/Models/InstrumentProfitLoss.swift
import Foundation

/// Per-instrument profit and loss summary.
struct InstrumentProfitLoss: Sendable, Identifiable, Hashable {
  var id: String { instrument.id }

  let instrument: Instrument
  let currentQuantity: Decimal
  let totalInvested: Decimal        // Total cost basis ever purchased (in profile currency)
  let currentValue: Decimal         // Current market value of remaining position
  let realizedGain: Decimal         // Sum of gains from closed lots
  let unrealizedGain: Decimal       // Current value - remaining cost basis

  /// Total return = realized + unrealized
  var totalGain: Decimal { realizedGain + unrealizedGain }

  /// Return percentage on total invested
  var returnPercentage: Decimal {
    guard totalInvested != 0 else { return 0 }
    return (totalGain / totalInvested) * 100
  }
}
```

- [ ] **Step 4: Implement ProfitLossCalculator**

```swift
// Shared/ProfitLossCalculator.swift
import Foundation

/// Computes per-instrument profit/loss from transaction history.
///
/// Combines FIFO cost basis tracking with current market valuation.
enum ProfitLossCalculator {
  static func compute(
    transactions: [LegTransaction],
    profileCurrency: Instrument,
    conversionService: InstrumentConversionService,
    asOfDate: Date
  ) async throws -> [InstrumentProfitLoss] {
    // Run capital gains computation to get events and open lots
    let gainsResult = try await CapitalGainsCalculator.computeWithConversion(
      transactions: transactions,
      profileCurrency: profileCurrency,
      conversionService: conversionService
    )

    // Track total invested and realized gains per instrument
    var instrumentData: [String: InstrumentData] = [:]

    // Process all transactions to compute total invested
    let sorted = transactions.sorted { $0.date < $1.date }
    for tx in sorted {
      let fiatLegs = tx.legs.filter { $0.instrument.kind == .fiatCurrency }
      let nonFiatLegs = tx.legs.filter { $0.instrument.kind != .fiatCurrency }

      let fiatOutflow = fiatLegs.filter { $0.quantity < 0 }
        .reduce(Decimal(0)) { $0 + abs($1.quantity) }

      for leg in nonFiatLegs where leg.quantity > 0 {
        instrumentData[leg.instrument.id, default: InstrumentData(instrument: leg.instrument)]
          .totalInvested += fiatOutflow
      }
    }

    // Add realized gains from events
    for event in gainsResult.events {
      instrumentData[event.instrument.id, default: InstrumentData(instrument: event.instrument)]
        .realizedGain += event.gain
    }

    // Compute current value and unrealized gain from open lots
    for lot in gainsResult.openLots {
      let id = lot.instrument.id
      instrumentData[id, default: InstrumentData(instrument: lot.instrument)]
        .currentQuantity += lot.remainingQuantity
      instrumentData[id, default: InstrumentData(instrument: lot.instrument)]
        .remainingCostBasis += lot.remainingCost
    }

    // Get current market values
    var results: [InstrumentProfitLoss] = []
    for (_, data) in instrumentData {
      var currentValue: Decimal = 0
      if data.currentQuantity > 0 {
        currentValue = try await conversionService.convert(
          data.currentQuantity, from: data.instrument, to: profileCurrency, on: asOfDate
        )
      }

      let unrealized = currentValue - data.remainingCostBasis

      results.append(InstrumentProfitLoss(
        instrument: data.instrument,
        currentQuantity: data.currentQuantity,
        totalInvested: data.totalInvested,
        currentValue: currentValue,
        realizedGain: data.realizedGain,
        unrealizedGain: unrealized
      ))
    }

    return results.sorted { $0.totalGain > $1.totalGain }
  }

  private struct InstrumentData {
    let instrument: Instrument
    var totalInvested: Decimal = 0
    var realizedGain: Decimal = 0
    var currentQuantity: Decimal = 0
    var remainingCostBasis: Decimal = 0
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
just test 2>&1 | tee .agent-tmp/test-pnl.txt
grep -i 'failed\|error:' .agent-tmp/test-pnl.txt
```

- [ ] **Step 6: Clean up and commit**

```bash
rm .agent-tmp/test-pnl.txt
```

---

## Task 7: ReportingStore

Store layer that loads transaction data, runs capital gains and P&L calculations, and publishes results for the UI.

**Files:**
- Create: `Features/Reports/ReportingStore.swift`
- Create: `MoolahTests/Features/ReportingStoreTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// MoolahTests/Features/ReportingStoreTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("ReportingStore")
struct ReportingStoreTests {
  let aud = Instrument.fiat(code: "AUD")

  @Test @MainActor func loadProfitLoss_populatesState() async throws {
    let backend = try TestBackend()
    // Create account and transactions with stock legs via backend
    // ... (specific creation calls depend on Phase 1-4 API)

    let store = ReportingStore(
      transactionRepository: backend.provider.transactionRepository,
      conversionService: FixedConversionService(rates: ["ASX:BHP": 50]),
      profileCurrency: aud
    )

    await store.loadProfitLoss()

    #expect(!store.isLoading)
    #expect(store.error == nil)
    // Verify P&L data matches expected values
  }

  @Test @MainActor func loadCapitalGains_forFinancialYear() async throws {
    let backend = try TestBackend()
    // Create transactions spanning a financial year boundary

    let store = ReportingStore(
      transactionRepository: backend.provider.transactionRepository,
      conversionService: FixedConversionService(rates: [:]),
      profileCurrency: aud
    )

    await store.loadCapitalGains(financialYear: 2026)

    #expect(!store.isLoading)
    #expect(store.error == nil)
    // Verify only events in FY2025-26 (1 Jul 2025 - 30 Jun 2026) are included
  }

  @Test @MainActor func capitalGainsSummary_separatesShortAndLongTerm() async throws {
    let backend = try TestBackend()
    // Create a short-term sale and a long-term sale

    let store = ReportingStore(
      transactionRepository: backend.provider.transactionRepository,
      conversionService: FixedConversionService(rates: [:]),
      profileCurrency: aud
    )

    await store.loadCapitalGains(financialYear: 2026)

    // Verify short-term and long-term gains are separated
    #expect(store.capitalGainsSummary != nil)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
just test 2>&1 | tee .agent-tmp/test-reporting-store.txt
```

- [ ] **Step 3: Implement ReportingStore**

```swift
// Features/Reports/ReportingStore.swift
import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class ReportingStore {
  // Published state
  private(set) var profitLoss: [InstrumentProfitLoss] = []
  private(set) var capitalGainsResult: CapitalGainsResult?
  private(set) var capitalGainsSummary: CapitalGainsSummary?
  private(set) var isLoading = false
  private(set) var error: Error?

  private let transactionRepository: TransactionRepository
  private let conversionService: InstrumentConversionService
  private let profileCurrency: Instrument
  private let logger = Logger(subsystem: "com.moolah.app", category: "ReportingStore")

  init(
    transactionRepository: TransactionRepository,
    conversionService: InstrumentConversionService,
    profileCurrency: Instrument
  ) {
    self.transactionRepository = transactionRepository
    self.conversionService = conversionService
    self.profileCurrency = profileCurrency
  }

  func loadProfitLoss() async {
    isLoading = true
    error = nil
    do {
      let transactions = try await loadAllLegTransactions()
      profitLoss = try await ProfitLossCalculator.compute(
        transactions: transactions,
        profileCurrency: profileCurrency,
        conversionService: conversionService,
        asOfDate: Date()
      )
    } catch {
      logger.error("Failed to load P&L: \(error)")
      self.error = error
    }
    isLoading = false
  }

  /// Load capital gains for an Australian financial year (1 Jul to 30 Jun).
  func loadCapitalGains(financialYear: Int) async {
    isLoading = true
    error = nil
    do {
      let transactions = try await loadAllLegTransactions()

      // Australian FY: 1 July (year-1) to 30 June (year)
      let calendar = Calendar(identifier: .gregorian)
      let fyStart = calendar.date(from: DateComponents(year: financialYear - 1, month: 7, day: 1))!
      let fyEnd = calendar.date(from: DateComponents(year: financialYear, month: 6, day: 30))!

      let result = try await CapitalGainsCalculator.computeWithConversion(
        transactions: transactions,
        profileCurrency: profileCurrency,
        conversionService: conversionService,
        sellDateRange: fyStart...fyEnd
      )
      capitalGainsResult = result
      capitalGainsSummary = CapitalGainsSummary(
        shortTermGain: result.shortTermGain,
        longTermGain: result.longTermGain,
        totalGain: result.totalRealizedGain,
        eventCount: result.events.count
      )
    } catch {
      logger.error("Failed to load capital gains: \(error)")
      self.error = error
    }
    isLoading = false
  }

  // MARK: - Private

  private func loadAllLegTransactions() async throws -> [LegTransaction] {
    // Fetch all non-scheduled transactions, convert to LegTransaction
    // Exact implementation depends on Phase 1 TransactionRepository API
    // which exposes legs on each transaction
    let page = try await transactionRepository.fetchTransactions(
      page: 0, pageSize: Int.max, filter: nil
    )
    return page.transactions.map { tx in
      LegTransaction(date: tx.date, legs: tx.legs)
    }
  }
}

/// Summary of capital gains for a financial year.
struct CapitalGainsSummary: Sendable {
  let shortTermGain: Decimal
  let longTermGain: Decimal
  let totalGain: Decimal
  let eventCount: Int

  /// Australian CGT discount: 50% on long-term gains for individuals.
  var discountedLongTermGain: Decimal {
    max(0, longTermGain) * Decimal(string: "0.5")!
  }

  /// Net capital gain after applying CGT discount (losses offset gains before discount).
  var netCapitalGain: Decimal {
    let netShortTerm = shortTermGain
    let netLongTerm = longTermGain > 0 ? discountedLongTermGain : longTermGain
    return max(0, netShortTerm + netLongTerm)
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
just test 2>&1 | tee .agent-tmp/test-reporting-store.txt
grep -i 'failed\|error:' .agent-tmp/test-reporting-store.txt
```

- [ ] **Step 5: Clean up and commit**

```bash
rm .agent-tmp/test-reporting-store.txt
```

---

## Task 8: Tax Reporting Integration

Wire computed capital gains into the tax reporting system so `TaxYearAdjustments` can be auto-populated from actual trade data instead of manual entry.

**Files:**
- Modify: `plans/2026-04-11-australian-tax-reporting-design.md` — update capital gains section
- Add method to `ReportingStore` or `TaxStore`
- Add tests

- [ ] **Step 1: Write failing test**

```swift
// Add to MoolahTests/Features/ReportingStoreTests.swift
@Test @MainActor func capitalGainsForTax_producesAdjustmentValues() async throws {
  let backend = try TestBackend()
  // Create transactions with both short-term and long-term sales

  let store = ReportingStore(
    transactionRepository: backend.provider.transactionRepository,
    conversionService: FixedConversionService(rates: [:]),
    profileCurrency: Instrument.fiat(code: "AUD")
  )

  await store.loadCapitalGains(financialYear: 2026)

  let summary = store.capitalGainsSummary
  #expect(summary != nil)

  // These values can feed directly into TaxYearAdjustments
  // shortTermCapitalGains = summary.shortTermGain (as InstrumentAmount)
  // longTermCapitalGains = summary.longTermGain (pre-discount, as InstrumentAmount)
  // The TaxCalculator handles the 50% discount
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test 2>&1 | tee .agent-tmp/test-tax-integration.txt
```

- [ ] **Step 3: Implement tax integration**

Add a method that converts `CapitalGainsSummary` into the format expected by `TaxYearAdjustments`:

```swift
// Add to Features/Reports/ReportingStore.swift (or a shared utility)
extension CapitalGainsSummary {
  /// Convert to values suitable for TaxYearAdjustments fields.
  ///
  /// Maps to:
  /// - `shortTermCapitalGains`: gains from assets held < 12 months
  /// - `longTermCapitalGains`: pre-discount gains from assets held > 12 months
  /// - `capitalLosses`: absolute value of net losses (if total is negative)
  func asTaxAdjustmentValues(currency: Instrument) -> (
    shortTerm: InstrumentAmount,
    longTerm: InstrumentAmount,
    losses: InstrumentAmount
  ) {
    let shortTerm = InstrumentAmount(
      quantity: max(0, shortTermGain), instrument: currency
    )
    let longTerm = InstrumentAmount(
      quantity: max(0, longTermGain), instrument: currency
    )
    let totalLoss = min(0, shortTermGain) + min(0, longTermGain)
    let losses = InstrumentAmount(
      quantity: abs(totalLoss), instrument: currency
    )
    return (shortTerm, longTerm, losses)
  }
}
```

The `TaxStore.loadTaxSummary` (from the tax reporting design) calls `ReportingStore.loadCapitalGains` and uses `asTaxAdjustmentValues` to populate the capital gains fields on `TaxYearAdjustments`. This replaces the manual "summary import" approach described in the original tax design.

- [ ] **Step 4: Update tax reporting design document**

Update `plans/2026-04-11-australian-tax-reporting-design.md`:
- Change the "Capital gains: summary import only" scope item to note that computed capital gains are now available from Phase 5 reporting
- Change the Non-Goals "Full capital gains lot tracking" to note this is now implemented via FIFO in `CostBasisEngine`
- Update `TaxYearAdjustments` to note that `shortTermCapitalGains`, `longTermCapitalGains`, and `capitalLosses` can be auto-populated from `ReportingStore.capitalGainsSummary`, with manual override still available

- [ ] **Step 5: Run tests to verify they pass**

```bash
just test 2>&1 | tee .agent-tmp/test-tax-integration.txt
grep -i 'failed\|error:' .agent-tmp/test-tax-integration.txt
```

- [ ] **Step 6: Clean up and commit**

```bash
rm .agent-tmp/test-tax-integration.txt
```

---

## Task Summary

| Task | Type | Key Output | Depends On |
|------|------|-----------|------------|
| 1 | Investigation | Performance measurements, approach decision | Phases 1-4 |
| 2 | Implementation | `NetWorthCalculator`, `NetWorthPoint` | Task 1 |
| 3 | Integration | Multi-instrument net worth in `CloudKitAnalysisRepository` | Task 2 |
| 4 | Implementation | `CostBasisEngine`, `CostBasisLot`, `CapitalGainEvent` | Phases 1-4 |
| 5 | Implementation | `CapitalGainsCalculator`, `LegTransaction` | Task 4 |
| 6 | Implementation | `ProfitLossCalculator`, `InstrumentProfitLoss` | Task 5 |
| 7 | Implementation | `ReportingStore` | Tasks 5, 6 |
| 8 | Integration | Tax reporting capital gains wiring | Task 7 |

Tasks 1-3 (net worth) and Tasks 4-6 (capital gains / P&L) are independent tracks that can be worked in parallel. Task 7 depends on both tracks. Task 8 depends on Task 7.
