# Cryptocurrency Price Data Design

## Goal

Provide cryptocurrency token price fetching, caching, and conversion so that crypto holdings can be valued in the profile's base fiat currency on any given date. Builds on the same patterns as the exchange rate infrastructure (see `exchange-rate-design.md`).

## Tokens

The primary tokens are ETH, OP, UNI, ENS, and BTC, but the system should support any token the user adds. Tokens are uniquely identified by contract address + chain ID (not by ticker symbol, which can be duplicated across unrelated tokens and is commonly exploited in scams).

Native tokens (ETH, BTC) have no contract address. These are identified by chain ID alone with a nil contract address. For non-EVM chains like Bitcoin, we use well-known pseudo chain IDs by convention (e.g. Bitcoin = `0`, following common industry practice where no EVM chain ID exists). The chain ID is part of the identity key but doesn't imply EVM compatibility.

## Token Identity

### CryptoToken Model

```swift
/// Domain model — lives in Domain/Models/
struct CryptoToken: Codable, Sendable, Hashable, Identifiable {
    let chainId: Int               // EVM chain ID (1 = Ethereum, 10 = OP Mainnet)
    let contractAddress: String?   // nil for native tokens (ETH, BTC)
    let symbol: String             // "OP" — display only, not used for identity
    let name: String               // "Optimism"
    let decimals: Int              // Token decimals (18 for most ERC-20s)

    // Provider-specific identifiers, resolved at registration time
    let coingeckoId: String?           // "optimism"
    let cryptocompareSymbol: String?   // "OP"
    let binanceSymbol: String?         // "OPUSDT"

    var id: String {
        if let contractAddress {
            return "\(chainId):\(contractAddress.lowercased())"
        }
        return "\(chainId):native"
    }
}
```

This model lives in the domain layer with no external imports. Provider-specific fields are optional — a token can be resolved against some providers but not others.

### Token Resolution

When the user adds a token, we resolve it from contract address + chain ID to provider-specific identifiers. The resolution flow:

1. **CoinGecko contract lookup** (no API key required): `GET /coins/{platform_id}/contract/{contract_address}` returns the CoinGecko `id`, `symbol`, and `name`. The `GET /asset_platforms` endpoint maps numeric chain IDs to CoinGecko platform slugs (e.g. chain ID `10` -> `optimistic-ethereum`). Cache this platform mapping on first use.

2. **CryptoCompare coin list**: Download `GET /data/all/coinlist` (~5500 coins) and cache it. This list includes `SmartContractAddress` and `BuiltOn` fields for many tokens. Build a reverse index from contract address -> CryptoCompare symbol. Coverage is incomplete but good for major tokens.

3. **Binance pair validation**: Try `{SYMBOL}USDT` against the `GET /api/v3/exchangeInfo` endpoint to confirm the pair exists. Cache the exchange info response.

4. **User confirmation**: After resolution, show the user the resolved token name, symbol, and which providers matched. If no provider could resolve the token, or if the match is ambiguous, ask the user to confirm or provide the correct mapping.

All resolved mappings are persisted with the `CryptoToken` — resolution is a one-time cost per token.

### Canonical Token Lists

As a supplement to per-token resolution, the app can pre-load the CoinGecko token list (`tokens.coingecko.com/uniswap/all.json`) which follows the Uniswap Token List standard (chain ID + contract address + symbol + name + decimals). This enables instant offline matching for well-known tokens before hitting any API.

### Built-in Token Presets

Ship a small hardcoded set of pre-resolved tokens for the primary use case so users can get started without any API calls:

| Token | Chain ID | Contract Address | CoinGecko ID | CC Symbol | Binance Pair |
|-------|----------|-----------------|--------------|-----------|--------------|
| BTC   | 0        | native          | bitcoin      | BTC       | BTCUSDT      |
| ETH   | 1        | native          | ethereum     | ETH       | ETHUSDT      |
| OP    | 10       | `0x4200000000000000000000000000000000000042` | optimism | OP | OPUSDT |
| UNI   | 1        | `0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984` | uniswap  | UNI | UNIUSDT |
| ENS   | 1        | `0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72` | ethereum-name-service | ENS | ENSUSDT |

These serve as both defaults and test fixtures for the resolution pipeline.

## Price Data Providers

### Provider Priority

1. **CoinGecko** — used only when the user has configured an API key. Best documentation, aggregated market prices, batch endpoints.
2. **CryptoCompare** — default, no API key required. Aggregated prices, 2000+ days of history, simple ticker-symbol API.
3. **Binance** — default fallback, no API key required. Exchange-specific prices (not aggregated), USDT-denominated pairs.

All three providers are queried in priority order. If the higher-priority provider fails (network error, rate limit, missing token), the system falls through to the next provider automatically.

### API Key Storage

The CoinGecko API key is stored in the iOS/macOS Keychain with `kSecAttrSynchronizable: true`, which syncs it across all devices signed into the same iCloud account. This provides both security (encrypted at rest, access-controlled) and convenience (configure once, available everywhere).

The existing `CookieKeychain` (`Backends/Remote/Auth/CookieKeychain.swift`) already wraps the Security framework for keychain CRUD. It currently stores cookie Data blobs without iCloud sync. Rather than creating a new keychain wrapper, generalize `CookieKeychain` into a `KeychainStore` that supports:

- **String values** (for API keys) in addition to Data blobs (for cookies).
- **Optional iCloud sync** via `kSecAttrSynchronizable: true` (API keys sync; cookies remain device-local).

The existing `KeychainError` enum and query-building patterns are reused. Cookie storage callers (`RemoteAuthProvider`, `ProfileSession`) update to use the new name but behavior is unchanged.

The CoinGecko API key uses service `"com.moolah.api-keys"` and account `"coingecko"`, with sync enabled.

### Provider Protocol

```swift
protocol CryptoPriceClient: Sendable {
    /// Fetch the daily closing price for a token in USD on a specific date.
    func dailyPrice(for token: CryptoToken, on date: Date) async throws -> Decimal

    /// Fetch daily closing prices for a token in USD over a date range.
    /// Returns prices for each available trading day in the range.
    func dailyPrices(for token: CryptoToken, in range: ClosedRange<Date>) async throws -> [Date: Decimal]

    /// Fetch current prices for multiple tokens in a single request (where supported).
    func currentPrices(for tokens: [CryptoToken]) async throws -> [CryptoToken.ID: Decimal]
}
```

All providers return prices denominated in USD. Conversion to the profile's fiat currency is handled separately (see Conversion Chain below).

### CoinGecko Client

- **Current prices (batch)**: `GET /simple/price?ids={id1},{id2},...&vs_currencies=usd` — all tokens in one call.
- **Historical daily**: `GET /coins/{id}/market_chart?vs_currency=usd&days={n}&interval=daily` — per token.
- **By contract (batch)**: `GET /simple/token_price/{platform_id}?contract_addresses={addr1},{addr2},...&vs_currencies=usd` — for tokens on the same chain.
- **Rate limits**: Free tier with key: 30 req/min, 10k credits/month.

### CryptoCompare Client

- **Current prices (batch)**: `GET /data/pricemulti?fsyms={sym1},{sym2},...&tsyms=USD` — all tokens in one call.
- **Historical daily**: `GET /data/v2/histoday?fsym={sym}&tsym=USD&limit={days}` — returns OHLCV, we use the `close` field. Max 2000 days per request.
- **Rate limits**: No key required. Older documentation cited ~250k calls per IP (likely tracked server-side by IP address, not truly "lifetime"). Current limits are poorly documented post-CoinDesk rebrand. At ~5-10 calls/day this is not a practical concern, and Binance provides automatic fallback.

### Binance Client

- **Historical daily klines**: `GET /api/v3/klines?symbol={sym}USDT&interval=1d&limit=1000` — returns OHLCV arrays. Max 1000 candles per request; paginate with `startTime` for more.
- **No batch endpoint** — one call per symbol.
- **Rate limits**: No key required. 6000 weight/minute by IP.
- **USDT denomination**: All Binance prices are in USDT, not USD. See Stablecoin Handling below.

### Stablecoin Handling

Binance returns prices denominated in USDT (Tether), not USD. USDT usually trades within ~0.1% of USD but can deviate during market stress.

**Approach**: Use the actual USDT/USD rate when available from CryptoCompare or CoinGecko. Fall back to 1:1 only if no rate data can be obtained. Apply the same treatment to USDC.

```
Binance price (TOKEN/USDT) * USDT/USD rate = TOKEN price in USD
```

The USDT/USD and USDC/USD rates are cached alongside other crypto prices and refreshed daily.

## Storage

### Cache Structure

One gzip-compressed JSON file per token, stored in the caches directory alongside exchange rate caches:

```
<cachesDirectory>/crypto-prices/
    prices-1-native.json.gz        // filename derived from token ID (chainId-address)
    prices-10-0x4200...0042.json.gz
    prices-0-native.json.gz
    ...
    coingecko-platforms.json   // cached chain ID -> platform slug mapping
    cryptocompare-coinlist.json.gz  // cached CryptoCompare coin list
    binance-exchangeinfo.json.gz   // cached Binance exchange info
```

Using `cachesDirectory` means the OS can purge under storage pressure, and the data is re-fetched transparently on next access — same as exchange rates.

### Price Cache Schema

```json
{
    "tokenId": "1:native",
    "symbol": "ETH",
    "earliestDate": "2020-01-01",
    "latestDate": "2026-04-11",
    "prices": {
        "2026-04-11": 1623.45,
        "2026-04-10": 1598.20,
        ...
    }
}
```

Prices are stored as `Decimal` (serialized as number). Each entry is the daily closing price in USD.

### Size Estimates

At one `Decimal` per day (~15 bytes as JSON), a single token with 5 years of daily data is ~27 KB uncompressed, ~5 KB gzipped. Even with 50 tokens, total storage is under 250 KB compressed. Year-based sharding is unnecessary at this scale.

### Token Registry

The token registry is **user-configured data**, not cache — it contains tokens the user explicitly added and confirmed. It must survive OS cache purges and sync across devices.

**Storage**: The registry is always persisted via CloudKit (NSUbiquitousKeyValueStore or a CloudKit record), independent of the profile's backend type. This provides automatic cross-device sync for all users with iCloud enabled.

If iCloud data isn't available on a device (e.g. not signed in, sync disabled), the registry starts empty and the user re-adds/re-verifies tokens on that device. This is an acceptable tradeoff since it's a rare edge case and the built-in presets cover the most common tokens without verification.

```swift
protocol CryptoTokenRepository: Sendable {
    func loadTokens() async throws -> [CryptoToken]
    func saveTokens(_ tokens: [CryptoToken]) async throws
}
```

The production implementation uses CloudKit. Tests use an in-memory implementation.

## Core Service

### CryptoPriceService

An `actor` that owns token resolution, price fetching, caching, and provider fallback logic.

```swift
actor CryptoPriceService {
    // --- Token Management ---

    /// Resolve a token from contract address + chain ID.
    /// Queries CoinGecko, CryptoCompare, and Binance to populate provider mappings.
    /// Returns the resolved token for user confirmation.
    func resolveToken(chainId: Int, contractAddress: String?) async throws -> CryptoToken

    /// Register a confirmed token (after user approval of resolution).
    func registerToken(_ token: CryptoToken) async

    /// All registered tokens.
    func registeredTokens() async -> [CryptoToken]

    /// Remove a token and its cached price data.
    func removeToken(_ token: CryptoToken) async

    // --- Price Lookups ---

    /// Get the USD price of a token on a given date.
    /// Checks cache first, fetches from providers in priority order if missing.
    /// Falls back to nearest prior cached date if all providers fail.
    func price(for token: CryptoToken, on date: Date) async throws -> Decimal

    /// Get USD prices for a token over a date range.
    /// Fetches only the missing segments from providers.
    func prices(for token: CryptoToken, in range: ClosedRange<Date>) async throws -> [Date: Decimal]

    /// Get current USD prices for all registered tokens.
    /// Uses batch endpoints where available.
    func currentPrices() async throws -> [CryptoToken.ID: Decimal]

    /// Prefetch latest prices for all registered tokens.
    /// Called on app launch / profile switch.
    func prefetchLatest() async
}
```

### Internal Flow

**Price lookup (single date):**

1. Check in-memory cache for the token + date.
2. If not in memory, load the token's gzip cache file (lazy, one-time per token per session).
3. If cached, return immediately.
4. If missing, try providers in priority order (CoinGecko if configured -> CryptoCompare -> Binance).
5. On success: merge into cache, persist to gzip file, return.
6. On failure from all providers: fall back to the most recent cached date **on or before** the requested date (same weekday/weekend logic as exchange rates — never look forward).
7. If no cached data exists at all, throw.

**Price lookup (date range):**

1. Load cache file for the token.
2. Identify gaps in the requested range vs cached data.
3. Fetch only the missing segments from providers (avoid re-fetching cached data).
4. For large ranges, chunk requests to respect provider limits (CryptoCompare: 2000 days, Binance: 1000 candles).
5. Merge and persist.
6. On partial network failure, return whatever is cached.

**Provider fallback:**

For each fetch attempt, try providers in order. A provider is skipped if:
- It requires an API key that isn't configured (CoinGecko without key).
- The token has no mapping for that provider (`cryptocompareSymbol` is nil).
- The provider returns an error or empty data.

Move to the next provider silently. Only throw if all eligible providers fail.

**Prefetch (on launch):**

1. Load the token registry.
2. For each registered token, check if the price cache is stale (latestDate before today).
3. Batch-fetch current prices using `currentPrices()` (single call for CoinGecko/CryptoCompare).
4. Persist updated caches.

**Rate limiting for bulk operations:**

When the user adds many tokens or requests historical data for many tokens at once, queue requests with a throttle to stay within provider rate limits. Show progress to the user during bulk operations.

## Conversion Chain

### Multi-Hop Conversion

Converting a crypto token to the profile's fiat currency requires composing crypto prices (TOKEN -> USD) with fiat exchange rates (USD -> target fiat).

**Standard path**: `TOKEN -> USD -> {profile currency}`
- Step 1: `CryptoPriceService.price(for: token, on: date)` gives TOKEN/USD
- Step 2: `ExchangeRateService.rate(from: .USD, to: profileCurrency, on: date)` gives USD/target

**Binance USDT path**: `TOKEN -> USDT -> USD -> {profile currency}`
- Step 1: Binance gives TOKEN/USDT
- Step 2: CryptoPriceService provides USDT/USD rate (from CryptoCompare/CoinGecko, or 1:1 fallback)
- Step 3: ExchangeRateService gives USD/target

This is handled inside `CryptoPriceService` — all prices are normalized to USD before being returned, so callers never see the USDT intermediary step.

### PriceConversionService

Sits above both `CryptoPriceService` and `ExchangeRateService`, composing them for end-to-end conversions.

```swift
actor PriceConversionService {
    private let cryptoPrices: CryptoPriceService
    private let exchangeRates: ExchangeRateService

    /// Convert a quantity of a crypto token to a fiat MonetaryAmount on a given date.
    /// Composes: token -> USD (crypto) then USD -> fiat (exchange rates).
    func convert(
        amount: Decimal,
        token: CryptoToken,
        to currency: Currency,
        on date: Date
    ) async throws -> MonetaryAmount

    /// Get the fiat value of one unit of a token on a given date.
    func unitPrice(
        for token: CryptoToken,
        in currency: Currency,
        on date: Date
    ) async throws -> Decimal

    /// Get fiat values for one unit of a token over a date range (for charts).
    func priceHistory(
        for token: CryptoToken,
        in currency: Currency,
        over range: ClosedRange<Date>
    ) async throws -> [(date: Date, price: Decimal)]
}
```

### Same-Currency Short-Circuit

If the profile currency is USD, skip the exchange rate lookup entirely (rate = 1.0).

## Integration Points

### ProfileSession

Like `ExchangeRateService`, the crypto price services are independent of the backend (same prices whether using Remote, CloudKit, or InMemory). They live on `ProfileSession`:

```swift
@Observable @MainActor
final class ProfileSession: Identifiable {
    // ... existing stores ...
    let exchangeRateService: ExchangeRateService
    let cryptoPriceService: CryptoPriceService
    let priceConversionService: PriceConversionService
}
```

Created when the profile session is constructed. All stores and views access them through the session.

### Settings UI

A settings section for crypto price configuration:

- **Registered tokens**: List of tokens the user has added, with name, symbol, chain, and which providers are available.
- **Add token**: Input for contract address + chain selector. Shows resolution results for confirmation.
- **CoinGecko API key**: Optional text field. Stored in synced Keychain. When provided, enables CoinGecko as the highest-priority provider.
- **Remove token**: Swipe-to-delete or edit mode, removes the token and its cached data.

### Future Use (out of scope for this design)

- Crypto portfolio tracking (holdings, P&L).
- Real-time or intraday prices.
- Price alerts.
- DEX/on-chain price sources (Uniswap TWAP oracles, etc.).

## Testing

### Test Clients

Inject fixed-rate clients conforming to `CryptoPriceClient` for testing. `CryptoPriceService` takes its clients via init.

```swift
struct FixedCryptoPriceClient: CryptoPriceClient, Sendable {
    let prices: [String: [Date: Decimal]]  // token ID -> date -> price
}
```

### Token Resolution Tests

- Resolve a known token by contract address + chain ID via mock CoinGecko response.
- Resolve a token present in CryptoCompare coin list but not CoinGecko.
- Handle ambiguous resolution (same symbol, different tokens) — verify user confirmation is requested.
- Native token resolution (ETH, BTC — nil contract address).

### Price Fetching Tests

- Cache hit returns price without network call.
- Cache miss triggers provider fetch in priority order.
- Provider fallback: CoinGecko fails -> CryptoCompare succeeds.
- Provider fallback: CryptoCompare fails -> Binance succeeds.
- All providers fail -> falls back to nearest prior cached date.
- All providers fail with empty cache -> throws.
- Date range fetch only requests missing segments.
- Binance USDT prices are converted to USD using the USDT/USD rate.
- USDT/USD rate unavailable -> falls back to 1:1.
- Stablecoin prices (USDT, USDC) use actual rates when available.
- Concurrent requests for the same token don't trigger duplicate fetches.

### Conversion Tests

- TOKEN -> USD -> AUD conversion multiplies correctly.
- Same-currency (USD profile) short-circuits without exchange rate lookup.
- Missing crypto price throws (does not silently return zero).
- Missing exchange rate throws (does not silently return zero).
- Date range conversion returns correct values for each day.

### Cache Persistence Tests

- Gzip round-trip: write cache, read back, verify integrity.
- Prefetch updates latestDate and only fetches the delta.
- Cache file missing (OS purge) triggers transparent re-fetch.
- Token registry round-trip: register, persist, reload, verify.

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| CryptoCompare free tier limits unclear post-rebrand | Binance fallback requires no key. CoinGecko available as opt-in. Monitor for deprecation. |
| CoinGecko free tier rate limits (30/min) during bulk history load | Throttle/queue requests. Show progress. Spread across providers. |
| Ticker symbol collision across providers | Contract address + chain ID is the primary identity. Provider mappings are validated at resolution time, confirmed by user. |
| Scam tokens with duplicate tickers | Never trust ticker alone. Always resolve from contract address. User confirmation step catches mismatches. |
| USDT depegs from USD | Use actual USDT/USD rate when available. Only fall back to 1:1 if rate data is unavailable. |
| Provider API changes | Each provider is isolated behind `CryptoPriceClient` protocol. One place to update per provider. |
| Large number of tokens exhausts rate limits | Batch endpoints where available (CoinGecko, CryptoCompare). Throttle individual requests. Cache aggressively — historical data never changes. |
| OS purges cache directory | Graceful re-fetch on next access. Historical crypto prices are immutable so re-fetching is safe. |
| No price data for obscure tokens | Some tokens may only be on one provider or none. Surface this clearly during token registration. |

## What This Plan Does NOT Cover

- Crypto portfolio tracking or holdings management.
- Real-time or intraday prices.
- Price alerts or notifications.
- DEX/on-chain price sources.
- UI for displaying crypto valuations (separate design).
- Integration with account/transaction models for crypto holdings.
