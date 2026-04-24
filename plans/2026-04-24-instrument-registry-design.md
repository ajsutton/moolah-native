# Instrument Registry — Design

**Date:** 2026-04-24
**Status:** Draft

## Background

The iPhone app logs `BUG IN CLIENT OF KVS: Trying to initialize NSUbiquitousKeyValueStore without a store identifier.` when the Settings screen is opened. The root cause is that `Backends/ICloud/ICloudTokenRepository.swift` uses `NSUbiquitousKeyValueStore.default` to persist crypto-token registrations, but the required `com.apple.developer.ubiquity-kvstore-identifier` entitlement is absent from both the shipped `fastlane/Moolah.entitlements` file and the development-time injection script (`scripts/inject-entitlements.sh`). Without the entitlement, every `set(_:forKey:)` and `data(forKey:)` call is a silent no-op: crypto-token registrations have never persisted since the feature shipped.

Rather than adding the missing entitlement and living with a second sync mechanism (`NSUbiquitousKeyValueStore` alongside CloudKit), this design removes `NSUbiquitousKeyValueStore` entirely. Crypto-token registrations move into a unified per-profile **instrument registry** that covers fiat currencies, stocks, and crypto tokens in one data path. This dissolves the KVS dependency and lays the groundwork for a single searchable instrument picker that replaces the current hardcoded `CurrencyPicker`.

## Goals

- Eliminate the `NSUbiquitousKeyValueStore` API from the codebase.
- Provide one persistent, CloudKit-synced data path for non-fiat instruments (stocks + crypto tokens) per profile.
- Merge that data path with the ambient ISO 4217 fiat list so consumers see a single unified instrument set.
- Expose a search service that covers all three kinds behind one call, even though no UI consumes it yet.
- Preserve today's auto-insertion behaviour for non-fiat instruments referenced by transactions and imports.
- Do not regress any existing sync, test, or build path.

## Non-Goals

- No new `InstrumentPicker` SwiftUI view in this project.
- No replacement of `CurrencyPicker` call sites (tracked in a follow-up issue — §7.3).
- No redesign of the Crypto Settings "Add Token" form.
- No stock search by company name (no reliable source today; tracked in the follow-up).
- No changes to `moolah-server` or the Remote backend. Remote profiles are single-instrument and this design does not apply to them.
- No changes to app entitlements or provisioning profiles.
- No automatic seeding of `CryptoRegistration.builtInPresets`.

## Scope

### In scope

- Extend `InstrumentRecord` with nullable provider-mapping fields so it can carry crypto lookup data.
- Add `InstrumentRegistryRepository` protocol (Domain) and `CloudKitInstrumentRegistryRepository` implementation (Backends/CloudKit).
- Rewire `CryptoPriceService`, `CryptoTokenStore`, and `FullConversionService`'s `providerMappings` closure to read from the registry instead of the deleted `CryptoTokenRepository`.
- Delete `Backends/ICloud/ICloudTokenRepository.swift`, the `Backends/ICloud/` directory, `Domain/Repositories/CryptoTokenRepository.swift`, and any test doubles implementing the deleted protocol.
- Add `InstrumentSearchService` — a unified fan-out search over fiat (local ISO list), crypto (CoinGecko `/search` + contract-address path via the existing `TokenResolutionClient`), and stock (typed-ticker validated via `YahooFinanceClient`).
- Contract tests for the registry, unit tests for the search service, and updates to `CryptoPriceServiceTests`, `CryptoPriceServiceTestsMore`, and `CryptoTokenStoreTests`.

### Out of scope

See Non-Goals.

## Architectural Context

### Current state

- `Instrument` (Domain) is a single struct with a `Kind` enum (`fiatCurrency | stock | cryptoToken`) and kind-specific optional fields (`ticker`, `exchange`, `chainId`, `contractAddress`). One type covers all three kinds.
- `InstrumentRecord` (Backends/CloudKit) is a SwiftData `@Model` that rides the existing `CKSyncEngine` in each profile's private zone (`profile-<uuid>`). Today it is used as an **implicit cache**: `CloudKitTransactionRepository.ensureInstrument(_:)` inserts a row whenever a transaction leg references a new `Instrument`.
- `CryptoRegistration` (Domain) pairs an `Instrument` with a `CryptoProviderMapping` (CoinGecko / CryptoCompare / Binance identifiers).
- `CryptoTokenRepository` (Domain) is a protocol with two operations: `loadRegistrations()` and `saveRegistrations(_:)`.
- `ICloudTokenRepository` (Backends/ICloud) is the only concrete implementation, backed by `NSUbiquitousKeyValueStore.default`. Because the ubiquity-kvstore entitlement is missing, both methods are silent no-ops on all shipped builds.
- `CryptoPriceService` (Shared) is an `actor` built per profile in `ProfileSession.makeCryptoPriceService()`. It holds the `CryptoTokenRepository` and exposes `registeredItems()`, `register(_:)`, `remove(_:)`, `removeById(_:)`, and a zero-argument `prefetchLatest()` that pulls the registration list itself. It also owns the provider-resolution wrapper `resolveRegistration(...)` and the on-disk price cache.
- `FullConversionService` (CloudKit branch only) resolves crypto provider mappings via an injected closure: `providerMappings: { await cryptoPrices.registeredItems().map(\.mapping) }`.
- `CryptoTokenStore` (Features/Settings) is the UI store behind Crypto Settings and injects `CryptoPriceService` directly. It mediates all registration CRUD through the service.
- `CurrencyPicker` (Shared/Views) is a fixed list of 17 common ISO codes. It does not consult any registry.

### Target state

- `InstrumentRecord` is the persistence row for all **non-fiat** registered instruments (stocks + crypto) and carries the crypto provider-mapping fields directly. Fiat stays ambient.
- `InstrumentRegistryRepository` is the authoritative interface for instruments visible to a profile. Its `all()` output merges stored non-fiat rows with the full `Locale.Currency.isoCurrencies` fiat list.
- `CryptoTokenRepository` and `ICloudTokenRepository` do not exist.
- `CryptoPriceService` contains no registration state: no `tokenRepository`, no `registeredItems()`, no `register`/`remove`. It exposes only pricing, resolution, cache, and a new `purgeCache(instrumentId:)`.
- The crypto mapping closure in `FullConversionService` reads from the registry, not the price service.
- `InstrumentSearchService` exists and is unit-tested, but has no SwiftUI caller. Its shape is stable so the follow-up UI work doesn't churn it.

## Design

### 1. Data model

#### 1.1 `InstrumentRecord` schema extension

`Backends/CloudKit/Models/InstrumentRecord.swift` gains three nullable fields:

```swift
@Model
final class InstrumentRecord {
  // existing fields unchanged
  var id: String = ""
  var kind: String = "fiatCurrency"
  var name: String = ""
  var decimals: Int = 2
  var ticker: String?
  var exchange: String?
  var chainId: Int?
  var contractAddress: String?

  // NEW — populated only for crypto-kind rows
  var coingeckoId: String?
  var cryptocompareSymbol: String?
  var binanceSymbol: String?

  var encodedSystemFields: Data?
  // existing init + toDomain()/from(_:) helpers updated to round-trip the new fields
}
```

Because all three new fields are optional, SwiftData's automatic lightweight migration handles the change. No migration script required.

`Backends/CloudKit/Sync/InstrumentRecord+CloudKit.swift` (the `CloudKitRecordConvertible` conformance) gains encode/decode lines for the three new CKRecord keys. CKRecords predating this change decode with the new fields `nil`, preserving existing records on upgrade.

The sync-handler dispatch (`ProfileDataSyncHandler+ApplyRemoteChanges.swift`) already routes `InstrumentRecord` generically by `recordType`; no change there.

#### 1.2 Domain types

- `CryptoRegistration` (Domain/Models) is kept as a value type pairing `Instrument` with `CryptoProviderMapping`. It is no longer a persistence entity — it is derived from `InstrumentRecord` on read.
- `CryptoProviderMapping` is unchanged.
- `Instrument` is unchanged — provider identifiers stay on the mapping side, not on the domain instrument. `coingeckoId`/`cryptocompareSymbol`/`binanceSymbol` exist only on `InstrumentRecord` (persistence) and `CryptoProviderMapping` (in-memory pairing).
- `CryptoRegistration.builtInPresets` is kept for test fixtures; it is not auto-seeded into profiles.

#### 1.3 `InstrumentRegistryRepository` protocol

New file `Domain/Repositories/InstrumentRegistryRepository.swift`:

```swift
import Foundation

protocol InstrumentRegistryRepository: Sendable {
  /// Every instrument visible to the profile: stock + crypto rows from the
  /// database, merged with the ambient fiat ISO list from
  /// `Locale.Currency.isoCurrencies`. De-duplicated by `Instrument.id`.
  func all() async throws -> [Instrument]

  /// All registered crypto instruments with their provider mappings. Rows
  /// whose three provider-mapping fields are all nil are skipped (they cannot
  /// be priced).
  func allCryptoRegistrations() async throws -> [CryptoRegistration]

  /// Registers (upserts) an instrument. No-op when
  /// `instrument.kind == .fiatCurrency` — fiat is ambient and not stored.
  /// `cryptoMapping` must be non-nil when registering a crypto instrument
  /// and is ignored for fiat/stock; calling with a crypto instrument and
  /// nil mapping is a programmer error (`preconditionFailure`).
  /// Re-registering an instrument whose id already exists upserts — the
  /// existing row's mutable fields are overwritten with the new values.
  /// Does not throw when the instrument id is already present.
  func register(_ instrument: Instrument, cryptoMapping: CryptoProviderMapping?) async throws

  /// Removes a registered instrument by id. No-op for fiat ids and for ids
  /// that are not currently registered. Does not throw when the id is missing.
  func remove(instrumentId: String) async throws

  /// Yields each time the registered set changes (register/upsert/remove).
  var changes: AsyncStream<Void> { get }
}
```

#### 1.4 `CloudKitInstrumentRegistryRepository` implementation

New file `Backends/CloudKit/Repositories/CloudKitInstrumentRegistryRepository.swift`:

- Holds the profile's `ModelContainer` and an `AsyncStream.Continuation<Void>` for `changes`.
- `all()`: `@MainActor` fetch of every `InstrumentRecord`, convert to `[Instrument]`; append each code from `Locale.Currency.isoCurrencies` via `Instrument.fiat(code:)`. De-duplicate by `Instrument.id` — defensive, in case `InstrumentRecord`s exist for fiat codes from pre-change data (they remain and are preferred over the ambient entry on id collision).
- `allCryptoRegistrations()`: fetch rows with `kind == "cryptoToken"` where at least one of the three provider-mapping fields is non-nil; build `CryptoRegistration`s via `Instrument.crypto(...)` + `CryptoProviderMapping(instrumentId:, coingeckoId:, cryptocompareSymbol:, binanceSymbol:)`.
- `register(_:cryptoMapping:)`: kind-switch:
  - `.fiatCurrency` → return immediately.
  - `.stock` → upsert an `InstrumentRecord` (no mapping fields).
  - `.cryptoToken` → require non-nil `cryptoMapping`; upsert `InstrumentRecord` with the three mapping fields populated.
  After mutation, yield to the `changes` stream.
- `remove(instrumentId:)`: look up the row; if found and non-fiat, delete it and yield.
- `changes`: `AsyncStream` vended via `AsyncStream.makeStream()`; continuation yielded inside each mutating call.

Sendability follows the pattern of existing CloudKit repositories (`@unchecked Sendable` via `ModelContainer`-owned access on the main actor).

#### 1.5 `BackendProvider` exposure

`CloudKitBackend` gains one property:

```swift
let instrumentRegistry: any InstrumentRegistryRepository
```

set in its initializer. **The `BackendProvider` protocol is not changed** — `RemoteBackend` has no registry concept because moolah-server profiles are single-instrument. Consumers that need the registry (Crypto Settings, session setup, follow-up picker UI) access it via the CloudKit path through `ProfileSession`.

#### 1.6 `ensureInstrument` behaviour

`CloudKitTransactionRepository.ensureInstrument(_:)` is modified to skip insertion for `.fiatCurrency`. Fiat is served ambient by `InstrumentRegistryRepository.all()`; writing a fiat `InstrumentRecord` would create an unneeded per-profile duplicate of a universal constant. Stock and crypto still insert as today (so CSV imports of non-fiat instruments continue to populate the registry automatically).

`CloudKitTransactionRepository.resolveInstrument(id:)` still falls back to `Instrument.fiat(code: id)` when no `InstrumentRecord` exists — this preserves correct behaviour for any fiat code referenced in transaction legs.

### 2. Search service

`Shared/InstrumentSearchService.swift`:

```swift
struct InstrumentSearchResult: Sendable, Hashable, Identifiable {
  let instrument: Instrument
  let cryptoMapping: CryptoProviderMapping?  // non-nil for crypto hits
  let isRegistered: Bool                     // already in the profile's registry
  let requiresResolution: Bool               // crypto hit from search needs chain
                                             // / contract / decimals resolved via
                                             // TokenResolutionClient before the
                                             // caller can persist it
  var id: String { instrument.id }
}

actor InstrumentSearchService {
  init(
    registry: any InstrumentRegistryRepository,
    cryptoSearchClient: any CryptoSearchClient,
    resolutionClient: any TokenResolutionClient,
    stockValidator: any StockTickerValidator
  )

  func search(query: String, kinds: Set<Instrument.Kind>? = nil)
    async -> [InstrumentSearchResult]
}
```

#### 2.1 Behaviour by kind

- **Fiat (local, synchronous within the actor).** Iterate `Locale.Currency.isoCurrencies`; match `query` against ISO code (case-insensitive prefix) and the localized currency name from `Locale.current.localizedString(forCurrencyCode:)` (case-insensitive substring). Every fiat result is `isRegistered: true` (ambient) and `requiresResolution: false`.
- **Crypto (network).** New `CryptoSearchClient` protocol in `Domain/Repositories/CryptoSearchClient.swift` with its default CoinGecko-backed implementation in `Backends/CoinGecko/CoinGeckoSearchClient.swift` (alongside the existing `CoinGeckoClient`; both share URL session and API-key handling). The implementation hits `GET /search?query=...`. Each hit yields an `InstrumentSearchResult` whose `instrument` is a **placeholder** `Instrument.crypto(chainId: 0, contractAddress: nil, symbol: hit.symbol, name: hit.name, decimals: 18)`; `cryptoMapping.coingeckoId` is populated from the hit, `cryptocompareSymbol` and `binanceSymbol` stay `nil`. `requiresResolution: true` signals the caller to call `TokenResolutionClient.resolve(chainId:contractAddress:symbol:isNative:)` before passing to `registry.register(_:cryptoMapping:)`. If `query` matches `^0x[0-9a-fA-F]{40}$`, the search endpoint is bypassed and `TokenResolutionClient.resolve(...)` is called directly; its result has `requiresResolution: false`.
- **Stock (typed + validated).** New `StockTickerValidator` protocol in `Domain/Repositories/StockTickerValidator.swift` with its default Yahoo-backed implementation in `Backends/YahooFinance/YahooFinanceStockTickerValidator.swift` (using `YahooFinanceClient`). Parses `query` in two canonical forms: `EXCHANGE:TICKER` (the project's canonical `Instrument.stock` id form, e.g. `ASX:BHP`) or Yahoo-native suffixed ticker (e.g. `BHP.AX`, `^GSPC`, `AAPL`); the validator normalises both forms into an `(exchange, ticker)` pair before the price-fetch probe. On successful price fetch, yields one result with `Instrument.stock(ticker:..., exchange:..., name: ticker, decimals: 0)` and `isRegistered: false`. On failure, yields nothing. No name-matching until a name source lands (follow-up issue).

#### 2.2 Registered-set merge

Before fanning out, the service fetches `registry.all()` and filters it locally against `query` using the same matching rules per kind. Matches from the registered set are marked `isRegistered: true` and rank ahead of freshly-fetched provider hits. If a provider hit shares an `Instrument.id` with a registered entry, the registered entry wins and the hit is discarded.

#### 2.3 Ranking and de-duplication

Single-pass merge with this ranking, highest to lowest:

1. Registered entries whose id or ticker exactly matches `query` (case-insensitive).
2. Registered entries whose id or ticker is a prefix of `query` (case-insensitive).
3. Registered entries matching `query` on localized name (substring, case-insensitive).
4. Provider hits in the same three tiers in the same order.

De-duplication key is `Instrument.id`. Stable sort within each tier preserves upstream ordering (Locale iteration order for fiat; CoinGecko-returned order for crypto).

#### 2.4 Empty query

`search(query: "")` returns `registry.all()` mapped to `InstrumentSearchResult`s, all with `isRegistered: true`. Useful for the follow-up UI so the picker can list "your instruments" before the user types.

#### 2.5 Statelessness

Each call is independent; callers own debouncing and cancellation (`Task.cancel()` propagates through the underlying URLSession tasks via `CryptoSearchClient` / `StockTickerValidator`, both of which must be cancellation-cooperative).

### 3. Service wiring

#### 3.1 `CryptoPriceService` surface reduction

- Remove `init(..., tokenRepository:)` parameter.
- Remove `registeredItems()`, `register(_:)`, `remove(_:)`, `removeById(_:)`.
- Remove zero-argument `prefetchLatest()`; keep `prefetchLatest(for: [CryptoRegistration])`.
- Keep `resolveRegistration(chainId:contractAddress:symbol:isNative:)` (pure wrapper over `TokenResolutionClient`, no persistence).
- Keep `price(for:mapping:on:)`, `prices(for:mapping:in:)`, `currentPrices(for:)` and the disk-cache layer.
- Add `purgeCache(instrumentId: String)`: removes the in-memory cache entry and deletes the on-disk cache file for that id. Used when a caller un-registers an instrument.

`CryptoPriceService` becomes a focused price-fetch + cache actor with no knowledge of what is registered.

#### 3.2 `FullConversionService.providerMappings` closure

In `ProfileSession+Factories.makeBackend` (CloudKit branch), the closure changes:

```swift
// before
providerMappings: { await cryptoPrices.registeredItems().map(\.mapping) }
// after
providerMappings: { (try? await registry.allCryptoRegistrations())?.map(\.mapping) ?? [] }
```

Same shape, different source. Error swallowed to `[]` to match the existing best-effort semantics of the closure.

#### 3.3 `CryptoTokenStore` (Crypto Settings)

```swift
@MainActor
@Observable
final class CryptoTokenStore {
  private let registry: any InstrumentRegistryRepository
  private let cryptoPriceService: CryptoPriceService

  init(registry: any InstrumentRegistryRepository, cryptoPriceService: CryptoPriceService)
}
```

- `loadRegistrations()` → `(try? await registry.allCryptoRegistrations()) ?? []`.
- `confirmRegistration()` → `try await registry.register(r.instrument, cryptoMapping: r.mapping)` (for the resolved registration).
- `removeRegistration(_:)` → `try await registry.remove(instrumentId: r.id)` then `await cryptoPriceService.purgeCache(instrumentId: r.id)`.
- `resolveToken(...)` unchanged — still calls `cryptoPriceService.resolveRegistration(...)`.
- API-key methods (`hasApiKey`, `saveApiKey`, `clearApiKey`) unchanged.

#### 3.4 `ProfileSession+Factories` wiring order

In the CloudKit branch of `makeBackend`:

```swift
let profileContainer = try! containerManager.container(for: profile.id)
let registry = CloudKitInstrumentRegistryRepository(modelContainer: profileContainer)
let conversionService = FullConversionService(
  exchangeRates: exchangeRates,
  stockPrices: stockPrices,
  cryptoPrices: cryptoPrices,
  providerMappings: {
    (try? await registry.allCryptoRegistrations())?.map(\.mapping) ?? []
  }
)
return CloudKitBackend(
  modelContainer: profileContainer,
  instrument: profile.instrument,
  profileLabel: profile.label,
  conversionService: conversionService,
  instrumentRegistry: registry
)
```

`makeCryptoPriceService()` loses the `tokenRepository:` argument.

`ProfileSession` adds a stored property `instrumentRegistry: (any InstrumentRegistryRepository)?`, populated from the CloudKit backend's new property for `.cloudKit` profiles and left `nil` for `.remote` / `.moolah` profiles. Crypto Settings views gate on this property being non-nil (see §3.6).

#### 3.5 Initial prefetch on session load

Wherever `ProfileSession` currently calls the zero-argument `cryptoPriceService.prefetchLatest()` at session load, replace with:

```swift
if let regs = try? await registry.allCryptoRegistrations(), !regs.isEmpty {
  await cryptoPriceService.prefetchLatest(for: regs)
}
```

Caller-side one-liner; no behaviour change.

#### 3.6 `SettingsView` / `SettingsView+iOS` fallback paths

Both currently construct a fallback `CryptoPriceService` using `ICloudTokenRepository()` when `activeSession` is `nil`. After deletion of `ICloudTokenRepository`, those fallback paths will no longer compile. Resolution: **gate the Crypto Settings navigation on `activeSession?.instrumentRegistry != nil`**. This covers both the "no active session" case and the "active session is a Remote/moolah profile" case (Remote profiles are single-instrument and have no registry). Crypto tokens have no meaningful semantics without a CloudKit-backed profile.

### 4. Deletions

| Path | Reason |
|---|---|
| `Backends/ICloud/ICloudTokenRepository.swift` | Sole user of `NSUbiquitousKeyValueStore`. |
| `Backends/ICloud/` (directory) | Empty after the file removal. |
| `Domain/Repositories/CryptoTokenRepository.swift` | Protocol no longer referenced. |
| `MoolahTests/Support/InMemoryTokenRepository.swift` (if present) | Test double for the deleted protocol. |

`CryptoRegistration` and `CryptoProviderMapping` are **kept**.

### 5. Migration and compatibility

- **`NSUbiquitousKeyValueStore` data.** Nothing to migrate. The entitlement has been absent on every shipped build, so `set(_:forKey:)` has always been a silent no-op. No user has persisted registrations via KVS.
- **Existing `InstrumentRecord` rows.** Unchanged. The three new fields default to `nil`. SwiftData's automatic lightweight migration handles the schema bump.
- **Existing crypto position rows.** Per confirmation with the product owner, there are no users with crypto positions today — the feature has been effectively non-functional since ship. No migration or "registration missing" affordance needed.
- **Automatic preset seeding.** Deliberately not performed. `CryptoRegistration.builtInPresets` stays as a test fixture.
- **App entitlements.** Unchanged. `fastlane/Moolah.entitlements` and `scripts/inject-entitlements.sh` are untouched.

### 6. Testing

All tests follow the project's TDD and contract-test rules: tests written before implementation; integration tests use `TestBackend` (real `CloudKitBackend` + in-memory SwiftData); no mocking of the repository layer.

#### 6.1 `InstrumentRegistryRepository` contract tests

New file `MoolahTests/Domain/InstrumentRegistryRepositoryContractTests.swift`, run against `CloudKitInstrumentRegistryRepository` on in-memory SwiftData:

- `all()` merges DB rows with ambient fiat ISO list; no duplicates.
- `all()` on a fresh profile contains every ISO currency from `Locale.Currency.isoCurrencies` and zero non-fiat entries.
- `all()` after registering a stock includes the stock.
- `allCryptoRegistrations()` returns only crypto rows with at least one populated provider-mapping field.
- `register(fiat, nil)` is a no-op — no row created, `all()` unchanged.
- `register(crypto, mapping)` round-trips all eight crypto fields (id/kind/name/decimals/ticker/chainId/contract + three mapping fields).
- `register(stock, nil)` round-trips ticker+exchange without provider-mapping fields.
- `register(existing, newMapping)` upserts — re-registering a crypto instrument replaces the mapping rather than duplicating.
- `remove(id)` deletes the row; `remove(fiatId)` is a no-op.
- `remove(unknownId)` is a no-op and does not throw.
- `changes` stream yields exactly once per mutation (register, upsert, remove).
- `changes` stream does not yield for no-op calls (fiat register, unknown-id remove).
- Corrupt row defence: an `InstrumentRecord` with `kind == "cryptoToken"` but all three provider-mapping fields `nil` is not returned from `allCryptoRegistrations()` and does not crash `all()`.

#### 6.2 `InstrumentRecord` CloudKit round-trip

Extend existing `InstrumentRecord` CloudKit tests (or add one) to cover:

- Encode `InstrumentRecord` with populated crypto mappings → CKRecord has the three field values.
- Decode CKRecord with the three fields → `InstrumentRecord` populated.
- Decode a CKRecord **without** the three fields (pre-migration record) → fields default to `nil`, no crash.

#### 6.3 `InstrumentSearchService`

New file `MoolahTests/Shared/InstrumentSearchServiceTests.swift`. Stub clients via `URLProtocol`-backed fixture JSON for CoinGecko; in-memory stubs conforming to `StockTickerValidator` and `TokenResolutionClient`:

- Fiat: case-insensitive prefix match on ISO code; substring match on localized name.
- Crypto: CoinGecko fixture returns two hits; service emits two results with `requiresResolution == true` and populated `coingeckoId`.
- Crypto-by-contract: query matching `^0x[0-9a-fA-F]{40}$` bypasses search, calls the resolution client; result has `requiresResolution == false`.
- Stock: valid typed ticker in `EXCHANGE:TICKER` form (`ASX:BHP`) → stub validator returns success → one result.
- Stock: valid Yahoo-native form (`BHP.AX`) → stub validator returns success → one result with the same normalised `(exchange, ticker)` pair.
- Stock: validator returns failure → empty.
- Stock: validator throws → search returns empty for the stock kind, does not propagate, and still surfaces fiat / crypto results.
- Results already in the registry are marked `isRegistered: true` and rank first.
- De-duplication by `Instrument.id` — provider hit sharing an id with a registered entry is dropped.
- Empty query returns the current registered set (order preserved).

#### 6.4 `CryptoPriceService`

In `CryptoPriceServiceTests` and `CryptoPriceServiceTestsMore`:

- Delete tests exercising `register`, `remove`, `removeById`, zero-argument `prefetchLatest`, or `registeredItems()`.
- Keep price-fetch, price-range, current-prices, resolver, and disk-cache tests.
- Add a new test for `purgeCache(instrumentId:)`: after seeding a cached price, `purgeCache` removes the in-memory entry and deletes the on-disk file.
- Update the remaining `prefetchLatest(for: [CryptoRegistration])` test to pass registrations explicitly.

Delete `InMemoryTokenRepository` test double if it exists.

#### 6.5 `CryptoTokenStore`

In `CryptoTokenStoreTests`, switch from `InMemoryTokenRepository` injection to `CloudKitInstrumentRegistryRepository` backed by an in-memory `ModelContainer`:

- `loadRegistrations()` reflects registry state.
- `confirmRegistration()` writes through the registry.
- `removeRegistration(_:)` removes from the registry **and** calls `cryptoPriceService.purgeCache(instrumentId:)`.
- `resolveToken(...)` path unchanged — assert it still produces a `resolvedRegistration` matching the resolver's output.

#### 6.6 Integration — `FullConversionService` via registry

One end-to-end test in `MoolahTests/Shared/`: with a `TestBackend`, register a crypto instrument, invoke `FullConversionService.convert(...)` for a crypto amount, assert the `providerMappings` closure resolved against the registry and the conversion produced the expected fiat value. Covers the full wiring seam.

### 7. Rollout

#### 7.1 Branching

Feature work happens on `feat/instrument-registry` in `.worktrees/instrument-registry`. PR to `main` via the merge-queue skill. No direct pushes to `main`.

#### 7.2 PR shape

One coherent PR. The pieces are tightly coupled — removing `CryptoTokenRepository` requires both the registry implementation and the `CryptoPriceService` rewire to land together, or the build breaks mid-stack. The PR description explicitly lists these post-merge greps:

- `NSUbiquitousKeyValueStore` — zero hits anywhere.
- `CryptoTokenRepository` — zero hits.
- `ICloudTokenRepository` — zero hits.
- `com.apple.developer.ubiquity-kvstore-identifier` — zero hits in entitlements or scripts.

#### 7.3 Follow-up GitHub issue

Filed before the implementation PR opens. Working title: **"Instrument registry UI: unified picker & call-site migration"**. Body sketch:

> Follow-up to the instrument-registry backend work (plans/2026-04-24-instrument-registry-design.md). The registry, repository, and search service now exist; the UI has not yet been updated to take advantage of them.
>
> **In scope for this issue**
>
> - Build a generic `InstrumentPicker` SwiftUI view that uses `InstrumentSearchService`.
>   - Shows the profile's registered instruments first, then on-type search results grouped by kind (Currency / Stock / Crypto).
>   - Selecting an unregistered crypto search result runs `TokenResolutionClient` then writes to the registry.
>   - Selecting an unregistered stock result validates via `StockTickerValidator` then writes.
>   - Fiat selection is always immediate (ambient).
> - Replace `CurrencyPicker` call sites with `InstrumentPicker` filtered to `.fiatCurrency`:
>   - Profile creation (`ProfileFormView`).
>   - Account creation / editing.
>   - Transaction forms where currency overrides the account.
> - Redesign the Crypto Settings "Add Token" flow to sit on top of `InstrumentSearchService` rather than the current contract-address form.
> - Verify that CSV import auto-registers instruments it references (today: routes through `ensureInstrument` via transaction legs; confirm coverage).
> - Find or integrate a stock-name source so stock search can match on company name, not just ticker.
>
> **Out of scope**
>
> - Server-side changes.
> - Remote / moolah-server profile support (single-instrument backends; registry doesn't apply).

#### 7.4 Risk summary

- **Schema change** is additive and nullable; SwiftData lightweight migration covers it; CloudKit fields default to absent/nil.
- **Sync fan-out** — new fields are on an already-synced record type, so the existing `CloudKitRecordConvertible` path carries them without new sync-engine code.
- **Deletion of `ICloudTokenRepository`** is pure subtraction; the only caller is `CryptoPriceService`'s init, which is also being changed. Compiler enforces the caller update.
- **Settings fallback gating** is the only user-visible behaviour change: crypto settings become unavailable when no profile is active.
- **No entitlement changes** — fastlane / provisioning story unchanged.

#### 7.5 Post-merge verification

- `just test` passes on iOS Simulator and macOS.
- Launch macOS build via `just run-mac-with-logs`, open Crypto Settings, register a token, quit, relaunch → token is still there (proves the fix).
- `grep "BUG IN CLIENT OF KVS"` across captured logs: zero hits.

## Open Questions

None — resolved during brainstorming:

- Scope: per-profile, CloudKit only. (Remote backends are single-instrument.)
- Fiat storage: ambient mix-in from `Locale.Currency.isoCurrencies`; no DB rows for fiat.
- Provider-mapping storage: flat optional fields on `InstrumentRecord`.
- Search architecture: unified fan-out; stock limited to typed-ticker until a name source is found.
- Picker UI migration: deferred to the follow-up issue above.
- Preset seeding: not performed.
