# Instrument Registry UI — Design

> Resolves [#461](https://github.com/ajsutton/moolah-native/issues/461). Builds on the backend foundation in
> [`plans/completed/2026-04-24-instrument-registry-design.md`](completed/2026-04-24-instrument-registry-design.md). The CSV-import counterpart is tracked separately in [#515](https://github.com/ajsutton/moolah-native/issues/515).

## 1. Goal

Take the instrument-registry backend (registry repository, search service, token-resolution client) and turn it into a usable UI: a single instrument picker that handles fiat / stock / crypto end-to-end, a redesigned crypto-token "Add" flow, and a sync bridge so remote registrations show up locally without restart.

## 2. Background

The registry-UI scaffolding (`InstrumentPickerField`, `InstrumentPickerSheet`, `InstrumentPickerStore`) shipped earlier and is wired into every form that picks an instrument:

| Form | File | Today |
|---|---|---|
| CloudKit profile creation | `Features/Profiles/Views/ProfileFormView.swift` | `kinds: [.fiatCurrency]` |
| Moolah profile detail (3 fields) | `Features/Settings/MoolahProfileDetailView.swift` | `kinds: [.fiatCurrency]` |
| Account create / edit | `Features/Accounts/Views/CreateAccountView.swift`, `EditAccountView.swift` | `kinds: [.fiatCurrency]` |
| Earmark create / edit | `Features/Earmarks/Views/CreateEarmarkSheet.swift`, `EditEarmarkSheet.swift` | `kinds: [.fiatCurrency]` |
| Transaction leg | `Features/Transactions/Views/Detail/TransactionDetailLegRow.swift` | `kinds: Set(Instrument.Kind.allCases)` |

Today the picker store handles fiat (ambient) and stock (validate-via-price-probe → `registerStock`) but bails on unregistered crypto and hard-codes `providerSources: .stocksOnly` to defend against scam tokens surfaced by free-form CoinGecko search. Crypto registration only happens via `Features/Settings/AddTokenSheet.swift` — a contract-address form that asks the user to choose a chain and paste an address.

Three other gaps remain:

- `InstrumentRegistryRepository.observeChanges()` fires on local writes only. Remote pulls land in `ProfileDataSyncHandler+BatchUpsert.swift` and bypass the registry's fan-out, so a token registered on another device doesn't refresh the picker on this one.
- `ensureInstrument` (called by CSV import via `CloudKitTransactionRepository`/`CloudKitAccountRepository`) silently inserts unmapped crypto `InstrumentRecord` rows, producing the `ConversionError.noProviderMapping` that the design doc §1.6 calls out.
- Stock "search" is exact-ticker-only — there is no name-based lookup ("Apple" → `AAPL`).

## 3. Design decisions (cross-reference)

| # | Decision | Rationale |
|---|---|---|
| D1 | "Add Token" becomes search-only; the contract-address form is removed | Pricing depends on having a known mapping from a known provider — there is no path to price an arbitrary contract |
| D2 | Crypto search is powered by a cached snapshot of CoinGecko `/coins/list?include_platform=true` | Free endpoint (no API key), instant in-app search, hands `(chain, contract)` directly to `resolve()` |
| D3 | Snapshot lives in a dedicated SQLite database with FTS5 indexing | Pages in only what's needed; ~0 MiB resident when picker is closed; <5 ms FTS query vs ~8 ms linear over 17.5k entries; no ORM ceremony |
| D4 | No DB migration framework: schema bumps drop the file and redownload | Catalog is rebuildable; migration framework is overkill |
| D5 | `/asset_platforms` (chain-slug → numeric chain ID map) lives in the same DB | Single file, single refresh transaction |
| D6 | Refresh policy: never block on download, 24 h max-age, ETag conditional GET, no manual button, silent failure | Pickers stay responsive; bandwidth is preserved when CoinGecko's CDN serves a stable ETag; users don't need to be told about a transient catalogue refresh failure |
| D7 | "Resolve mapping" affordance is dropped; unmapped state is prevented at the boundary | `ensureInstrument` will throw on unmapped crypto, forcing CSV import (and any other caller) to register through the picker → resolve flow. Recovery UX for pre-existing rows and CSV imports is deferred to #515 |
| D8 | Stock search uses Yahoo `/v1/finance/search?quotesCount=20`, filtered to `EQUITY ∪ ETF ∪ MUTUALFUND`; no post-select validation | Yahoo is already our price source; per-keystroke search is the only realistic shape (no bulk endpoint at this scale); skipping validation removes a redundant probe — the next price fetch is the real test |
| D9 | Remote-change fan-out: `ProfileDataSyncHandler` accepts an `onInstrumentRemoteChange: @Sendable () -> Void` closure, fired once per sync transaction that touched any `InstrumentRecord` row (insert / update / delete / mapping-field change) | Mirrors the existing `onRecordChanged` / `onRecordDeleted` closure pattern, avoids cyclic deps between sync and registry, naturally testable |
| D10 | The transaction-leg picker drops `providerSources: .stocksOnly` and gains crypto registration in `select(_:)` | With catalog-backed search the scam-token risk goes away; users can record a position leg in any kind without bouncing to Settings → Crypto |

## 4. Component map

### 4.1 `CoinGeckoCatalog` — new

**Location:** `Shared/Catalog/CoinGeckoCatalog.swift` (+ supporting files in same directory).

A `@MainActor`-confined facade plus an actor-isolated SQLite connection. Public surface:

```swift
struct CatalogEntry: Sendable, Hashable {
  let coingeckoId: String
  let symbol: String
  let name: String
  let platforms: [PlatformBinding]   // ordered by canonical-platform priority
}

struct PlatformBinding: Sendable, Hashable {
  let slug: String                   // e.g. "ethereum", "polygon-pos"
  let chainId: Int?                  // nil if slug not in /asset_platforms or unsupported
  let contractAddress: String        // already lowercased
}

protocol CoinGeckoCatalog: Sendable {
  /// Returns up to `limit` entries with their full platform list attached so
  /// the picker's `select(_:)` has everything it needs to call `resolve()`.
  func search(query: String, limit: Int) async -> [CatalogEntry]
  /// Triggered once per app session; never blocks the caller.
  func refreshIfStale() async
}
```

The concrete implementation:

- Owns one SQLite connection backed by `Application Support/InstrumentRegistry/catalog.sqlite`.
- Initialises schema on first open, recreates the file when `meta.schema_version` doesn't match `CatalogSchema.version`.
- Provides `search(query:limit:)` via FTS5 (see §6).
- Triggers `refreshIfStale()` once per session (called from `ProfileSession` startup), which: reads `meta.last_fetched` + `meta.coins_etag` + `meta.platforms_etag`, kicks off two parallel HTTP requests with `If-None-Match`, parses the response if `200`, replaces all rows in a single transaction, updates the `meta` row.

Refresh is fire-and-forget on a background `Task`. Failures are logged with `os_log` only.

### 4.2 `InstrumentSearchService` — modified

**Location:** `Shared/InstrumentSearchService.swift`.

- Add a `catalog: CoinGeckoCatalog` dependency, replacing `CryptoSearchClient` on the crypto path.
- Add a `stockSearchClient: any StockSearchClient` dependency (new protocol — see §4.3).
- Keep `resolutionClient` and `stockValidator` (validator still has callers outside the picker).
- The `search(query:kinds:providerSources:)` method:
  - Fiat: unchanged (matches against `Locale.Currency.isoCurrencies`).
  - Crypto (`kinds.contains(.cryptoToken)`): query catalog, return up to `limit` `InstrumentSearchResult`s with `requiresResolution: true` and `cryptoMapping: nil`. The `instrument.id` is built from the catalog entry's first usable platform (`<chainId>:<contractAddress>` or `<chainId>:native` when no platforms exist), so duplicates against registered rows can be detected.
  - Stock (`kinds.contains(.stock)`): call `stockSearchClient.search(query:)`; map hits to `InstrumentSearchResult` with `requiresResolution: false` (Yahoo's search is itself the validator).
- Drop the `providerSources` parameter — every call site can now safely surface every kind.

### 4.3 `StockSearchClient` — new protocol

**Location:** `Domain/Repositories/StockSearchClient.swift`, with a Yahoo implementation in `Backends/YahooFinance/YahooFinanceStockSearchClient.swift`.

```swift
struct StockSearchHit: Sendable, Hashable {
  let symbol: String          // Yahoo ticker, e.g. "AAPL", "BHP.AX"
  let name: String            // shortname or longname, whichever is non-empty, trimmed
  let exchange: String        // e.g. "NMS", "ASX"
  let quoteType: QuoteType    // EQUITY | ETF | MUTUALFUND
}

enum QuoteType: String, Sendable, Hashable {
  case equity      = "EQUITY"
  case etf         = "ETF"
  case mutualFund  = "MUTUALFUND"
}

protocol StockSearchClient: Sendable {
  func search(query: String) async throws -> [StockSearchHit]
}
```

`YahooFinanceStockSearchClient.search` calls `https://query1.finance.yahoo.com/v1/finance/search?q=<q>&quotesCount=20&newsCount=0` and discards anything outside the three accepted `quoteType`s.

### 4.4 `InstrumentPickerStore` — modified

**Location:** `Shared/InstrumentPickerStore.swift`.

Two changes:

1. **Stop suppressing crypto.** Remove the `.stocksOnly` provider gate; the search service is the source of truth for what to show.
2. **Register crypto on selection.** Extend `select(_:) async -> Instrument?`:
   - If the selected result is registered (`isRegistered == true`): return its `Instrument` immediately (existing behaviour).
   - If the selected result is unregistered crypto (`requiresResolution == true`, kind `.cryptoToken`):
     - Set `isResolving = true`, clear `error`.
     - Call `resolutionClient.resolve(chainId:contractAddress:symbol:isNative:)` with the catalog entry's chain/contract (or `isNative: true` and the symbol if there are no platforms).
     - Build a `CryptoProviderMapping` from the result. Refuse to register if all three provider IDs are still nil — surface "Could not find a price source for this token" as `error` and return `nil`.
     - Build an `Instrument` from the catalog entry plus resolved decimals.
     - `await registry.registerCrypto(instrument, mapping: mapping)`; on success, return the instrument.
   - If the selected result is unregistered stock: existing path (`registry.registerStock(instrument)`); continue to skip post-select validation.

### 4.5 "Add Token" flow — rewritten

**Location:** `Features/Settings/AddTokenSheet.swift` (rewrite), supporting wiring in `Features/Settings/CryptoSettingsView.swift`.

The new `AddTokenSheet` is a thin wrapper around an `InstrumentPickerSheet` configured with `kinds: [.cryptoToken]`. On dismiss with a non-nil `Instrument`, the sheet invokes `store.loadRegistrations()` to refresh the displayed list.

The contract-address form, chain enum, native/contract toggle, and the `CryptoTokenStore.resolveToken` / `confirmRegistration` orchestration go away. `CryptoTokenStore` keeps its loader, remover, and API-key methods.

### 4.6 `CloudKitInstrumentRegistryRepository.notifyExternalChange()` — new

**Location:** `Backends/CloudKit/Repositories/CloudKitInstrumentRegistryRepository.swift`.

```swift
@MainActor
func notifyExternalChange() {
  for continuation in subscribers.values { continuation.yield() }
}
```

Concrete-class only. The protocol stays clean: `notifyExternalChange()` is plumbing, not part of the read/write contract.

### 4.7 `ProfileDataSyncHandler` — modified

**Locations:** `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift` (+ `+BatchUpsert.swift`, `+QueueAndDelete.swift`, `+ApplyRemoteChanges.swift` as needed).

- Add an `onInstrumentRemoteChange: @Sendable () -> Void` constructor parameter (default `{ }`).
- In `batchUpsertInstruments`: track whether *any* `InstrumentRecord` row was inserted, updated, or had a mapping-field change. If so, after the transaction commits, call `onInstrumentRemoteChange()` exactly once.
- In the deletion path: if any deleted record is an `InstrumentRecord`, call `onInstrumentRemoteChange()` once after the deletions commit.
- In `ProfileSession+Factories.makeBackend`, after constructing the registry:
  ```swift
  onInstrumentRemoteChange: { [registry] in
    Task { @MainActor in registry.notifyExternalChange() }
  }
  ```

Subscribers re-fetch via `all()` / `allCryptoRegistrations()` on every yield; the `Void` payload is a signal, not a diff. We do not coalesce — first batch and a follow-up local write produce two yields, which is fine.

### 4.8 `ensureInstrument` tightening

**Locations:** `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift:55`, `CloudKitAccountRepository.swift:188`.

The crypto path of `ensureInstrument`:

- If a row already exists in `InstrumentRecord` and it has at least one of `coingeckoId` / `cryptocompareSymbol` / `binanceSymbol` populated, it is treated as registered — proceed.
- Otherwise (no row, or row exists with all three mapping fields nil) → throw a new `RepositoryError.unmappedCryptoInstrument(instrumentId:)`.

Fiat continues to be ambient — `ensureInstrument` is a no-op-with-cache for `kind == .fiatCurrency`. Stocks are out of scope for this plan: the existing CSV parsers do not produce unmapped stock rows in the same way the crypto path does, and tightening the stock precondition without a clear motivating failure would risk regressing imports. If a real gap surfaces it gets its own follow-up.

After this lands, CSV imports of unknown tokens will fail noisily and the import store is expected to surface that failure as a hard import error. The user-facing recovery UX is the subject of #515.

## 5. Data flow scenarios

### 5.1 User registers crypto via Settings → Crypto → Add Token

1. User taps Add Token. `AddTokenSheet` opens an `InstrumentPickerSheet` with `kinds: [.cryptoToken]`.
2. User types `pepe`. Picker store debounces 250 ms, then calls `searchService.search(query:"pepe", kinds:[.cryptoToken])`.
3. Search service queries `coinGeckoCatalog.search(query:"pepe", limit: …)`. FTS5 returns the matching rows (BM25-ranked, capped). Service maps them to `InstrumentSearchResult` (`requiresResolution: true`).
4. Picker shows results grouped under a "Crypto" section.
5. User selects "Pepe (PEPE)". `InstrumentPickerStore.select(_:)` calls `resolutionClient.resolve(chainId: 1, contractAddress: "0x6982…", symbol: "pepe", isNative: false)`.
6. Resolver hits CryptoCompare's coin list (cached) and Binance's exchange info (cached for the resolver's session) and, if a CoinGecko Pro API key is present, the contract-lookup endpoint. Result: `coingeckoId: "pepe"`, `cryptocompareSymbol: "PEPE"`, `binanceSymbol: "PEPEUSDT"` (illustrative — actual values depend on availability).
7. Picker store calls `registry.registerCrypto(instrument, mapping:)`. Registry writes both rows, fires `observeChanges()`, returns.
8. Sheet dismisses with the new `Instrument`. `CryptoTokenStore.loadRegistrations()` refreshes the list, the new row appears.

### 5.2 User registers crypto from a transaction-leg picker

Same as 5.1 except `kinds: Set(Instrument.Kind.allCases)` and the resulting `Instrument` is bound to the leg's instrument field rather than a Settings list. The user does not need to pre-register crypto from Settings to record a position — that is the UX win promised in §3 D10.

### 5.3 Another device registers a token; this device's picker reflects it

1. User on Mac runs flow 5.1; CKSyncEngine queues the new `InstrumentRecord` for upload.
2. iPhone in the user's pocket receives a push, runs an incremental sync.
3. `ProfileDataSyncHandler.batchUpsertInstruments` upserts the row. The transaction commits; the handler calls `onInstrumentRemoteChange()`.
4. The closure dispatches onto MainActor and calls `registry.notifyExternalChange()`, which yields `Void` to every active subscriber.
5. Any open picker re-runs `loadRegistrations()` (or equivalent) and the new token appears without a tab switch or app relaunch.

### 5.4 Catalogue refresh

1. App launch: `ProfileSession` (CloudKit-backed only) calls `coinGeckoCatalog.refreshIfStale()`.
2. Catalog reads `meta.last_fetched`. If `< 24h` ago, returns immediately.
3. Otherwise, opens two parallel `URLSession.data(for:)` requests:
   - `GET https://api.coingecko.com/api/v3/coins/list?include_platform=true` with `If-None-Match: <coins_etag>`.
   - `GET https://api.coingecko.com/api/v3/asset_platforms` with `If-None-Match: <platforms_etag>`.
4. For each `200 OK`: parse the JSON, run a single replace-all transaction (`DELETE … ; INSERT …` per affected table; FTS triggers keep `coin_fts` in sync). Store the new ETag and `Date()` into `meta`.
5. Either response `304 Not Modified`: leave that table's data alone, but still update `last_fetched` to suppress re-attempts for 24 h.
6. Any thrown error: `os_log` at error level; do not update `last_fetched` so a retry happens on the next launch.

### 5.5 CSV import encounters an unknown crypto token

1. Parser builds an `Instrument.crypto(chainId:contractAddress:symbol:name:decimals:)` for a row that references a token not in the registry.
2. `CloudKitTransactionRepository.ensureInstrument(_:)` (or the account variant) throws `RepositoryError.unmappedCryptoInstrument(instrumentId:)`.
3. Import pipeline aborts the offending leg(s) and surfaces the failure to the import UI as a hard error. **Recovery UX (a "Review unknown tokens" step) is the subject of [#515](https://github.com/ajsutton/moolah-native/issues/515).**

## 6. SQLite schema (catalog.sqlite)

```sql
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE meta (
  schema_version  INTEGER NOT NULL,
  last_fetched    REAL,        -- unix seconds, NULL until first successful fetch
  coins_etag      TEXT,
  platforms_etag  TEXT
);
INSERT INTO meta (schema_version) VALUES (1);

CREATE TABLE coin (
  rowid          INTEGER PRIMARY KEY,
  coingecko_id   TEXT NOT NULL UNIQUE,
  symbol         TEXT NOT NULL,
  name           TEXT NOT NULL
);

CREATE TABLE coin_platform (
  coingecko_id     TEXT NOT NULL,
  platform_slug    TEXT NOT NULL,
  contract_address TEXT NOT NULL,
  PRIMARY KEY (coingecko_id, platform_slug),
  FOREIGN KEY (coingecko_id) REFERENCES coin(coingecko_id) ON DELETE CASCADE
);

CREATE INDEX coin_platform_chain_contract
  ON coin_platform(platform_slug, contract_address);

CREATE TABLE platform (
  slug      TEXT PRIMARY KEY,
  chain_id  INTEGER,        -- nullable: not every CoinGecko platform is EVM-shaped
  name      TEXT NOT NULL
);

CREATE VIRTUAL TABLE coin_fts USING fts5(
  symbol, name,
  content='coin',
  content_rowid='rowid',
  tokenize='unicode61 remove_diacritics 1'
);

-- triggers keep coin_fts in sync with coin
CREATE TRIGGER coin_ai AFTER INSERT ON coin BEGIN
  INSERT INTO coin_fts(rowid, symbol, name) VALUES (new.rowid, new.symbol, new.name);
END;
CREATE TRIGGER coin_ad AFTER DELETE ON coin BEGIN
  INSERT INTO coin_fts(coin_fts, rowid, symbol, name) VALUES('delete', old.rowid, old.symbol, old.name);
END;
CREATE TRIGGER coin_au AFTER UPDATE ON coin BEGIN
  INSERT INTO coin_fts(coin_fts, rowid, symbol, name) VALUES('delete', old.rowid, old.symbol, old.name);
  INSERT INTO coin_fts(rowid, symbol, name) VALUES (new.rowid, new.symbol, new.name);
END;
```

**Search query (two steps so the per-platform fan-out doesn't break `LIMIT`):**

```sql
-- step 1: top-N matching coins, ranked by BM25
SELECT c.coingecko_id, c.symbol, c.name
FROM coin_fts JOIN coin c ON c.rowid = coin_fts.rowid
WHERE coin_fts MATCH ?
ORDER BY rank
LIMIT ?;

-- step 2: platforms for those coins (single round-trip, parameterised IN)
SELECT cp.coingecko_id, cp.platform_slug, cp.contract_address, p.chain_id
FROM coin_platform cp
LEFT JOIN platform p ON p.slug = cp.platform_slug
WHERE cp.coingecko_id IN (?, ?, …);
```

Caller passes the user's query as `?1` with a `*` suffix so prefix matching kicks in (`btc*` matches `BTC`, `BTCB`, …). Exact symbol hits naturally rank above tokenised name hits because BM25 weights the matched column. After step 2, results are merged in code: each `CatalogEntry` carries a `[PlatformBinding]` ordered by the priority list in §13 (ETH → Polygon → BSC → Base → Arbitrum → Optimism → Avalanche → fallback to step-2 row order). Coins with **no** platforms (CoinGecko's "platformless" entries — typically cross-chain natives) are returned with an empty `platforms` array and the picker's `select(_:)` calls `resolve()` with `isNative: true` and the coin symbol.

**Replace-all transaction (refresh):**

```sql
BEGIN IMMEDIATE;
DELETE FROM coin;            -- cascades into coin_platform; FTS triggers keep coin_fts current
INSERT INTO coin(...) VALUES (?, ?, ?), ...;  -- batched
INSERT INTO coin_platform(...) VALUES (?, ?, ?), ...;
COMMIT;
```

Asset-platform refresh uses the same shape on `platform`.

`coin.symbol` and `coin.name` are stored verbatim. FTS handles case-insensitivity; we don't store a redundant lowercased copy.

## 7. Error handling

| Path | Failure | Behaviour |
|---|---|---|
| Catalog refresh | network error / non-200 / non-304 | `os_log .error`; don't update `last_fetched`; pickers continue serving previous snapshot |
| Catalog refresh | JSON parse error | `os_log .error`; abort the replace-all transaction (snapshot unchanged); same retry semantics |
| Catalog open | corrupt SQLite file | recreate the file (drop + create fresh schema); `os_log .info` |
| Catalog search | query against empty catalog | return `[]`; pickers show empty crypto section |
| Stock search | Yahoo error | `os_log .error`; surface a transient "Search failed — try again" banner inside the picker only |
| `resolve()` | all three provider IDs `nil` | `InstrumentPickerStore` surfaces "Could not find a price source for this token" as `error`, returns `nil`. No registration is written |
| `resolve()` | network error | `InstrumentPickerStore` surfaces a generic "Couldn't reach token resolver" error; same no-write semantics |
| `registerCrypto` / `registerStock` | repository throws | propagate to picker store `error`; the row is not written; the picker remains open so the user can retry |
| `ensureInstrument` (crypto) | unmapped row | throw `RepositoryError.unmappedCryptoInstrument`; CSV-import handling is #515 |

## 8. Concurrency

- `CoinGeckoCatalog` is an actor (or `@unchecked Sendable` wrapping a serial queue); its public methods are `async`. Refresh runs on a `Task.detached(priority: .background)` so it never blocks the caller.
- `InstrumentSearchService` stays a `Sendable struct`; nothing it does is now stateful (`stockSearchClient` and `coinGeckoCatalog` are themselves Sendable).
- `InstrumentPickerStore` stays `@MainActor @Observable`. The new crypto branch in `select(_:)` does its `resolve()` call off-main (the resolver is already non-isolated) and hops back via the existing main-actor confinement of the store.
- `CloudKitInstrumentRegistryRepository.notifyExternalChange()` is `@MainActor`; the closure passed to the sync handler hops onto `MainActor` before invoking it.

All threading guidance in `guides/CONCURRENCY_GUIDE.md` continues to apply.

## 9. Testing strategy

| Surface | Tests |
|---|---|
| `CoinGeckoCatalog` | golden-snapshot tests using fixture JSON shipped under `MoolahTests/Support/Fixtures/CoinGecko/`; covers schema-version bump, ETag round-trip, replace-all transaction, FTS query, refresh failures keep prior snapshot |
| `YahooFinanceStockSearchClient` | URLProtocol-stubbed fixture against `MoolahTests/Support/Fixtures/Yahoo/search-apple.json`; covers parsing, quoteType filtering, trim of stray whitespace |
| `InstrumentSearchService` | injected fakes for catalog and stock client; covers fiat ambient, crypto-from-catalog, stock-from-search, mixed-kinds dedup against registered rows |
| `InstrumentPickerStore` | drives `select(_:)` against a fake registry + fake resolver; covers the four selection branches (registered, unregistered crypto, unregistered stock, error path with all-nil resolver result) |
| `CloudKitInstrumentRegistryRepository.notifyExternalChange()` | MainActor unit test that subscribes via `observeChanges()` and asserts a yield happens after a manual `notifyExternalChange()` call |
| `ProfileDataSyncHandler` change-fan-out | sync-handler test using `TestBackend`; runs a fake remote upsert touching an `InstrumentRecord`, asserts the `onInstrumentRemoteChange` closure fires exactly once |
| `ensureInstrument` tightening | repository contract tests; covers throw on unmapped crypto, success on mapped crypto, success on fiat |
| End-to-end picker UX | XCUITest (macOS) under `MoolahUITests_macOS`: type a stock name → register; type a crypto symbol → register; verify the new instrument shows in the post-flow form. Seeds a deterministic catalog DB for the test profile so search results are stable |

The CoinGecko / Yahoo network paths are never hit live in tests — every external call is fixture-stubbed via `URLProtocol`.

## 10. Telemetry and accessibility

- Catalog refresh outcomes are logged via `os_log` to the existing `instrument-registry` subsystem with categories `catalog.refresh` and `catalog.search`. We log the count of rows replaced on a successful refresh and the duration. No personally-identifying data.
- New picker rows (stock and crypto search hits) gain an `accessibilityLabel` of `"<symbol>, <name>, <kind>"` (e.g. "AAPL, Apple Inc., stock"). This matches the existing fiat-row pattern.
- The `AddTokenSheet` reuses `InstrumentPickerSheet`'s existing `accessibilityIdentifier("instrumentPicker.sheet")` — no new identifiers needed for screen-driver wiring.

## 11. Migration notes

This design intentionally does **not** migrate pre-existing unmapped `InstrumentRecord` rows. After this work ships, those rows continue to throw `ConversionError.noProviderMapping` whenever they are priced — the same behaviour as before. The recovery UX (one-shot "Review tokens" sheet at app launch, or in-line per-account affordance) is bundled into [#515](https://github.com/ajsutton/moolah-native/issues/515) so it can be designed alongside the CSV-import "Review unknown tokens" step that produces the same data shape.

## 12. Out of scope

- Server-side moolah-server changes (single-instrument backend; registry doesn't apply).
- The CSV-import "Review unknown tokens" step (#515).
- Any UI or migration for pre-existing unmapped `InstrumentRecord` rows (#515).
- Replacing the resolution client's CryptoCompare/Binance/CoinGecko-Pro plumbing — the existing `CompositeTokenResolutionClient` is reused as-is.
- Live crypto price fetching from new sources; the bulk catalogue is metadata only, not prices.
- Non-EVM chain handling beyond what `/asset_platforms` already provides (Solana, Cosmos, etc.) — `chain_id` is nullable on the `platform` table for exactly this case; resolution falls through to native-symbol matching.
- Bulk stock lists (no good source at the size we need; per-keystroke search is the design).

## 13. Risks and follow-ups

- **CoinGecko CDN ETag rotation.** Sometimes weak ETags rotate even when data is unchanged, so we'll occasionally re-download a 2.5 MB JSON we already had. Acceptable; correctness is unaffected.
- **Catalogue staleness for brand-new tokens.** A token launched within the last 24 h may not appear in search until the next refresh window. For v1 this is acceptable; if it becomes a real complaint, the follow-up is a "Refresh" button in Settings → Crypto.
- **Yahoo `/v1/finance/search` is undocumented.** Yahoo could break or rate-limit it. We already depend on Yahoo for prices, so the blast radius is the same as today.
- **`platform.chain_id IS NULL`.** Some CoinGecko platforms have no canonical numeric chain ID (e.g. non-EVM or oddly-mapped chains). Such platforms are excluded from crypto-search results; coins whose *only* platforms have null chain IDs will be omitted (rare). This keeps `Instrument.id` shapes consistent.
- **Multi-platform coins.** A coin like USDC is on ten chains. Picker behaviour: the user sees the coin once; on select we pick the highest-priority platform in `PlatformBinding` order (ETH → Polygon → BSC → Base → Arbitrum → Optimism → Avalanche → fallback to first). The user can later register the *same* coin on a different chain through the picker; the registry treats them as separate `Instrument`s by `<chainId>:<contract>` id. Acceptable for v1; richer "which chain?" UX is a follow-up if real users hit it.
- **Provider-mapping coverage.** Even after `resolve()` runs, some coins return all three IDs nil (very obscure or very new). We already refuse to register in this case; users see an inline error and the row is not written. No silent partial-success.
