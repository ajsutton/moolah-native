# Exchange Rate Infrastructure Design

## Goal

Provide exchange rate fetching, caching, and conversion helpers so that multi-currency account balances can be aggregated into the profile's currency. This plan covers the infrastructure and conversion API only — per-account currency model changes are out of scope.

## Data Source

**Frankfurter API** (`api.frankfurter.dev/v2`) — free, no API key, sources from 40+ central banks, 161 currencies, historical data from 1977. Returns daily reference rates (not real-time). The API always returns all 161 currencies per request; there is no server-side currency filtering.

## Storage

- **Location:** `FileManager.cachesDirectory` — purgeable by the OS under storage pressure on both iOS and macOS. If purged, data is re-fetched transparently.
- **Format:** One gzip-compressed JSON file per base currency (e.g. `rates-AUD.json.gz`). Contains all 161 quote currencies for every cached trading day.
- **Size:** ~2.2 MB compressed for 15 years of daily rates across all currencies. Grows ~150 KB/year.
- **Structure on disk:**
  ```
  <cachesDirectory>/exchange-rates/
    rates-AUD.json.gz
    rates-USD.json.gz
    ...
  ```
- **JSON schema** (inside the gzip):
  ```json
  {
    "base": "AUD",
    "earliestDate": "2011-04-11",
    "latestDate": "2026-04-11",
    "rates": {
      "2026-04-11": { "USD": 0.632, "EUR": 0.581, "GBP": 0.497, ... },
      "2026-04-10": { "USD": 0.629, "EUR": 0.583, ... },
      ...
    }
  }
  ```

## Core Types

```swift
/// A day's rates from one base currency, decoded from the cache file
struct DailyRates: Codable, Sendable {
    let rates: [String: Decimal]   // quote currency code -> rate
}

/// Wrapper for a cache file's contents
struct ExchangeRateCache: Codable, Sendable {
    let base: String
    var earliestDate: String                    // ISO date string
    var latestDate: String                      // ISO date string
    var rates: [String: [String: Decimal]]      // date string -> { quote -> rate }
}

```

## ExchangeRateService

A single `actor` that owns fetching, caching, and lookups.

```swift
actor ExchangeRateService {
    // --- Public API ---

    /// Get the rate for converting `from` -> `to` on a given date.
    /// Fetches from network if not cached. Falls back to nearest cached date
    /// if network is unavailable.
    func rate(from: Currency, to: Currency, on date: Date) async throws -> Decimal

    /// Get rates for a date range (used by time-series views like net worth graph).
    /// Returns rates for each trading day in the range.
    /// Fetches missing segments from the network, falls back to interpolation for gaps.
    func rates(from: Currency, to: Currency, in range: ClosedRange<Date>) async throws -> [(date: Date, rate: Decimal)]

    /// Convert an amount to a target currency on a given date.
    /// Short-circuits with rate 1.0 for same-currency conversions.
    func convert(_ amount: MonetaryAmount, to currency: Currency, on date: Date) async throws -> MonetaryAmount

    /// Prefetch latest rates for a base currency.
    /// Called on app launch / profile switch.
    func prefetchLatest(base: Currency) async
}
```

### Internal Flow

**Lookup path (for a single rate):**

1. If `from == to`, return rate 1.0 immediately.
2. Check in-memory dictionary for the base currency + date.
3. If not in memory, load the gzip cache file for that base currency (if not already loaded). Cache files are loaded lazily — only when first needed.
4. Check again after loading.
5. If still missing, fetch from Frankfurter API for the needed date range.
6. Merge fetched data into memory and persist to the gzip file.
7. If network fails and cached data exists, find the most recent cached date **on or before** the requested date (never forward — a weekend conversion uses Friday's close, not Monday's open). Return that rate.
8. If network fails and no cached data exists at all (or no earlier date is available), throw. Callers decide how to handle this.

**Lookup path (for a date range):**

1. Load cache file for the base currency if not already in memory.
2. Compare the requested range against the cache's `earliestDate`..`latestDate`:
   - If the cache covers the full range, return from cache.
   - If the request extends before `earliestDate`, fetch from `requestedStart` to `earliestDate - 1` and prepend.
   - If the request extends after `latestDate`, fetch from `latestDate + 1` to `requestedEnd` and append.
   - If no cache exists, fetch the full requested range (chunked into yearly requests for large spans).
3. Merge and persist.
4. Return the full series. On network failure, return whatever is cached and use most-recent-prior-date fallback for missing edges.

**Prefetch (on launch):**

1. Load cache file for the profile's base currency.
2. If `latestDate` is before today, fetch rates from `latestDate + 1` to today.
3. Merge and persist. This is a small incremental fetch (~2 KB/day).

### In-Memory State

```swift
/// Loaded cache files, keyed by base currency code.
/// Lazily populated — only currencies that have been requested are loaded.
private var caches: [String: ExchangeRateCache] = [:]
```

The full 15-year, all-currency cache for one base currency is ~6.9 MB uncompressed in memory. Most users will only have one or two base currencies loaded. This is acceptable.

### Frankfurter Client

A protocol for the HTTP layer, allowing injection of fixed rates in tests:

```swift
protocol ExchangeRateClient: Sendable {
    /// Fetch rates for a base currency over a date range.
    /// Returns { date_string: { quote_code: rate } }.
    func fetchRates(base: String, from: Date, to: Date) async throws -> [String: [String: Decimal]]
}

struct FrankfurterClient: ExchangeRateClient, Sendable { ... }
```

- Frankfurter returns a flat JSON array: `[{"date":"...","base":"...","quote":"...","rate":...}, ...]`
- The client reshapes this into the `{ date: { quote: rate } }` dict used by the cache.
- Rate-limiting: Frankfurter has soft rate limits. We batch by date range (not individual days), so typical usage is 1-2 requests per session. For a 15-year backfill, chunk into yearly requests (15 sequential requests of ~470 KB each).

### Persistence

After any fetch, the updated `ExchangeRateCache` is serialized to JSON, gzip-compressed, and written to the cache file. This happens on a background queue to avoid blocking the actor.

If the cache file is missing (OS purged it or first launch), the next lookup triggers a fetch for the needed range.

## MonetaryAmount Conversion Extension

```swift
extension MonetaryAmount {
    /// Convert this amount to another currency using the given rate service.
    func converted(to currency: Currency, on date: Date, using service: ExchangeRateService) async throws -> MonetaryAmount
}
```

This is a convenience wrapper around `service.convert()`. It handles the cents-level math:
1. Get the rate from the service.
2. Multiply `self.cents` by the rate.
3. Round to the target currency's decimal places using **banker's rounding** (`NSDecimalNumber.RoundingMode.bankers` / `Decimal.round(.bankers)`) so inaccuracies tend towards netting out over many conversions.
4. Return the converted `MonetaryAmount`.

## Integration Points

### ProfileSession (not BackendProvider)

Exchange rates are independent of the backend (same rates whether using Remote, CloudKit, or InMemory). The `ExchangeRateService` lives on `ProfileSession`, not on `BackendProvider`:

```swift
@Observable @MainActor
final class ProfileSession {
    // ... existing stores ...
    let exchangeRateService: ExchangeRateService
}
```

Created when the profile session is constructed, using the profile's currency as the default base. All stores and views access it through the session.

### Future Aggregation (out of scope)

When per-account currencies are added, the `AccountStore` (or a new aggregation layer) will:
1. Iterate accounts with foreign currencies.
2. Call `exchangeRateService.convert(account.balance, to: profileCurrency, on: .now)` for each.
3. Sum the converted amounts for total net worth.

The net worth graph will use `exchangeRateService.rates(from:to:in:)` to get historical rates for the visible date range, then multiply each day's foreign-currency balance by that day's rate.

## Testing

### Test Client

Inject a `FixedRateClient` conforming to `ExchangeRateClient` that returns pre-configured rates without network calls. `ExchangeRateService` takes its client via init, so tests use `ExchangeRateService(client: FixedRateClient(...))`.

```swift
struct FixedRateClient: ExchangeRateClient, Sendable {
    let rates: [String: [String: Decimal]]  // date -> { quote -> rate }
}
```

### Test Cases

- Same-currency conversion returns identity (rate 1.0, `isExact: true`).
- Cache hit returns exact rate without network call.
- Cache miss triggers fetch, caches result, returns rate.
- Network failure falls back to most recent prior cached date (looks backwards only, never forward).
- Weekend/holiday date uses the most recent trading day's rate (e.g. Saturday uses Friday's close).
- Network failure with empty cache throws.
- Date range request extends cache boundaries (before/after) without re-fetching existing data.
- Gzip round-trip: write cache, read back, verify integrity.
- Prefetch updates `latestDate` and only fetches the delta.
- Concurrent requests for the same base currency don't trigger duplicate fetches.

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Frankfurter API goes down permanently | Service is open source; we can self-host. Cache survives indefinitely in the meantime. |
| API response format changes (v2 → v3) | `FrankfurterClient` is the only type that knows the wire format. One place to update. |
| Large initial backfill on first launch (15yr) | Chunk into yearly requests. Show progress indicator. ~7 MB total, comparable to loading a few images. |
| OS purges cache at inopportune time | Graceful re-fetch on next access. Views show stale/approximate data via `isExact` flag while fetching. |
| Rate precision for large amounts | Use `Decimal` throughout (not `Double`) to avoid floating-point errors in currency math. |

## What This Plan Does NOT Cover

- Adding a `currency` field to `Account` or `Transaction` models.
- UI for displaying converted amounts or multi-currency views.
- Choosing which accounts use which currencies.
- The aggregation logic itself (summing converted balances).
- Real-time or intraday rates.
