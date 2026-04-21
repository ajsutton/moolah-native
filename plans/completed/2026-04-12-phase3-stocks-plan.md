# Phase 3: Stock Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable investment accounts to hold stock positions with live market valuations, recorded via a dedicated trade transaction UI, and retire the manual `investmentValue` approach for accounts that adopt per-instrument position tracking.

**Completed:** `7d3459c` on `feature/multi-instrument` — 641 tests passing on macOS.

**Architecture:** Extend `Instrument` with a `.stock(ticker:exchange:name:)` factory. Wire `StockPriceService` into `InstrumentConversionService` so stock-to-fiat conversion routes through stock price lookup (getting the listing currency) then fiat-to-fiat if the listing currency differs from the target. Add a `TradeDraft` value type that produces multi-leg transactions (cash out, stock in, optional fee). Build `StockPositionsView` for the investment account detail showing per-instrument quantities with live market values. Add a `usesPositionTracking` flag on `Account` so the UI can switch between the legacy `investmentValue` panel and the new positions-based display.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, CloudKit, Swift Testing, Yahoo Finance API (via existing `YahooFinanceClient`)

**Key files to read before starting:** `plans/2026-04-12-multi-instrument-design.md` (overall design), `plans/2026-04-12-phase1-foundation-plan.md` (foundation types this builds on), `CLAUDE.md`, `CONCURRENCY_GUIDE.md`, `UI_GUIDE.md`.

**Prerequisite:** Phase 1 (Instrument, InstrumentAmount, TransactionLeg, leg-based transactions) and Phase 2 (InstrumentConversionService with fiat-to-fiat, Position type, multi-currency account display) must be complete before starting this plan.

---

## File Structure

### New Files
- `MoolahTests/Domain/InstrumentStockTests.swift` — Tests for `Instrument.stock()` factory
- `MoolahTests/Shared/InstrumentConversionServiceStockTests.swift` — Tests for stock-to-fiat conversion routing
- `MoolahTests/Shared/TradeDraftTests.swift` — Tests for trade draft validation and leg generation
- `Shared/Models/TradeDraft.swift` — Value type capturing trade form state, produces multi-leg transactions
- `MoolahTests/Features/TradeStoreTests.swift` — Tests for trade execution store
- `Features/Investments/TradeStore.swift` — Store for executing trade transactions
- `Features/Investments/Views/RecordTradeView.swift` — Trade entry form (instrument sold, bought, quantities, fee)
- `Features/Investments/Views/StockPositionsView.swift` — Per-instrument position list with market values
- `Features/Investments/Views/StockPositionRow.swift` — Single position row (ticker, quantity, value, gain/loss)
- `MoolahTests/Features/StockPositionDisplayTests.swift` — Tests for position valuation logic in the store

### Major Modifications
- `Domain/Models/Instrument.swift` — Add `stock(ticker:exchange:name:)` factory, convenience constants
- `Shared/InstrumentConversionService.swift` — Wire stock price routing (Phase 2 creates this file with fiat-only support)
- `Domain/Models/Account.swift` — Add `usesPositionTracking: Bool` flag
- `Backends/CloudKit/Models/AccountRecord.swift` — Persist `usesPositionTracking` field
- `Features/Investments/InvestmentStore.swift` — Add position loading and stock valuation methods
- `Features/Investments/Views/InvestmentAccountView.swift` — Conditionally show positions vs legacy valuations
- `Features/Investments/Views/InvestmentSummaryView.swift` — Compute totals from positions when position tracking is active
- `MoolahTests/Support/TestBackend.swift` — Add seed helpers for leg-based stock transactions

### Files NOT Changed
- `Domain/Repositories/StockPriceClient.swift` — Already has the right interface
- `Shared/StockPriceService.swift` — Already provides `price(ticker:on:)` and `currency(for:)`
- `Backends/YahooFinance/YahooFinanceClient.swift` — Already works
- `MoolahTests/Support/FixedStockPriceClient.swift` — Already works for test doubles

---

## Task 1: Instrument.stock() Factory

**Files:**
- Create: `MoolahTests/Domain/InstrumentStockTests.swift`
- Modify: `Domain/Models/Instrument.swift`

**Why:** The `Instrument` type from Phase 1 has the `Kind.stock` case and all optional metadata fields, but no factory method for constructing stock instruments. We need `Instrument.stock(ticker:exchange:name:)` to parallel `Instrument.fiat(code:)`.

- [ ] **Step 1: Write the failing tests**

```swift
// MoolahTests/Domain/InstrumentStockTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("Instrument — Stock")
struct InstrumentStockTests {
  @Test func stockInstrumentProperties() {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    #expect(bhp.id == "ASX:BHP")
    #expect(bhp.kind == .stock)
    #expect(bhp.name == "BHP")
    #expect(bhp.decimals == 0)
    #expect(bhp.ticker == "BHP.AX")
    #expect(bhp.exchange == "ASX")
    #expect(bhp.chainId == nil)
    #expect(bhp.contractAddress == nil)
  }

  @Test func stockIdUsesExchangeColonName() {
    let aapl = Instrument.stock(ticker: "AAPL", exchange: "NASDAQ", name: "Apple")
    #expect(aapl.id == "NASDAQ:Apple")
  }

  @Test func stockDecimalsDefaultToZero() {
    // Stocks are traded in whole shares (fractional shares are quantity-level, not instrument-level)
    let stock = Instrument.stock(ticker: "VAS.AX", exchange: "ASX", name: "VAS")
    #expect(stock.decimals == 0)
  }

  @Test func stockWithCustomDecimals() {
    // Some instruments may need fractional display (e.g., ETFs with fractional shares)
    let stock = Instrument.stock(ticker: "BTC-USD", exchange: "CRYPTO", name: "BTC-USD", decimals: 8)
    #expect(stock.decimals == 8)
  }

  @Test func stockCurrencySymbolIsNil() {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    #expect(bhp.currencySymbol == nil)
  }

  @Test func stockCodableRoundTrip() throws {
    let original = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Instrument.self, from: data)
    #expect(decoded == original)
    #expect(decoded.ticker == "BHP.AX")
    #expect(decoded.exchange == "ASX")
  }

  @Test func stockEquality() {
    let a = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let b = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let c = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")
    #expect(a == b)
    #expect(a != c)
  }

  @Test func stockHashable() {
    let a = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let b = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    #expect(a.hashValue == b.hashValue)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
just test 2>&1 | tee .agent-tmp/test-instrument-stock.txt
grep -i 'failed\|error:' .agent-tmp/test-instrument-stock.txt
```

Expected: FAIL — `Instrument.stock(ticker:exchange:name:)` not defined.

- [ ] **Step 3: Implement stock factory on Instrument**

Add to `Domain/Models/Instrument.swift`:

```swift
  /// Factory for stock instruments.
  /// `ticker` is the Yahoo Finance symbol (e.g., "BHP.AX").
  /// `exchange` is the exchange code (e.g., "ASX", "NASDAQ").
  /// `name` is the display name (e.g., "BHP", "Apple").
  /// `decimals` defaults to 0 (whole shares); override for fractional instruments.
  static func stock(ticker: String, exchange: String, name: String, decimals: Int = 0) -> Instrument {
    Instrument(
      id: "\(exchange):\(name)",
      kind: .stock,
      name: name,
      decimals: decimals,
      ticker: ticker,
      exchange: exchange,
      chainId: nil,
      contractAddress: nil
    )
  }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
just test 2>&1 | tee .agent-tmp/test-instrument-stock.txt
grep -i 'failed\|error:' .agent-tmp/test-instrument-stock.txt
```

Expected: All InstrumentStockTests PASS.

- [ ] **Step 5: Clean up and commit**

```bash
rm .agent-tmp/test-instrument-stock.txt
git add Domain/Models/Instrument.swift MoolahTests/Domain/InstrumentStockTests.swift
git commit -m "feat: add Instrument.stock() factory for stock instruments"
```

---

## Task 2: Wire Stock Prices into InstrumentConversionService

**Files:**
- Create: `MoolahTests/Shared/InstrumentConversionServiceStockTests.swift`
- Modify: `Shared/InstrumentConversionService.swift` (created in Phase 2)

**Why:** Phase 2 creates `InstrumentConversionService` with fiat-to-fiat routing via `ExchangeRateService`. This task adds stock-to-fiat routing: look up the stock price in its listing currency via `StockPriceService`, then convert from listing currency to target fiat via the existing fiat-to-fiat path.

**Prerequisite context:** `StockPriceService` is an `actor` with `price(ticker:on:) -> Decimal` and `currency(for:) -> Currency`. It already handles caching and network fetching. The conversion service needs a reference to it.

- [ ] **Step 1: Write the failing tests**

```swift
// MoolahTests/Shared/InstrumentConversionServiceStockTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentConversionService — Stock")
struct InstrumentConversionServiceStockTests {
  let aud = Instrument.fiat(code: "AUD")
  let usd = Instrument.fiat(code: "USD")
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let aapl = Instrument.stock(ticker: "AAPL", exchange: "NASDAQ", name: "Apple")

  private func makeService(
    stockPrices: [String: StockPriceResponse] = [:],
    exchangeRates: [String: [String: Decimal]] = [:]
  ) -> InstrumentConversionService {
    let stockClient = FixedStockPriceClient(responses: stockPrices)
    let stockService = StockPriceService(client: stockClient, cacheDirectory: nil)
    let rateClient = FixedRateClient(rates: exchangeRates)
    let rateService = ExchangeRateService(client: rateClient, cacheDirectory: nil)
    return InstrumentConversionService(
      exchangeRates: rateService,
      stockPrices: stockService
    )
  }

  private func dateString(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.string(from: date)
  }

  @Test func stockToListingCurrencySameFiat() async throws {
    // BHP listed in AUD, converting to AUD — just stock price, no FX
    let today = Date()
    let ds = dateString(today)
    let service = makeService(
      stockPrices: ["BHP.AX": StockPriceResponse(currency: .AUD, prices: [ds: Decimal(string: "42.30")!])]
    )

    let result = try await service.convert(Decimal(150), from: bhp, to: aud, on: today)
    // 150 shares * $42.30 = $6345.00
    #expect(result == Decimal(string: "6345.00")!)
  }

  @Test func stockToForeignFiatRequiresFXConversion() async throws {
    // AAPL listed in USD, converting to AUD — stock price * FX rate
    let today = Date()
    let ds = dateString(today)
    let service = makeService(
      stockPrices: ["AAPL": StockPriceResponse(currency: .USD, prices: [ds: Decimal(string: "185.50")!])],
      exchangeRates: [ds: ["AUD": Decimal(string: "1.55")!]]  // 1 USD = 1.55 AUD
    )

    let result = try await service.convert(Decimal(10), from: aapl, to: aud, on: today)
    // 10 shares * $185.50 USD * 1.55 AUD/USD = $2875.25 AUD
    #expect(result == Decimal(string: "2875.25")!)
  }

  @Test func stockToStockNotSupported() async throws {
    // Stock-to-stock conversion should throw (go through fiat as intermediate)
    let today = Date()
    let service = makeService()

    await #expect(throws: (any Error).self) {
      _ = try await service.convert(Decimal(10), from: bhp, to: aapl, on: today)
    }
  }

  @Test func fiatToStockNotSupported() async throws {
    // Fiat-to-stock conversion doesn't make sense for display purposes
    let today = Date()
    let service = makeService()

    await #expect(throws: (any Error).self) {
      _ = try await service.convert(Decimal(1000), from: aud, to: bhp, on: today)
    }
  }

  @Test func stockPriceFetchFailureThrows() async throws {
    let today = Date()
    let stockClient = FixedStockPriceClient(shouldFail: true)
    let stockService = StockPriceService(client: stockClient, cacheDirectory: nil)
    let rateClient = FixedRateClient(rates: [:])
    let rateService = ExchangeRateService(client: rateClient, cacheDirectory: nil)
    let service = InstrumentConversionService(
      exchangeRates: rateService,
      stockPrices: stockService
    )

    await #expect(throws: (any Error).self) {
      _ = try await service.convert(Decimal(10), from: bhp, to: aud, on: today)
    }
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
just test 2>&1 | tee .agent-tmp/test-conversion-stock.txt
grep -i 'failed\|error:' .agent-tmp/test-conversion-stock.txt
```

Expected: FAIL — `InstrumentConversionService` does not accept `stockPrices` parameter or handle stock instruments.

- [ ] **Step 3: Add stock price routing to InstrumentConversionService**

Modify `Shared/InstrumentConversionService.swift` to add a `StockPriceService` dependency and route stock-to-fiat conversions:

```swift
// In InstrumentConversionService (Phase 2 creates this as an actor or struct)
// Add stockPrices property:
private let stockPrices: StockPriceService?

// Update init to accept optional stock prices:
init(
  exchangeRates: ExchangeRateService,
  stockPrices: StockPriceService? = nil
) {
  self.exchangeRates = exchangeRates
  self.stockPrices = stockPrices
}

// In the convert method, add stock routing before the fiat-to-fiat path:
func convert(
  _ quantity: Decimal,
  from source: Instrument,
  to target: Instrument,
  on date: Date
) async throws -> Decimal {
  // Same kind → same kind: only fiat-to-fiat is supported
  if source.kind == .fiatCurrency && target.kind == .fiatCurrency {
    // Existing Phase 2 fiat-to-fiat path
    if source.id == target.id { return quantity }
    let rate = try await exchangeRates.rate(
      from: Currency.from(code: source.id),
      to: Currency.from(code: target.id),
      on: date
    )
    return quantity * rate
  }

  // Stock → Fiat: price lookup + optional FX
  if source.kind == .stock && target.kind == .fiatCurrency {
    guard let stockPrices, let ticker = source.ticker else {
      throw ConversionError.unsupportedConversion(from: source.id, to: target.id)
    }
    let pricePerShare = try await stockPrices.price(ticker: ticker, on: date)
    let listingCurrency = try await stockPrices.currency(for: ticker)
    let valueInListingCurrency = quantity * pricePerShare

    // If listing currency matches target, done
    if listingCurrency.code == target.id {
      return valueInListingCurrency
    }

    // Otherwise convert listing currency → target fiat
    let rate = try await exchangeRates.rate(from: listingCurrency, to: Currency.from(code: target.id), on: date)
    return valueInListingCurrency * rate
  }

  throw ConversionError.unsupportedConversion(from: source.id, to: target.id)
}
```

Add the error type if not already present from Phase 2:

```swift
enum ConversionError: Error {
  case unsupportedConversion(from: String, to: String)
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
just test 2>&1 | tee .agent-tmp/test-conversion-stock.txt
grep -i 'failed\|error:' .agent-tmp/test-conversion-stock.txt
```

Expected: All InstrumentConversionServiceStockTests PASS. Existing fiat-to-fiat tests still pass.

- [ ] **Step 5: Clean up and commit**

```bash
rm .agent-tmp/test-conversion-stock.txt
git add Shared/InstrumentConversionService.swift MoolahTests/Shared/InstrumentConversionServiceStockTests.swift
git commit -m "feat: wire stock price routing into InstrumentConversionService"
```

---

## Task 3: TradeDraft Value Type

**Files:**
- Create: `MoolahTests/Shared/TradeDraftTests.swift`
- Create: `Shared/Models/TradeDraft.swift`

**Why:** The trade UI needs a value type (like `TransactionDraft` for regular transactions) that captures the user's intent — instrument sold, instrument bought, quantities, optional fee — and produces the correct multi-leg transaction. This is pure logic, no UI, fully testable.

**Leg generation rules (from design spec):**
- Stock purchase: `transfer [account, AUD, -6345]`, `transfer [account, BHP, +150]`
- With fee: adds `expense [account, AUD, -9.50, cat:"Brokerage Fees"]`
- Stock sale: `transfer [account, BHP, -150]`, `transfer [account, AUD, +6345]`

- [ ] **Step 1: Write the failing tests**

```swift
// MoolahTests/Shared/TradeDraftTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("TradeDraft")
struct TradeDraftTests {
  let accountId = UUID()
  let aud = Instrument.fiat(code: "AUD")
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let feeCategoryId = UUID()

  // MARK: - Validation

  @Test func emptyDraftIsInvalid() {
    let draft = TradeDraft(accountId: accountId)
    #expect(!draft.isValid)
  }

  @Test func validBuyDraft() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    draft.date = Date()
    #expect(draft.isValid)
  }

  @Test func missingBoughtInstrumentIsInvalid() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtQuantityText = "150"
    draft.date = Date()
    #expect(!draft.isValid)
  }

  @Test func zeroQuantityIsInvalid() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "0"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    #expect(!draft.isValid)
  }

  // MARK: - Leg Generation

  @Test func buyStockProducesTwoTransferLegs() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    draft.date = Date()

    let transaction = draft.toTransaction(id: UUID())
    #expect(transaction != nil)

    let legs = transaction!.legs
    #expect(legs.count == 2)

    // Leg 0: cash outflow
    #expect(legs[0].accountId == accountId)
    #expect(legs[0].instrument == aud)
    #expect(legs[0].quantity == Decimal(string: "-6345.00")!)
    #expect(legs[0].type == .transfer)

    // Leg 1: stock inflow
    #expect(legs[1].accountId == accountId)
    #expect(legs[1].instrument == bhp)
    #expect(legs[1].quantity == Decimal(150))
    #expect(legs[1].type == .transfer)
  }

  @Test func buyStockWithFeeProducesThreeLegs() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    draft.feeAmountText = "9.50"
    draft.feeInstrument = aud
    draft.feeCategoryId = feeCategoryId
    draft.date = Date()

    let transaction = draft.toTransaction(id: UUID())
    #expect(transaction != nil)

    let legs = transaction!.legs
    #expect(legs.count == 3)

    // Leg 2: fee expense
    #expect(legs[2].accountId == accountId)
    #expect(legs[2].instrument == aud)
    #expect(legs[2].quantity == Decimal(string: "-9.50")!)
    #expect(legs[2].type == .expense)
    #expect(legs[2].categoryId == feeCategoryId)
  }

  @Test func sellStockProducesCorrectSigns() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = bhp
    draft.soldQuantityText = "50"
    draft.boughtInstrument = aud
    draft.boughtQuantityText = "2115.00"
    draft.date = Date()

    let transaction = draft.toTransaction(id: UUID())
    #expect(transaction != nil)

    let legs = transaction!.legs
    #expect(legs.count == 2)

    // Leg 0: stock outflow
    #expect(legs[0].instrument == bhp)
    #expect(legs[0].quantity == Decimal(-50))

    // Leg 1: cash inflow
    #expect(legs[1].instrument == aud)
    #expect(legs[1].quantity == Decimal(string: "2115.00")!)
  }

  @Test func transactionPayeeIsGeneratedFromTrade() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    draft.date = Date()

    let transaction = draft.toTransaction(id: UUID())
    #expect(transaction?.payee == "Buy 150 BHP")
  }

  @Test func sellTransactionPayee() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = bhp
    draft.soldQuantityText = "50"
    draft.boughtInstrument = aud
    draft.boughtQuantityText = "2115.00"
    draft.date = Date()

    let transaction = draft.toTransaction(id: UUID())
    #expect(transaction?.payee == "Sell 50 BHP")
  }

  @Test func feeWithoutCategoryStillValid() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    draft.feeAmountText = "9.50"
    draft.feeInstrument = aud
    draft.date = Date()

    #expect(draft.isValid)
    let legs = draft.toTransaction(id: UUID())!.legs
    #expect(legs.count == 3)
    #expect(legs[2].categoryId == nil)
  }

  @Test func parsedQuantitiesHandleCommas() {
    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "1,234.56"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "100"
    draft.date = Date()

    let transaction = draft.toTransaction(id: UUID())
    #expect(transaction != nil)
    #expect(transaction!.legs[0].quantity == Decimal(string: "-1234.56")!)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
just test 2>&1 | tee .agent-tmp/test-trade-draft.txt
grep -i 'failed\|error:' .agent-tmp/test-trade-draft.txt
```

Expected: FAIL — `TradeDraft` type not defined.

- [ ] **Step 3: Implement TradeDraft**

```swift
// Shared/Models/TradeDraft.swift
import Foundation

/// Captures trade form state and converts it into a multi-leg Transaction.
/// Parallel to TransactionDraft for regular transactions.
struct TradeDraft: Sendable {
  var accountId: UUID
  var date: Date = Date()

  // Sold side (outflow)
  var soldInstrument: Instrument?
  var soldQuantityText: String = ""

  // Bought side (inflow)
  var boughtInstrument: Instrument?
  var boughtQuantityText: String = ""

  // Optional fee
  var feeInstrument: Instrument?
  var feeAmountText: String = ""
  var feeCategoryId: UUID?

  var notes: String = ""

  // MARK: - Parsing

  /// Parse a quantity text into a positive Decimal, stripping commas.
  private static func parseQuantity(_ text: String) -> Decimal? {
    let cleaned = text.replacingOccurrences(of: ",", with: "")
    guard !cleaned.isEmpty, let value = Decimal(string: cleaned), value > 0 else { return nil }
    return value
  }

  var parsedSoldQuantity: Decimal? { Self.parseQuantity(soldQuantityText) }
  var parsedBoughtQuantity: Decimal? { Self.parseQuantity(boughtQuantityText) }
  var parsedFeeAmount: Decimal? { Self.parseQuantity(feeAmountText) }

  // MARK: - Validation

  var isValid: Bool {
    guard soldInstrument != nil,
          boughtInstrument != nil,
          parsedSoldQuantity != nil,
          parsedBoughtQuantity != nil
    else { return false }
    return true
  }

  // MARK: - Conversion

  /// Build a multi-leg Transaction from the trade draft.
  /// Returns nil if the draft is not valid.
  func toTransaction(id: UUID) -> Transaction? {
    guard let soldInst = soldInstrument,
          let boughtInst = boughtInstrument,
          let soldQty = parsedSoldQuantity,
          let boughtQty = parsedBoughtQuantity
    else { return nil }

    var legs: [TransactionLeg] = []

    // Leg 0: sold side (outflow — negative quantity)
    legs.append(TransactionLeg(
      accountId: accountId,
      instrument: soldInst,
      quantity: -soldQty,
      type: .transfer,
      categoryId: nil,
      earmarkId: nil
    ))

    // Leg 1: bought side (inflow — positive quantity)
    legs.append(TransactionLeg(
      accountId: accountId,
      instrument: boughtInst,
      quantity: boughtQty,
      type: .transfer,
      categoryId: nil,
      earmarkId: nil
    ))

    // Leg 2: optional fee (expense, negative quantity)
    if let feeAmount = parsedFeeAmount, let feeInst = feeInstrument ?? soldInstrument {
      legs.append(TransactionLeg(
        accountId: accountId,
        instrument: feeInst,
        quantity: -feeAmount,
        type: .expense,
        categoryId: feeCategoryId,
        earmarkId: nil
      ))
    }

    let payee = generatePayee(
      soldInst: soldInst,
      boughtInst: boughtInst,
      soldQty: soldQty,
      boughtQty: boughtQty
    )

    return Transaction(
      id: id,
      date: date,
      payee: payee,
      notes: notes.isEmpty ? nil : notes,
      legs: legs
    )
  }

  // MARK: - Payee Generation

  private func generatePayee(
    soldInst: Instrument,
    boughtInst: Instrument,
    soldQty: Decimal,
    boughtQty: Decimal
  ) -> String {
    // If selling stock for fiat: "Sell {qty} {name}"
    // If buying stock with fiat: "Buy {qty} {name}"
    // If stock-to-stock: "Trade {sold} for {bought}"
    if soldInst.kind == .stock && boughtInst.kind == .fiatCurrency {
      return "Sell \(soldQty.formattedQuantity) \(soldInst.name)"
    } else if soldInst.kind == .fiatCurrency && boughtInst.kind == .stock {
      return "Buy \(boughtQty.formattedQuantity) \(boughtInst.name)"
    } else {
      return "Trade \(soldInst.name) for \(boughtInst.name)"
    }
  }
}

// MARK: - Decimal Formatting Helper

private extension Decimal {
  /// Format a quantity for display, removing trailing zeros.
  var formattedQuantity: String {
    let formatter = NumberFormatter()
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 8
    formatter.numberStyle = .decimal
    return formatter.string(from: self as NSDecimalNumber) ?? "\(self)"
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
just test 2>&1 | tee .agent-tmp/test-trade-draft.txt
grep -i 'failed\|error:' .agent-tmp/test-trade-draft.txt
```

Expected: All TradeDraftTests PASS.

- [ ] **Step 5: Clean up and commit**

```bash
rm .agent-tmp/test-trade-draft.txt
git add Shared/Models/TradeDraft.swift MoolahTests/Shared/TradeDraftTests.swift
git commit -m "feat: add TradeDraft value type for multi-leg trade transactions"
```

---

## Task 4: Account Position Tracking Flag

**Files:**
- Modify: `Domain/Models/Account.swift`
- Modify: `Backends/CloudKit/Models/AccountRecord.swift`
- Modify: `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift`
- Update existing tests as needed (compiler-guided)

**Why:** Investment accounts need a way to distinguish between legacy manual-valuation mode (`investmentValue`) and the new position-tracking mode. This flag determines which UI to show and whether positions are computed from legs.

- [ ] **Step 1: Add `usesPositionTracking` to Account**

Add to the `Account` struct in `Domain/Models/Account.swift`:

```swift
/// Whether this account tracks per-instrument positions from transaction legs.
/// When true, the account's value is derived from positions rather than manual investmentValue entries.
/// When false (default), investment accounts use the legacy investmentValue approach.
var usesPositionTracking: Bool
```

Update the initializer default: `usesPositionTracking: Bool = false`.

Update `displayBalance` to account for position-tracked accounts (they will compute their balance differently — the actual position valuation happens in the store layer, not here).

- [ ] **Step 2: Add the field to AccountRecord and mapping**

Add `usesPositionTracking` as a `Bool` column on `AccountRecord`. Update `AccountRecord.from(_:currencyCode:)` and the `toDomain(currencyCode:)` mapping.

- [ ] **Step 3: Run full tests, fix any compilation issues**

```bash
just test 2>&1 | tee .agent-tmp/test-account-flag.txt
grep -i 'failed\|error:' .agent-tmp/test-account-flag.txt
```

Expected: All existing tests pass (new field defaults to `false`).

- [ ] **Step 4: Clean up and commit**

```bash
rm .agent-tmp/test-account-flag.txt
git add Domain/Models/Account.swift Backends/CloudKit/Models/AccountRecord.swift Backends/CloudKit/Repositories/CloudKitAccountRepository.swift
git commit -m "feat: add usesPositionTracking flag to Account for stock position support"
```

---

## Task 5: TradeStore — Execute Trades

**Files:**
- Create: `MoolahTests/Features/TradeStoreTests.swift`
- Create: `Features/Investments/TradeStore.swift`

**Why:** The trade UI needs a store to orchestrate: validate the TradeDraft, create the multi-leg transaction via the transaction repository, update the account's position cache. This follows the pattern of `TransactionStore` — all multi-step async logic lives in the store, not the view.

- [ ] **Step 1: Write the failing tests**

```swift
// MoolahTests/Features/TradeStoreTests.swift
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("TradeStore")
@MainActor
struct TradeStoreTests {
  let aud = Instrument.fiat(code: "AUD")
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  private func makeDate(year: Int, month: Int, day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
  }

  @Test func executeTradeSavesMultiLegTransaction() async throws {
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [
      Account(id: accountId, name: "Sharesight", type: .investment, usesPositionTracking: true)
    ], in: container)

    let store = TradeStore(transactions: backend.transactions)

    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    draft.date = makeDate(year: 2024, month: 6, day: 15)

    let result = try await store.executeTrade(draft)
    #expect(result != nil)
    #expect(result!.legs.count == 2)

    // Verify transaction was persisted
    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0,
      pageSize: 10
    )
    #expect(page.transactions.count == 1)
    #expect(page.transactions[0].legs.count == 2)
  }

  @Test func executeTradeWithFeeSavesThreeLegs() async throws {
    let accountId = UUID()
    let feeCategoryId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [
      Account(id: accountId, name: "Sharesight", type: .investment, usesPositionTracking: true)
    ], in: container)

    let store = TradeStore(transactions: backend.transactions)

    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    draft.feeAmountText = "9.50"
    draft.feeInstrument = aud
    draft.feeCategoryId = feeCategoryId
    draft.date = makeDate(year: 2024, month: 6, day: 15)

    let result = try await store.executeTrade(draft)
    #expect(result != nil)
    #expect(result!.legs.count == 3)
    #expect(result!.legs[2].type == .expense)
  }

  @Test func executeInvalidDraftThrows() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TradeStore(transactions: backend.transactions)

    // Empty draft — invalid
    let draft = TradeDraft(accountId: UUID())

    await #expect(throws: TradeError.self) {
      _ = try await store.executeTrade(draft)
    }
  }

  @Test func executeTradeReportsError() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TradeStore(transactions: backend.transactions)

    let draft = TradeDraft(accountId: UUID())
    do {
      _ = try await store.executeTrade(draft)
    } catch {
      #expect(store.error != nil)
    }
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
just test 2>&1 | tee .agent-tmp/test-trade-store.txt
grep -i 'failed\|error:' .agent-tmp/test-trade-store.txt
```

- [ ] **Step 3: Implement TradeStore**

```swift
// Features/Investments/TradeStore.swift
import Foundation
import OSLog
import Observation

enum TradeError: Error, LocalizedError {
  case invalidDraft

  var errorDescription: String? {
    switch self {
    case .invalidDraft: return "Trade details are incomplete or invalid"
    }
  }
}

@Observable
@MainActor
final class TradeStore {
  private(set) var error: Error?

  private let transactions: TransactionRepository
  private let logger = Logger(subsystem: "com.moolah.app", category: "TradeStore")

  init(transactions: TransactionRepository) {
    self.transactions = transactions
  }

  /// Execute a trade from a draft, creating the multi-leg transaction.
  /// Returns the created transaction, or throws on failure.
  @discardableResult
  func executeTrade(_ draft: TradeDraft) async throws -> Transaction {
    error = nil

    guard let transaction = draft.toTransaction(id: UUID()) else {
      let tradeError = TradeError.invalidDraft
      self.error = tradeError
      throw tradeError
    }

    do {
      let created = try await transactions.create(transaction)
      logger.info("Trade executed: \(created.id) with \(created.legs.count) legs")
      return created
    } catch {
      logger.error("Failed to execute trade: \(error.localizedDescription)")
      self.error = error
      throw error
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
just test 2>&1 | tee .agent-tmp/test-trade-store.txt
grep -i 'failed\|error:' .agent-tmp/test-trade-store.txt
```

- [ ] **Step 5: Clean up and commit**

```bash
rm .agent-tmp/test-trade-store.txt
git add Features/Investments/TradeStore.swift MoolahTests/Features/TradeStoreTests.swift
git commit -m "feat: add TradeStore for executing multi-leg trade transactions"
```

---

## Task 6: Stock Position Valuation in InvestmentStore

**Files:**
- Create: `MoolahTests/Features/StockPositionDisplayTests.swift`
- Modify: `Features/Investments/InvestmentStore.swift`

**Why:** The InvestmentStore needs methods to load positions for a position-tracked account, look up current market values via `InstrumentConversionService`, and compute per-position gain/loss and total portfolio value. This is the data layer for the positions UI.

- [ ] **Step 1: Write the failing tests**

```swift
// MoolahTests/Features/StockPositionDisplayTests.swift
import Foundation
import SwiftData
import Testing

@testable import Moolah

/// A valued position for display — position + current market value in profile currency.
/// Tests validate the store's ability to compute these from raw positions.
@Suite("InvestmentStore — Stock Positions")
@MainActor
struct StockPositionDisplayTests {
  let aud = Instrument.fiat(code: "AUD")
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")

  private func dateString(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.string(from: date)
  }

  @Test func loadPositionsComputesFromLegs() async throws {
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [
      Account(id: accountId, name: "Invest", type: .investment, usesPositionTracking: true)
    ], in: container)

    // Seed a buy trade: -6345 AUD, +150 BHP
    let buyDate = Calendar.current.date(from: DateComponents(year: 2024, month: 6, day: 15))!
    TestBackend.seed(transactions: [
      Transaction(
        id: UUID(),
        date: buyDate,
        legs: [
          TransactionLeg(accountId: accountId, instrument: aud, quantity: Decimal(string: "-6345.00")!, type: .transfer),
          TransactionLeg(accountId: accountId, instrument: bhp, quantity: Decimal(150), type: .transfer),
        ]
      )
    ], in: container)

    let store = InvestmentStore(
      repository: backend.investments,
      conversionService: nil
    )
    await store.loadPositions(accountId: accountId, using: backend)

    #expect(store.positions.count == 2)  // AUD + BHP

    let bhpPosition = store.positions.first { $0.instrument == bhp }
    #expect(bhpPosition != nil)
    #expect(bhpPosition!.quantity == Decimal(150))

    let audPosition = store.positions.first { $0.instrument == aud }
    #expect(audPosition != nil)
    #expect(audPosition!.quantity == Decimal(string: "-6345.00")!)
  }

  @Test func valuedPositionsIncludeMarketValue() async throws {
    let accountId = UUID()
    let today = Date()
    let ds = dateString(today)

    let stockClient = FixedStockPriceClient(responses: [
      "BHP.AX": StockPriceResponse(currency: .AUD, prices: [ds: Decimal(string: "45.00")!])
    ])
    let stockService = StockPriceService(client: stockClient, cacheDirectory: nil)
    let rateClient = FixedRateClient(rates: [:])
    let rateService = ExchangeRateService(client: rateClient, cacheDirectory: nil)
    let conversionService = InstrumentConversionService(
      exchangeRates: rateService,
      stockPrices: stockService
    )

    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [
      Account(id: accountId, name: "Invest", type: .investment, usesPositionTracking: true)
    ], in: container)
    TestBackend.seed(transactions: [
      Transaction(
        id: UUID(),
        date: today,
        legs: [
          TransactionLeg(accountId: accountId, instrument: aud, quantity: Decimal(string: "-6345.00")!, type: .transfer),
          TransactionLeg(accountId: accountId, instrument: bhp, quantity: Decimal(150), type: .transfer),
        ]
      )
    ], in: container)

    let store = InvestmentStore(
      repository: backend.investments,
      conversionService: conversionService
    )
    await store.loadPositions(accountId: accountId, using: backend)
    await store.valuatePositions(profileCurrency: aud, on: today)

    let bhpValued = store.valuedPositions.first { $0.position.instrument == bhp }
    #expect(bhpValued != nil)
    // 150 shares * $45.00 = $6,750.00
    #expect(bhpValued!.marketValue == Decimal(string: "6750.00")!)
  }

  @Test func totalPortfolioValueSumsAllPositions() async throws {
    let accountId = UUID()
    let today = Date()
    let ds = dateString(today)

    let stockClient = FixedStockPriceClient(responses: [
      "BHP.AX": StockPriceResponse(currency: .AUD, prices: [ds: Decimal(string: "45.00")!]),
      "CBA.AX": StockPriceResponse(currency: .AUD, prices: [ds: Decimal(string: "120.00")!]),
    ])
    let stockService = StockPriceService(client: stockClient, cacheDirectory: nil)
    let rateClient = FixedRateClient(rates: [:])
    let rateService = ExchangeRateService(client: rateClient, cacheDirectory: nil)
    let conversionService = InstrumentConversionService(
      exchangeRates: rateService,
      stockPrices: stockService
    )

    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [
      Account(id: accountId, name: "Invest", type: .investment, usesPositionTracking: true)
    ], in: container)
    TestBackend.seed(transactions: [
      // Buy 150 BHP for 6345 AUD
      Transaction(id: UUID(), date: today, legs: [
        TransactionLeg(accountId: accountId, instrument: aud, quantity: Decimal(string: "-6345.00")!, type: .transfer),
        TransactionLeg(accountId: accountId, instrument: bhp, quantity: Decimal(150), type: .transfer),
      ]),
      // Buy 20 CBA for 2400 AUD
      Transaction(id: UUID(), date: today, legs: [
        TransactionLeg(accountId: accountId, instrument: aud, quantity: Decimal(string: "-2400.00")!, type: .transfer),
        TransactionLeg(accountId: accountId, instrument: cba, quantity: Decimal(20), type: .transfer),
      ]),
    ], in: container)

    let store = InvestmentStore(
      repository: backend.investments,
      conversionService: conversionService
    )
    await store.loadPositions(accountId: accountId, using: backend)
    await store.valuatePositions(profileCurrency: aud, on: today)

    // Cash: -6345 - 2400 = -8745 AUD (negative = cash spent)
    // BHP: 150 * 45.00 = 6750 AUD
    // CBA: 20 * 120.00 = 2400 AUD
    // Total: -8745 + 6750 + 2400 = 405 AUD
    #expect(store.totalPortfolioValue == Decimal(string: "405.00")!)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
just test 2>&1 | tee .agent-tmp/test-position-display.txt
grep -i 'failed\|error:' .agent-tmp/test-position-display.txt
```

- [ ] **Step 3: Extend InvestmentStore with position support**

Add to `Features/Investments/InvestmentStore.swift`:

```swift
/// A position with its current market value in the profile currency.
struct ValuedPosition: Identifiable, Sendable {
  let position: Position
  var marketValue: Decimal?  // nil if price lookup failed

  var id: String { "\(position.accountId)-\(position.instrument.id)" }
}
```

Add properties and methods to `InvestmentStore`:

```swift
  private(set) var positions: [Position] = []
  private(set) var valuedPositions: [ValuedPosition] = []
  private(set) var totalPortfolioValue: Decimal = 0

  private let conversionService: InstrumentConversionService?

  // Update init to accept optional conversion service:
  init(repository: InvestmentRepository, conversionService: InstrumentConversionService? = nil) {
    self.repository = repository
    self.conversionService = conversionService
  }

  /// Load positions for a position-tracked account by computing them from transaction legs.
  func loadPositions(accountId: UUID, using backend: BackendProvider) async {
    // Fetch all transactions for this account
    // Aggregate leg quantities by (accountId, instrumentId)
    // Produces Position array
    do {
      var allTransactions: [Transaction] = []
      var page = 0
      while true {
        let result = try await backend.transactions.fetch(
          filter: TransactionFilter(accountId: accountId),
          page: page,
          pageSize: 200
        )
        allTransactions.append(contentsOf: result.transactions)
        if result.transactions.count < 200 { break }
        page += 1
      }

      var quantityByInstrument: [Instrument: Decimal] = [:]
      for txn in allTransactions {
        for leg in txn.legs where leg.accountId == accountId {
          quantityByInstrument[leg.instrument, default: 0] += leg.quantity
        }
      }

      positions = quantityByInstrument.map { instrument, quantity in
        Position(accountId: accountId, instrument: instrument, quantity: quantity)
      }.sorted { $0.instrument.name < $1.instrument.name }
    } catch {
      logger.error("Failed to load positions: \(error.localizedDescription)")
      self.error = error
    }
  }

  /// Valuate all loaded positions using current market prices.
  func valuatePositions(profileCurrency: Instrument, on date: Date) async {
    guard let conversionService else {
      valuedPositions = positions.map { ValuedPosition(position: $0, marketValue: nil) }
      return
    }

    var valued: [ValuedPosition] = []
    var total: Decimal = 0

    for position in positions {
      if position.instrument.kind == .fiatCurrency {
        // Fiat positions: convert to profile currency if different
        let value: Decimal
        if position.instrument.id == profileCurrency.id {
          value = position.quantity
        } else {
          do {
            value = try await conversionService.convert(
              position.quantity, from: position.instrument, to: profileCurrency, on: date
            )
          } catch {
            valued.append(ValuedPosition(position: position, marketValue: nil))
            continue
          }
        }
        valued.append(ValuedPosition(position: position, marketValue: value))
        total += value
      } else {
        // Stock positions: convert quantity to profile currency value
        do {
          let value = try await conversionService.convert(
            position.quantity, from: position.instrument, to: profileCurrency, on: date
          )
          valued.append(ValuedPosition(position: position, marketValue: value))
          total += value
        } catch {
          valued.append(ValuedPosition(position: position, marketValue: nil))
        }
      }
    }

    valuedPositions = valued
    totalPortfolioValue = total
  }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
just test 2>&1 | tee .agent-tmp/test-position-display.txt
grep -i 'failed\|error:' .agent-tmp/test-position-display.txt
```

Existing InvestmentStoreTests must also still pass (new `conversionService` parameter defaults to `nil`).

- [ ] **Step 5: Clean up and commit**

```bash
rm .agent-tmp/test-position-display.txt
git add Features/Investments/InvestmentStore.swift MoolahTests/Features/StockPositionDisplayTests.swift
git commit -m "feat: add stock position loading and valuation to InvestmentStore"
```

---

## Task 7: Record Trade UI

**Files:**
- Create: `Features/Investments/Views/RecordTradeView.swift`

**Why:** Investment account users need a form to record stock buys and sells. This is the SwiftUI view that binds to a `TradeDraft` and calls `TradeStore.executeTrade()`. Following the thin-views principle, all logic is in `TradeDraft` and `TradeStore`.

**Design:**
- Sheet presented from the investment account view
- Fields: Sold instrument picker, sold quantity, Bought instrument picker, bought quantity, Date picker, Optional fee section (amount, category)
- "Record Trade" button calls `TradeStore.executeTrade(draft)`
- On success, dismisses the sheet

- [ ] **Step 1: Implement RecordTradeView**

```swift
// Features/Investments/Views/RecordTradeView.swift
import SwiftUI

struct RecordTradeView: View {
  let accountId: UUID
  let profileCurrency: Instrument
  let categories: Categories
  let tradeStore: TradeStore

  @State private var draft: TradeDraft
  @State private var showFee = false
  @State private var isSaving = false
  @Environment(\.dismiss) private var dismiss

  init(
    accountId: UUID,
    profileCurrency: Instrument,
    categories: Categories,
    tradeStore: TradeStore
  ) {
    self.accountId = accountId
    self.profileCurrency = profileCurrency
    self.categories = categories
    self.tradeStore = tradeStore
    self._draft = State(initialValue: TradeDraft(accountId: accountId))
  }

  var body: some View {
    NavigationStack {
      Form {
        // Sold section
        Section("Selling") {
          instrumentPicker(
            label: "Instrument",
            selection: $draft.soldInstrument,
            defaultFiat: profileCurrency
          )
          TextField("Quantity", text: $draft.soldQuantityText)
            .keyboardType(.decimalPad)
            .monospacedDigit()
            .accessibilityLabel("Quantity sold")
        }

        // Bought section
        Section("Buying") {
          instrumentPicker(
            label: "Instrument",
            selection: $draft.boughtInstrument,
            defaultFiat: nil
          )
          TextField("Quantity", text: $draft.boughtQuantityText)
            .keyboardType(.decimalPad)
            .monospacedDigit()
            .accessibilityLabel("Quantity bought")
        }

        // Date
        Section {
          DatePicker("Date", selection: $draft.date, displayedComponents: .date)
        }

        // Fee (optional)
        Section {
          Toggle("Include Fee", isOn: $showFee)
          if showFee {
            TextField("Fee Amount", text: $draft.feeAmountText)
              .keyboardType(.decimalPad)
              .monospacedDigit()
            // Category picker for fee
            Picker("Fee Category", selection: $draft.feeCategoryId) {
              Text("None").tag(UUID?.none)
              ForEach(categories.ordered) { category in
                Text(category.name).tag(Optional(category.id))
              }
            }
          }
        }

        // Notes
        Section {
          TextField("Notes", text: $draft.notes, axis: .vertical)
            .lineLimit(3...)
        }
      }
      .navigationTitle("Record Trade")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Record") {
            Task {
              isSaving = true
              defer { isSaving = false }
              do {
                _ = try await tradeStore.executeTrade(draft)
                dismiss()
              } catch {
                // Error is captured on tradeStore.error
              }
            }
          }
          .disabled(!draft.isValid || isSaving)
        }
      }
      .alert("Error", isPresented: .constant(tradeStore.error != nil)) {
        Button("OK") { tradeStore.error = nil }
      } message: {
        if let error = tradeStore.error {
          Text(error.localizedDescription)
        }
      }
    }
  }

  // MARK: - Instrument Picker

  @ViewBuilder
  private func instrumentPicker(
    label: String,
    selection: Binding<Instrument?>,
    defaultFiat: Instrument?
  ) -> some View {
    // For Phase 3, this is a simple text field for the stock ticker
    // with a toggle between "Cash" and "Stock"
    // Full instrument search/picker is a Phase 5 enhancement
    HStack {
      Text(label)
      Spacer()
      if let instrument = selection.wrappedValue {
        Text(instrument.name)
          .foregroundStyle(.secondary)
      } else {
        Text("Select")
          .foregroundStyle(.tertiary)
      }
    }
    // TODO: Replace with full instrument picker sheet in Phase 5
    // For now, provide cash default and manual stock entry
  }
}
```

Note: The instrument picker is deliberately simplified for Phase 3. A full searchable instrument picker (with Yahoo Finance ticker lookup) is a Phase 5 enhancement. For now, the view provides basic instrument selection — the critical logic (leg generation, validation) is already tested in TradeDraft.

- [ ] **Step 2: Build to verify compilation**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-trade-view.txt
grep -i 'error:' .agent-tmp/build-trade-view.txt
```

Expected: Compiles with no errors or warnings.

- [ ] **Step 3: Clean up and commit**

```bash
rm .agent-tmp/build-trade-view.txt
git add Features/Investments/Views/RecordTradeView.swift
git commit -m "feat: add RecordTradeView for stock buy/sell entry"
```

---

## Task 8: Stock Positions Display

**Files:**
- Create: `Features/Investments/Views/StockPositionsView.swift`
- Create: `Features/Investments/Views/StockPositionRow.swift`
- Modify: `Features/Investments/Views/InvestmentAccountView.swift`
- Modify: `Features/Investments/Views/InvestmentSummaryView.swift`

**Why:** Investment accounts with `usesPositionTracking = true` need to display per-instrument positions (quantity, current market value, gain/loss) instead of the legacy manual-valuation UI.

- [ ] **Step 1: Implement StockPositionRow**

```swift
// Features/Investments/Views/StockPositionRow.swift
import SwiftUI

struct StockPositionRow: View {
  let valuedPosition: ValuedPosition
  let profileCurrency: Instrument

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(valuedPosition.position.instrument.name)
          .font(.headline)
        Text(quantityText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 2) {
        if let marketValue = valuedPosition.marketValue {
          Text(formatCurrency(marketValue))
            .font(.body)
            .monospacedDigit()
        } else {
          Text("--")
            .font(.body)
            .foregroundStyle(.tertiary)
        }
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
  }

  private var quantityText: String {
    let position = valuedPosition.position
    if position.instrument.kind == .fiatCurrency {
      return formatCurrency(position.quantity)
    }
    let formatter = NumberFormatter()
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = position.instrument.decimals
    formatter.numberStyle = .decimal
    return "\(formatter.string(from: position.quantity as NSDecimalNumber) ?? "\(position.quantity)") shares"
  }

  private func formatCurrency(_ value: Decimal) -> String {
    value.formatted(.currency(code: profileCurrency.id))
  }

  private var accessibilityText: String {
    let name = valuedPosition.position.instrument.name
    if let value = valuedPosition.marketValue {
      return "\(name), \(quantityText), valued at \(formatCurrency(value))"
    }
    return "\(name), \(quantityText), value unavailable"
  }
}
```

- [ ] **Step 2: Implement StockPositionsView**

```swift
// Features/Investments/Views/StockPositionsView.swift
import SwiftUI

struct StockPositionsView: View {
  let valuedPositions: [ValuedPosition]
  let totalValue: Decimal
  let profileCurrency: Instrument

  var body: some View {
    VStack(spacing: 0) {
      // Header with total
      HStack {
        Text("Positions")
          .font(.headline)
        Spacer()
        Text(totalValue.formatted(.currency(code: profileCurrency.id)))
          .font(.headline)
          .monospacedDigit()
      }
      .padding(.horizontal)
      .padding(.vertical, 12)

      Divider()

      if valuedPositions.isEmpty {
        ContentUnavailableView(
          "No Positions",
          systemImage: "chart.bar",
          description: Text("Record a trade to start tracking positions")
        )
      } else {
        List {
          // Stock positions first, then fiat
          ForEach(stockPositions) { vp in
            StockPositionRow(valuedPosition: vp, profileCurrency: profileCurrency)
          }
          if !cashPositions.isEmpty {
            Section("Cash") {
              ForEach(cashPositions) { vp in
                StockPositionRow(valuedPosition: vp, profileCurrency: profileCurrency)
              }
            }
          }
        }
        .listStyle(.inset)
      }
    }
  }

  private var stockPositions: [ValuedPosition] {
    valuedPositions.filter { $0.position.instrument.kind == .stock }
  }

  private var cashPositions: [ValuedPosition] {
    valuedPositions.filter { $0.position.instrument.kind == .fiatCurrency }
  }
}
```

- [ ] **Step 3: Update InvestmentAccountView for position tracking**

Modify `Features/Investments/Views/InvestmentAccountView.swift` to conditionally show positions vs legacy valuations based on `account.usesPositionTracking`:

```swift
// In the body, replace the conditional summary view with:
if account.usesPositionTracking {
  // Position-tracked: show positions and trade button
  StockPositionsView(
    valuedPositions: investmentStore.valuedPositions,
    totalValue: investmentStore.totalPortfolioValue,
    profileCurrency: profileCurrencyInstrument
  )
} else {
  // Legacy: show manual valuations (existing code)
  if account.investmentValue != nil {
    InvestmentSummaryView(account: account, store: investmentStore)
      .padding(.horizontal)
      .padding(.top)
  }
  // ... existing chart + valuations code
}
```

Add a "Record Trade" button to the toolbar when `usesPositionTracking` is true.

Update the `.task(id:)` modifier to load positions when position tracking is active:

```swift
.task(id: account.id) {
  if account.usesPositionTracking {
    await investmentStore.loadPositions(accountId: account.id, using: backend)
    await investmentStore.valuatePositions(profileCurrency: profileCurrencyInstrument, on: Date())
  } else {
    await investmentStore.loadAll(accountId: account.id)
  }
}
```

- [ ] **Step 4: Build and verify**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-positions-view.txt
grep -i 'error:\|warning:' .agent-tmp/build-positions-view.txt
```

Expected: Compiles with no errors or warnings.

- [ ] **Step 5: Run full test suite**

```bash
just test 2>&1 | tee .agent-tmp/test-positions-view.txt
grep -i 'failed\|error:' .agent-tmp/test-positions-view.txt
```

Expected: All tests pass.

- [ ] **Step 6: Clean up and commit**

```bash
rm .agent-tmp/build-positions-view.txt .agent-tmp/test-positions-view.txt
git add Features/Investments/Views/StockPositionsView.swift \
       Features/Investments/Views/StockPositionRow.swift \
       Features/Investments/Views/InvestmentAccountView.swift \
       Features/Investments/Views/InvestmentSummaryView.swift
git commit -m "feat: add stock positions display for investment accounts with position tracking"
```

---

## Task 9: Wire TradeStore into InvestmentAccountView

**Files:**
- Modify: `Features/Investments/Views/InvestmentAccountView.swift`
- Modify: `App/ProfileSession.swift` (or wherever stores are created)

**Why:** Connect the Record Trade sheet to the investment account view, and create the TradeStore at the appropriate lifecycle point.

- [ ] **Step 1: Add TradeStore to InvestmentAccountView**

Add `tradeStore: TradeStore` parameter to `InvestmentAccountView`. Add a `@State private var showingRecordTrade = false` and present `RecordTradeView` as a sheet.

Wire the "Record Trade" toolbar button (only shown when `usesPositionTracking`):

```swift
.toolbar {
  if account.usesPositionTracking {
    ToolbarItem {
      Button {
        showingRecordTrade = true
      } label: {
        Label("Record Trade", systemImage: "arrow.left.arrow.right")
      }
      .help("Record Trade")
    }
  }
}
.sheet(isPresented: $showingRecordTrade) {
  RecordTradeView(
    accountId: account.id,
    profileCurrency: profileCurrencyInstrument,
    categories: categories,
    tradeStore: tradeStore
  )
}
```

After the trade sheet dismisses, reload positions:

```swift
.onChange(of: showingRecordTrade) { _, showing in
  if !showing && account.usesPositionTracking {
    Task {
      await investmentStore.loadPositions(accountId: account.id, using: backend)
      await investmentStore.valuatePositions(profileCurrency: profileCurrencyInstrument, on: Date())
    }
  }
}
```

- [ ] **Step 2: Create TradeStore in ProfileSession or parent view**

The `TradeStore` needs `TransactionRepository` from the backend. Follow the existing pattern where `InvestmentStore` is created — create `TradeStore` at the same level and pass it down.

- [ ] **Step 3: Update all call sites**

The compiler will guide updates to any view that constructs `InvestmentAccountView` — add the `tradeStore` parameter.

- [ ] **Step 4: Build and verify**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-wire-trade.txt
grep -i 'error:\|warning:' .agent-tmp/build-wire-trade.txt
```

- [ ] **Step 5: Run full test suite**

```bash
just test 2>&1 | tee .agent-tmp/test-wire-trade.txt
grep -i 'failed\|error:' .agent-tmp/test-wire-trade.txt
```

- [ ] **Step 6: Clean up and commit**

```bash
rm .agent-tmp/build-wire-trade.txt .agent-tmp/test-wire-trade.txt
git add Features/Investments/Views/InvestmentAccountView.swift \
       App/ProfileSession.swift
git commit -m "feat: wire trade recording into investment account view"
```

---

## Task 10: Integration Test — Full Trade Flow

**Files:**
- Create: `MoolahTests/Features/TradeFlowIntegrationTests.swift`

**Why:** End-to-end test verifying that recording a trade updates positions and valuations correctly. This catches any wiring issues between TradeDraft, TradeStore, InvestmentStore, and InstrumentConversionService.

- [ ] **Step 1: Write the integration tests**

```swift
// MoolahTests/Features/TradeFlowIntegrationTests.swift
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("Trade Flow — Integration")
@MainActor
struct TradeFlowIntegrationTests {
  let aud = Instrument.fiat(code: "AUD")
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  private func dateString(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.string(from: date)
  }

  @Test func buyThenSellUpdatesPositions() async throws {
    let accountId = UUID()
    let today = Date()
    let ds = dateString(today)

    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [
      Account(id: accountId, name: "Invest", type: .investment, usesPositionTracking: true)
    ], in: container)

    let stockClient = FixedStockPriceClient(responses: [
      "BHP.AX": StockPriceResponse(currency: .AUD, prices: [ds: Decimal(string: "45.00")!])
    ])
    let stockService = StockPriceService(client: stockClient, cacheDirectory: nil)
    let rateClient = FixedRateClient(rates: [:])
    let rateService = ExchangeRateService(client: rateClient, cacheDirectory: nil)
    let conversionService = InstrumentConversionService(
      exchangeRates: rateService,
      stockPrices: stockService
    )

    let tradeStore = TradeStore(transactions: backend.transactions)
    let investmentStore = InvestmentStore(
      repository: backend.investments,
      conversionService: conversionService
    )

    // Buy 100 BHP for $4,230
    var buyDraft = TradeDraft(accountId: accountId)
    buyDraft.soldInstrument = aud
    buyDraft.soldQuantityText = "4230.00"
    buyDraft.boughtInstrument = bhp
    buyDraft.boughtQuantityText = "100"
    buyDraft.date = today
    _ = try await tradeStore.executeTrade(buyDraft)

    // Load and check positions
    await investmentStore.loadPositions(accountId: accountId, using: backend)
    #expect(investmentStore.positions.count == 2)

    let bhpPos = investmentStore.positions.first { $0.instrument == bhp }
    #expect(bhpPos?.quantity == Decimal(100))

    // Valuate
    await investmentStore.valuatePositions(profileCurrency: aud, on: today)
    let bhpValued = investmentStore.valuedPositions.first { $0.position.instrument == bhp }
    #expect(bhpValued?.marketValue == Decimal(string: "4500.00")!)  // 100 * 45.00

    // Sell 30 BHP for $1,350
    var sellDraft = TradeDraft(accountId: accountId)
    sellDraft.soldInstrument = bhp
    sellDraft.soldQuantityText = "30"
    sellDraft.boughtInstrument = aud
    sellDraft.boughtQuantityText = "1350.00"
    sellDraft.date = today
    _ = try await tradeStore.executeTrade(sellDraft)

    // Reload positions
    await investmentStore.loadPositions(accountId: accountId, using: backend)
    let bhpAfterSell = investmentStore.positions.first { $0.instrument == bhp }
    #expect(bhpAfterSell?.quantity == Decimal(70))  // 100 - 30

    // Cash position: -4230 + 1350 = -2880
    let cashPos = investmentStore.positions.first { $0.instrument == aud }
    #expect(cashPos?.quantity == Decimal(string: "-2880.00")!)
  }

  @Test func tradeWithFeeReducesCashPosition() async throws {
    let accountId = UUID()
    let feeCatId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [
      Account(id: accountId, name: "Invest", type: .investment, usesPositionTracking: true)
    ], in: container)
    TestBackend.seed(categories: [
      Category(id: feeCatId, name: "Brokerage Fees", position: 0)
    ], in: container)

    let tradeStore = TradeStore(transactions: backend.transactions)
    let investmentStore = InvestmentStore(
      repository: backend.investments,
      conversionService: nil
    )

    var draft = TradeDraft(accountId: accountId)
    draft.soldInstrument = aud
    draft.soldQuantityText = "6345.00"
    draft.boughtInstrument = bhp
    draft.boughtQuantityText = "150"
    draft.feeAmountText = "9.50"
    draft.feeInstrument = aud
    draft.feeCategoryId = feeCatId
    draft.date = Date()
    _ = try await tradeStore.executeTrade(draft)

    await investmentStore.loadPositions(accountId: accountId, using: backend)

    // Cash: -6345 - 9.50 = -6354.50
    let cashPos = investmentStore.positions.first { $0.instrument == aud }
    #expect(cashPos?.quantity == Decimal(string: "-6354.50")!)
  }
}
```

- [ ] **Step 2: Run integration tests**

```bash
just test 2>&1 | tee .agent-tmp/test-integration.txt
grep -i 'failed\|error:' .agent-tmp/test-integration.txt
```

Expected: All integration tests PASS.

- [ ] **Step 3: Clean up and commit**

```bash
rm .agent-tmp/test-integration.txt
git add MoolahTests/Features/TradeFlowIntegrationTests.swift
git commit -m "test: add integration tests for full trade flow (buy, sell, fee, positions)"
```

---

## Task 11: project.yml Updates and Final Verification

**Files:**
- Modify: `project.yml` — Ensure all new files are included in the correct targets

**Why:** The project is managed by XcodeGen. All new source files must be registered in `project.yml`, and the project must be regenerated.

- [ ] **Step 1: Verify file inclusion in project.yml**

Check that the source file groups in `project.yml` use directory-based inclusion patterns (e.g., `path: Features/Investments`). If so, new files are automatically included. If explicit file lists are used, add each new file.

New files to verify inclusion for:
- `Domain/Models/Instrument.swift` (already from Phase 1)
- `Shared/Models/TradeDraft.swift`
- `Features/Investments/TradeStore.swift`
- `Features/Investments/Views/RecordTradeView.swift`
- `Features/Investments/Views/StockPositionsView.swift`
- `Features/Investments/Views/StockPositionRow.swift`
- `MoolahTests/Domain/InstrumentStockTests.swift`
- `MoolahTests/Shared/InstrumentConversionServiceStockTests.swift`
- `MoolahTests/Shared/TradeDraftTests.swift`
- `MoolahTests/Features/TradeStoreTests.swift`
- `MoolahTests/Features/StockPositionDisplayTests.swift`
- `MoolahTests/Features/TradeFlowIntegrationTests.swift`

- [ ] **Step 2: Regenerate and build**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/build-final.txt
grep -i 'error:\|warning:' .agent-tmp/build-final.txt
```

- [ ] **Step 3: Run full test suite**

```bash
just test 2>&1 | tee .agent-tmp/test-final.txt
grep -i 'failed\|error:' .agent-tmp/test-final.txt
```

- [ ] **Step 4: Check for warnings**

Use Xcode MCP: `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"` — or check build output. Fix any warnings (unused variables, unused results, etc.).

- [ ] **Step 5: Clean up and commit**

```bash
rm .agent-tmp/build-final.txt .agent-tmp/test-final.txt
git add project.yml
git commit -m "chore: update project.yml for Phase 3 stock support files"
```

---

## Summary of Commits

1. `feat: add Instrument.stock() factory for stock instruments`
2. `feat: wire stock price routing into InstrumentConversionService`
3. `feat: add TradeDraft value type for multi-leg trade transactions`
4. `feat: add usesPositionTracking flag to Account for stock position support`
5. `feat: add TradeStore for executing multi-leg trade transactions`
6. `feat: add stock position loading and valuation to InvestmentStore`
7. `feat: add RecordTradeView for stock buy/sell entry`
8. `feat: add stock positions display for investment accounts with position tracking`
9. `feat: wire trade recording into investment account view`
10. `test: add integration tests for full trade flow (buy, sell, fee, positions)`
11. `chore: update project.yml for Phase 3 stock support files`

## Out of Scope (Deferred to Later Phases)

- **Full instrument search/picker** — Phase 3 uses a simplified instrument picker. A searchable picker with Yahoo Finance ticker lookup is a Phase 5 enhancement.
- **Position-based investment charts** — The existing chart uses manual valuations. Charting position values over time requires the performance spike planned for Phase 5.
- **Migration of legacy investment accounts** — Existing investment accounts keep using `investmentValue`. A migration path (import historical trades from manual valuations) could be added as a Phase 5 feature.
- **Capital gains/loss tracking** — Requires tracking cost basis per lot. Planned for Phase 5.
- **Dividend recording** — Income legs for dividends work with the existing model but need a tailored UI entry mode.
