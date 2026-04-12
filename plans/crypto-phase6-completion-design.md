# Crypto Price Data — Phase 6 Completion Design

**Date:** 2026-04-12

Completes the remaining Phase 6 work from `crypto-price-data-design.md`. The core price infrastructure (provider clients, CryptoPriceService, PriceConversionService, gzip caching, ProfileSession wiring) is already merged. This spec covers token persistence, resolution, settings UI, and loose ends.

---

## 1. Token Repository & Persistence

### Protocol

`Domain/Repositories/CryptoTokenRepository.swift`:

```swift
protocol CryptoTokenRepository: Sendable {
    func loadTokens() async throws -> [CryptoToken]
    func saveTokens(_ tokens: [CryptoToken]) async throws
}
```

### Production: ICloudTokenRepository

Backed by `NSUbiquitousKeyValueStore`. Serializes the token array as JSON under the key `"crypto-tokens"`.

- On `loadTokens()`: read and decode. Return empty array if key is absent.
- On `saveTokens()`: encode and write.
- Observes `NSUbiquitousKeyValueStoreDidChangeExternallyNotification` to pick up cross-device sync changes.
- Size budget: ~300 bytes/token. 1,000 tokens ≈ 300 KB, well within the 1 MB limit.

### Test: InMemoryTokenRepository

Simple in-memory array. Used by `TestBackend` and all service/store tests.

### Integration

The repository is independent of `BackendProvider` (same tokens regardless of Remote/CloudKit backend). It is owned by `CryptoPriceService`, which loads the registry on first access and persists after any mutation (register/remove).

---

## 2. Token Resolution Pipeline

Resolution populates provider-specific fields on a `CryptoToken` from a contract address + chain ID. Three providers, tried in order:

### 2a. CoinGecko Contract Lookup (API key required)

- Map chain ID to CoinGecko platform slug via `GET /asset_platforms`. Cache the mapping; refresh if older than 7 days (serve stale, refresh in background).
- Look up token: `GET /coins/{platform_id}/contract/{contract_address}`. Populates `coingeckoId`, `symbol`, `name`, `decimals`.
- Skipped entirely if no CoinGecko API key is configured.

### 2b. CryptoCompare Coin List

- Download and cache `GET /data/all/coinlist` (~5,500 coins). Refresh weekly (stale-while-revalidate).
- Build a reverse index from lowercase contract address → CryptoCompare symbol.
- Populates `cryptocompareSymbol`.
- Coverage is incomplete but good for major tokens.

### 2c. Binance Pair Validation

- Cache `GET /api/v3/exchangeInfo`. Refresh weekly.
- Try `{SYMBOL}USDT` against the cached pairs. Populates `binanceSymbol` if the pair exists.

### Native Token Handling

Native tokens (nil contract address) skip contract lookup. Disambiguation rules to avoid confusion with scam ERC20s named "ETH"/"BTC":

- **Built-in presets** (BTC, ETH, OP, UNI, ENS) have hardcoded provider mappings. No resolution needed.
- **User-added native tokens**: the add-token UI requires the user to explicitly mark "native/layer-1 token". Then:
  - CoinGecko: look up by CoinGecko ID or name search (not symbol), verify it's flagged as a native asset.
  - CryptoCompare: match entries with no `SmartContractAddress` field.
  - Binance: match the canonical pair directly.
- **Confirmation step** always shows the full resolved name and chain so the user can catch mismatches.

### Resolution Methods on CryptoPriceService

```swift
func resolveToken(chainId: Int, contractAddress: String?, isNative: Bool) async throws -> CryptoToken
func registerToken(_ token: CryptoToken) async throws
func registeredTokens() async -> [CryptoToken]
func removeToken(_ token: CryptoToken) async throws
```

Each provider client gets a concrete resolution method (not part of `CryptoPriceClient` — resolution is a one-time operation, not a price query).

---

## 3. Settings UI

### macOS — Tabbed Settings Window

A `Settings` scene using SwiftUI's `TabView` to get the macOS toolbar-tab look (like Mail.app):

- **Profiles** tab — migrates existing profile/settings content.
- **Crypto** tab — token management + API key.

### iOS — Navigation Row

A "Crypto Tokens" row in the existing settings list that pushes to the crypto management screen. Same content as the macOS Crypto tab, in a navigation-stack layout.

### Crypto Tab/Screen Content

**Token List:**
- Each row: token symbol, name, chain name, which providers resolved (small indicators).
- Swipe-to-delete on iOS, Delete key / context menu on macOS.
- "+" button opens the Add Token sheet.

**CoinGecko API Key Section:**
- `SecureField` for the API key, stored via `KeychainStore` with iCloud sync.
- Status: "Not configured" / "Configured" (with a clear button).

### Add Token Sheet

Multi-step flow in a single sheet:

1. **Input** — Contract address text field + chain picker (Ethereum, Optimism, Bitcoin, etc.). Toggle for "Native token (no contract address)" which hides the contract address field.
2. **Resolving** — Progress indicator while querying providers in sequence.
3. **Results** — Resolved token name, symbol, decimals, matched providers. Warning if no providers matched. User taps "Add" to confirm or "Cancel" to abort.

### UI Review

The `ui-review` agent is invoked after every UI component is created. Issues are fixed and re-reviewed until clean.

---

## 4. USDT/USD Rate Fix

The current `BinanceClient` takes a static `usdtUsdRate` constructor param (defaults to 1.0). This needs to be date-aware.

**Change:** `BinanceClient` accepts a closure/function `(Date) async -> Decimal?` that looks up the USDT/USD rate for a given date. When converting TOKEN/USDT klines to USD, it calls this function with each kline's date. If the rate isn't available for that date, falls back to 1.0.

`CryptoPriceService` provides this function — it looks up USDT as a token in its own cache (CoinGecko ID "tether"). On prefetch, USDT is fetched alongside registered tokens automatically.

---

## 5. CoinGecko Provider Activation

`ProfileSession` currently wires `[CryptoCompareClient, BinanceClient]` into `CryptoPriceService`. With the API key now configurable:

- On profile session init, check `KeychainStore` for a CoinGecko API key.
- If present, prepend `CoinGeckoClient` to the provider list (highest priority per the original design).
- If the key is added/removed later via settings, the provider list updates on next session init (no hot-reload needed — changing an API key is rare).

---

## 6. Testing

### Token Repository Tests
- Round-trip: save tokens → load tokens → verify integrity.
- Empty registry returns empty array.
- Save overwrites previous list entirely.
- `InMemoryTokenRepository` used in all service/store tests.

### Token Resolution Tests
- Resolve known ERC-20 by contract address + chain ID via mock CoinGecko response.
- Resolve token present in CryptoCompare coin list but not CoinGecko.
- Binance pair validation confirms/rejects a symbol.
- Native token resolution uses correct matching (no contract address confusion with ERC20s).
- No providers match — returns partial token with empty provider fields.
- CoinGecko skipped when no API key configured.
- Cached coin list used when fresh (< 7 days), re-fetched when stale.

### USDT/USD Rate Tests
- Binance prices converted using date-specific USDT/USD rate.
- Rate unavailable for date falls back to 1.0.
- USDT rate fetched as part of prefetch cycle.

### Settings UI
- UI review agent validates all new views against `STYLE_GUIDE.md` and Apple HIG after each is created. Review/fix cycle repeats until clean.

---

## What This Spec Does NOT Cover

- Crypto portfolio tracking, holdings management, or account integration.
- UI for displaying crypto valuations in transaction/account views.
- Real-time or intraday prices.
- Price alerts.
- DEX/on-chain price sources.
