# Australian Stock Price Service — Design Spec

## Goal

A price lookup service for ASX stocks. Fetches daily adjusted close prices from Yahoo Finance, caches them to disk, and exposes simple query methods. Follows the same provider-protocol + actor-service pattern as `ExchangeRateService`.

## Scope

- Price lookup only — no portfolio tracking, no stock registry, no UI
- 5–10 ASX stocks, updated daily
- Historical backfill on first access
- Currency conversion is out of scope — prices returned in the stock's native currency

## Data Source

**Yahoo Finance v8 API** (primary, free, no API key):

```
GET https://query2.finance.yahoo.com/v8/finance/chart/{ticker}
    ?period1={unix_timestamp}&period2={unix_timestamp}&interval=1d
```

- Ticker format: `{ASX_CODE}.AX` (e.g., `BHP.AX`, `CBA.AX`)
- Requires `User-Agent` header for reliability
- Returns parallel arrays: `timestamp[]`, `indicators.adjclose[0].adjclose[]`, `meta.currency`
- Undocumented/unofficial but stable for years, used by thousands of projects

**Fallback:** If Yahoo breaks, the `StockPriceClient` protocol allows swapping to EODHD (~US$20/month) or another provider without changing the service or consumers.

---

## Domain Models

### StockPriceCache

Per-ticker cache stored on disk. Prices are `Decimal` (market data precision — ASX quotes to 3 decimal places for stocks under $2). Conversion to `MonetaryAmount` happens at point of use, not in the price service.

```swift
struct StockPriceCache: Codable, Sendable, Equatable {
    let ticker: String            // e.g. "BHP.AX"
    let currency: Currency        // denomination discovered from API (e.g. .AUD)
    var earliestDate: String      // ISO date string
    var latestDate: String        // ISO date string
    var prices: [String: Decimal] // date string -> adjusted close price
}
```

Only the **adjusted close** is stored. Adjusted close accounts for stock splits and dividends, making it the correct price for valuations over time.

---

## Client Protocol

Thin abstraction over the HTTP layer, following the `ExchangeRateClient` pattern:

```swift
protocol StockPriceClient: Sendable {
    func fetchDailyPrices(ticker: String, from: Date, to: Date) async throws -> StockPriceResponse
}

struct StockPriceResponse: Sendable {
    let currency: Currency           // discovered from API response
    let prices: [String: Decimal]    // date string -> adjusted close
}
```

Single method. The response includes the currency because Yahoo Finance reports what currency the stock is quoted in — no hardcoding needed.

---

## Yahoo Finance Client

```swift
struct YahooFinanceClient: StockPriceClient {
    func fetchDailyPrices(ticker: String, from: Date, to: Date) async throws -> StockPriceResponse
}
```

- Direct `URLSession` — no third-party packages (adds dependency risk without meaningful benefit)
- URL construction: ticker in path, `period1`/`period2` as Unix timestamps, `interval=1d`
- `User-Agent` header set to a standard browser string
- Parses `meta.currency` for denomination
- Zips `timestamp[]` with `indicators.adjclose[0].adjclose[]`, converts timestamps to ISO date strings
- Skips null values in adjclose array (trading halts)
- Invalid ticker: Yahoo returns a specific error structure → throw descriptive error

---

## Service

Actor that owns caching and exposes query methods, following `ExchangeRateService`:

```swift
actor StockPriceService {
    private let client: StockPriceClient
    private var caches: [String: StockPriceCache]  // ticker -> cache

    init(client: StockPriceClient)

    // Primary API
    func price(ticker: String, on date: Date) async throws -> Decimal
    func prices(ticker: String, in range: ClosedRange<Date>) async throws -> [(date: String, price: Decimal)]
    func currency(for ticker: String) async throws -> Currency
}
```

### Behaviors

- **Lazy cache loading** — disk cache loaded on first access per ticker
- **Initial backfill** — on first access for a ticker with no cache, fetches full history (`period1=0` to now) in a single request
- **Range expansion** — on subsequent accesses, if a requested date is outside the cached range, fetches only the gap from the client and merges into the cache
- **Date fallback** — if a specific date has no price (weekend/holiday), falls back to the most recent prior trading day. Never looks forward.
- **Currency discovery** — the first fetch for a ticker establishes its currency from the API response, stored on the cache
- **Disk storage** — `<cachesDirectory>/stock-prices/prices-{ticker}.json.gz`, one gzip-compressed JSON file per ticker
- **Network failure** — if a fetch fails and cached data exists for the requested date, returns cached data. If no cache exists, throws.

### Ownership

Lives on `ProfileSession`, same as `ExchangeRateService`. Not on `BackendProvider` — it's a lookup service, not a repository.

---

## File Layout

### New files

| File | Purpose |
|------|---------|
| `Domain/Models/StockPriceCache.swift` | `StockPriceCache` model |
| `Domain/Repositories/StockPriceClient.swift` | `StockPriceClient` protocol + `StockPriceResponse` |
| `Shared/StockPriceService.swift` | `actor StockPriceService` |
| `Shared/YahooFinanceClient.swift` | `YahooFinanceClient` implementation |
| `MoolahTests/Support/FixedStockPriceClient.swift` | Test double |
| `MoolahTests/Shared/StockPriceServiceTests.swift` | Service tests |
| `MoolahTests/Shared/YahooFinanceClientTests.swift` | Client tests |
| `MoolahTests/Support/Fixtures/yahoo-finance-chart-response.json` | Fixture JSON |

### Modified files

| File | Change |
|------|--------|
| `App/ProfileSession.swift` | Add `stockPriceService: StockPriceService` property |
| `project.yml` | Add new files to appropriate targets |

### Dependency graph

```
Domain layer (no imports):
  StockPriceClient.swift
  StockPriceCache.swift

Shared layer (imports Foundation):
  StockPriceService.swift → uses StockPriceClient, StockPriceCache
  YahooFinanceClient.swift → uses StockPriceClient, URLSession

App layer:
  ProfileSession.swift → owns StockPriceService
```

`BackendProvider` is not modified — this is a lookup service, not a repository.

---

## Testing

### Test double

```swift
struct FixedStockPriceClient: StockPriceClient, Sendable {
    let responses: [String: StockPriceResponse]  // ticker -> response
    let shouldFail: Bool
}
```

Returns canned responses by ticker, or throws if `shouldFail` is set. Follows the `FixedRateClient` pattern.

### Service tests (`StockPriceServiceTests`)

- Cache miss triggers client fetch
- Cache hit returns without fetching
- Range expansion — dates beyond cached range fetch the gap
- Date fallback — weekend/holiday returns most recent prior trading day
- Currency discovered from first fetch and persisted
- Network failure with existing cache returns cached data
- Network failure with no cache throws
- Disk persistence — save, create new service instance, verify cache loads

### Client tests (`YahooFinanceClientTests`)

- `URLProtocol` stubs with fixture JSON (same pattern as remote backend tests)
- Correct URL construction (ticker, period1/period2, interval)
- Parsing of adjclose values and currency from response
- Null values in adjclose array are skipped
- Error response handling (invalid ticker)
