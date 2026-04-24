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

`Backends/CloudKit/Sync/InstrumentRecord+CloudKit.swift` (the `CloudKitRecordConvertible` conformance) gains:

- **Encode** side: three new `if let field { record["coingeckoId"] = field as CKRecordValue }` blocks, matching the existing conditional-set pattern used for `ticker`, `exchange`, `chainId`, and `contractAddress`. Nil fields must remain absent from the `CKRecord`, not be written as explicit nulls — this avoids wasting record bytes and matches the existing convention.
- **Decode** side: three new `as? String` reads in `fieldValues(from:)` with nil default. `as?` returns `nil` for both a missing key and an explicit null, so CKRecords predating this change decode with the new fields `nil` and no crash. No force-cast anywhere.

The sync-handler dispatch (`ProfileDataSyncHandler+ApplyRemoteChanges.swift`) already routes `InstrumentRecord` generically by `recordType`; no routing change there.

**Field-copy update — `batchUpsertInstruments`.** `ProfileDataSyncHandler+BatchUpsert.swift` currently enumerates each `InstrumentRecord` field by name when updating an existing row from remote data:

```swift
existing.kind = values.kind
existing.name = values.name
// … seven fields total
```

Three additional lines are added for the new fields:

```swift
existing.coingeckoId = values.coingeckoId
existing.cryptocompareSymbol = values.cryptocompareSymbol
existing.binanceSymbol = values.binanceSymbol
```

Without this update, device B silently drops the new fields when applying a remote update from device A (the decoded `values` object carries them, but the copy-block does not transfer them). The insert branch is unaffected because it inserts the whole `values` object.

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
  /// `Locale.Currency.isoCurrencies`. De-duplicated by `Instrument.id`
  /// (stored row wins on collision with an ambient fiat entry).
  /// Throws on a backing-store failure (e.g. `ModelContainer` unavailable).
  func all() async throws -> [Instrument]

  /// All registered crypto instruments with their provider mappings. Rows
  /// whose three provider-mapping fields are all nil are skipped (they
  /// cannot be priced); see §1.6 for the CSV-import scenario that can
  /// produce such rows.
  /// Throws on a backing-store failure.
  func allCryptoRegistrations() async throws -> [CryptoRegistration]

  /// Registers (or upserts) a crypto instrument with its provider mapping.
  /// Re-registering an id that already exists overwrites the mapping and
  /// mutable metadata fields rather than duplicating the row.
  /// Invokes the injected sync-queue hook after a successful SwiftData
  /// write (see §3.4).
  /// Traps (via the compiler's type check) if a non-crypto `Instrument`
  /// is passed — this variant only accepts `.cryptoToken` instruments.
  func registerCrypto(
    _ instrument: Instrument, mapping: CryptoProviderMapping
  ) async throws

  /// Registers (or upserts) a stock instrument. Mapping fields stay nil
  /// for stock rows — Yahoo's lookup key is the instrument's own ticker.
  /// Accepts only `.stock` instruments.
  func registerStock(_ instrument: Instrument) async throws

  /// Removes a registered instrument by id. No-op for fiat ids and for
  /// ids that are not currently registered. Does not throw when the id
  /// is missing. Invokes the injected sync-queue hook after a successful
  /// delete.
  func remove(instrumentId: String) async throws

  /// Creates a fresh change-observation stream for a single consumer.
  /// Every mutating call on this repository (registerCrypto, registerStock,
  /// remove) yields a `Void` to every outstanding stream created via this
  /// method. Terminating the returned AsyncStream (consumer cancellation
  /// or break) removes its continuation from the fan-out list.
  ///
  /// **Scope.** This stream fires only for *local* mutations on this
  /// repository instance. Remote-change notifications delivered by
  /// `CKSyncEngine` apply to `InstrumentRecord` via `batchUpsertInstruments`
  /// and do NOT fan out through this stream — consumers that must react
  /// to remote changes also subscribe to the existing per-profile
  /// `SyncCoordinator` observer signal. This scope limitation is
  /// deliberate for this project; the reactive-UI follow-up (§7.3)
  /// introduces a unified local+remote change signal.
  func observeChanges() -> AsyncStream<Void>
}
```

Design notes on the split register API:

- Fiat has no register path. Fiat registration is semantically a no-op (ambient), and surfacing a "register fiat" method invites callers to write dead code. Fiat instruments simply appear in `all()` via the mix-in.
- Crypto requires a mapping. Encoding this at the type level (separate method with a non-optional mapping parameter) eliminates the runtime-trap scenario flagged in reviewer feedback and makes the contract testable.
- Stock has no mapping. Separate method mirrors the semantic distinction.
- `preconditionFailure` is reserved for the "caller passed a `.fiatCurrency` instrument to a non-fiat register method" case — a genuine programmer error that is both rare and obvious in code review.

#### 1.4 `CloudKitInstrumentRegistryRepository` implementation

New file `Backends/CloudKit/Repositories/CloudKitInstrumentRegistryRepository.swift`. Structure follows the existing `CloudKitAccountRepository` / `CloudKitTransactionRepository` patterns for Sendability and context use — not a new pattern.

**Stored state:**

- `let modelContainer: ModelContainer`
- `let onRecordChanged: @Sendable (String) -> Void` — sync-queue hook, set by `CloudKitBackend` to call `SyncCoordinator.queueSave(recordName:zoneID:)` with the registry's zone (same pattern as `CloudKitTransactionRepository.onInstrumentChanged`, since `InstrumentRecord` uses string ids).
- `let onRecordDeleted: @Sendable (String) -> Void` — symmetric hook for deletions.
- Multi-consumer fan-out: a `@MainActor`-confined `[UUID: AsyncStream<Void>.Continuation]` dictionary. New subscribers are added in `observeChanges()`; finished/cancelled subscribers are removed via their termination handler.

**Sendability.** `@unchecked Sendable` with `@MainActor` discipline on mutable state — same model used by every existing CloudKit repository. `AsyncStream.Continuation` is itself `Sendable` and thread-safe for `yield()`; the dictionary holding the continuations is the only state that must be actor-confined, and it is accessed only from `@MainActor`.

**Read methods** use a **background** `ModelContext` (following the established pattern in `CloudKitAccountRepository.fetchAll()` — `let bgContext = ModelContext(modelContainer)`), not the main context. Reads therefore do not block the main thread even for a full `InstrumentRecord` table scan.

- `all()` (background context): fetch every `InstrumentRecord`, convert to `[Instrument]`; append each code from `Locale.Currency.isoCurrencies` via `Instrument.fiat(code:)`. De-duplicate by `Instrument.id`. On id collision with an ambient fiat entry, the stored row wins (defensive against any legacy fiat `InstrumentRecord`s present from pre-change data).
- `allCryptoRegistrations()` (background context): fetch rows with `kind == "cryptoToken"` where at least one of the three provider-mapping fields is non-nil; build `CryptoRegistration`s via `Instrument.crypto(...)` + `CryptoProviderMapping(...)`.

**Write methods** use `await MainActor.run { ... }` with `modelContainer.mainContext`, matching the existing write pattern in `CloudKitTransactionRepository.ensureInstrument(_:)`:

- `registerCrypto(_:mapping:)`:
  - Precondition: `instrument.kind == .cryptoToken`. Violation traps (programmer error).
  - In the main-actor block: fetch-or-create the `InstrumentRecord` row by id; set / overwrite all eight crypto fields including the three mapping fields; commit.
  - After the main-actor block returns: call `onRecordChanged(instrument.id)` to queue sync, then fan out a `yield()` to every registered change-stream continuation.
- `registerStock(_:)`:
  - Precondition: `instrument.kind == .stock`. Violation traps.
  - Same shape as `registerCrypto` but without mapping fields.
- `remove(instrumentId:)`:
  - In the main-actor block: look up the row; return early if missing or if the row has kind `.fiatCurrency` (no-op for fiat and for unknown ids — does not throw).
  - Delete the row; commit.
  - After the main-actor block: call `onRecordDeleted(instrumentId)` to queue a CloudKit delete, then fan out `yield()`.
- `observeChanges()`:
  - Hops to `@MainActor`, creates a new `AsyncStream.makeStream()`, installs the continuation under a fresh `UUID` key in the fan-out dictionary, and sets `onTermination` to remove the entry back on `MainActor`. Returns the `AsyncStream`.

**Concurrency guarantees.** Writes are serialized on the main actor; reads run off-main on a fresh background context. The fan-out dictionary is accessed only from `@MainActor` and is therefore free of data races. Yields to `AsyncStream.Continuation` are thread-safe per Foundation's contract and do not need actor confinement. Cancellation of a subscriber removes its continuation without affecting sibling subscribers.

#### 1.5 `BackendProvider` exposure

`CloudKitBackend` gains one property:

```swift
let instrumentRegistry: any InstrumentRegistryRepository
```

set in its initializer. **The `BackendProvider` protocol is not changed** — `RemoteBackend` has no registry concept because moolah-server profiles are single-instrument. Consumers that need the registry (Crypto Settings, session setup, follow-up picker UI) access it via `ProfileSession.instrumentRegistry` (§3.4).

Feature code (Views and Stores under `Features/`) must continue to hold `any InstrumentRegistryRepository` (the protocol existential) and must not import `Backends/CloudKit` or reference the concrete `CloudKitInstrumentRegistryRepository` type directly. The concrete type is constructed in exactly one place — the CloudKit branch of `ProfileSession.makeBackend(...)` (§3.4) — and never leaks as a concrete type anywhere else. This preserves the project's domain-layer / feature-layer / backend-layer isolation.

#### 1.6 `ensureInstrument` behaviour

`CloudKitTransactionRepository.ensureInstrument(_:)` is modified to skip insertion for `.fiatCurrency`. Fiat is served ambient by `InstrumentRegistryRepository.all()`; writing a fiat `InstrumentRecord` would create an unneeded per-profile duplicate of a universal constant. Stock and crypto still insert as today (so CSV imports of non-fiat instruments continue to populate the registry automatically).

`CloudKitTransactionRepository.resolveInstrument(id:)` still falls back to `Instrument.fiat(code: id)` when no `InstrumentRecord` exists — this preserves correct behaviour for any fiat code referenced in transaction legs.

**Known limitation — crypto rows inserted via `ensureInstrument` lack mapping fields.** `ensureInstrument` has no knowledge of provider mappings; any crypto `Instrument` reaching this code path via a CSV import or a remote data change creates an `InstrumentRecord` with all three mapping fields `nil`. Such rows are filtered out of `allCryptoRegistrations()` (§1.3) and therefore the conversion service will return `ConversionError.noProviderMapping` when asked to price the token. The user must open Crypto Settings and resolve the token's mapping before conversions succeed. This is the same user-facing state as today (where no crypto has ever been priceable because the KVS layer dropped all registrations), so there is no regression — but the scenario is genuinely new in the sense that it now surfaces as an actionable "resolve mapping" state per token rather than a universal broken state. A proper "resolve on first reference" flow is deferred to the follow-up UI issue (§7.3), which will add an affordance in the picker and — optionally — an automated first-use resolution via `TokenResolutionClient` when an auto-inserted row is first referenced.

### 2. Search service

Two files:

**`Shared/InstrumentSearchResult.swift`** — the result type lives in its own file (it has API surface independent of the service and is referenced from tests and from the follow-up UI work):

```swift
struct InstrumentSearchResult: Sendable, Identifiable {
  let instrument: Instrument
  let cryptoMapping: CryptoProviderMapping?  // non-nil for crypto hits
  let isRegistered: Bool                     // already in the profile's registry
  let requiresResolution: Bool               // crypto hit from search needs chain
                                             // / contract / decimals resolved via
                                             // TokenResolutionClient before the
                                             // caller can persist it
  var id: String { instrument.id }
}

extension InstrumentSearchResult: Equatable {
  /// Equality is keyed on `instrument.id` alone — two results for the same
  /// instrument (one registered, one a fresh search hit) collapse to the
  /// same identity during de-duplication. Ranking in `InstrumentSearchService`
  /// decides which variant survives.
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension InstrumentSearchResult: Hashable {
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
```

**`Shared/InstrumentSearchService.swift`** — the service is a `struct` (not an `actor`). It holds no mutable state; every search is independent; concurrent calls fan out in parallel rather than being serialised on an actor executor:

```swift
struct InstrumentSearchService: Sendable {
  private let registry: any InstrumentRegistryRepository
  private let cryptoSearchClient: any CryptoSearchClient
  private let resolutionClient: any TokenResolutionClient
  private let stockValidator: any StockTickerValidator

  init(
    registry: any InstrumentRegistryRepository,
    cryptoSearchClient: any CryptoSearchClient,
    resolutionClient: any TokenResolutionClient,
    stockValidator: any StockTickerValidator
  )

  /// Searches all three kinds in parallel and returns merged, ranked, deduped
  /// results. Individual-kind failures are absorbed and logged via
  /// `os.Logger` — a stock validator throw, a CoinGecko network failure, or
  /// a registry read failure each reduce that kind's contribution to the
  /// empty set while the other kinds still return their results. The method
  /// itself does not throw: it is a best-effort UI-facing API.
  func search(query: String, kinds: Set<Instrument.Kind>? = nil)
    async -> [InstrumentSearchResult]
}
```

`Shared/InstrumentSearchService.swift` only imports `Foundation` and the protocol types from `Domain/Repositories/`. It must not import `Backends/CoinGecko` or `Backends/YahooFinance`: the concrete clients are injected via their protocols.

#### 2.1 Behaviour by kind

- **Fiat (local, synchronous in the caller's context).** Iterate `Locale.Currency.isoCurrencies`; match `query` against ISO code (case-insensitive prefix) and the localized currency name from `Locale.current.localizedString(forCurrencyCode:)` (case-insensitive substring). Every fiat result is `isRegistered: true` (ambient) and `requiresResolution: false`.
- **Crypto (network).** New `CryptoSearchClient` protocol in `Domain/Repositories/CryptoSearchClient.swift` with its default CoinGecko-backed implementation in `Backends/CoinGecko/CoinGeckoSearchClient.swift` (alongside the existing `CoinGeckoClient`; both share URL session and API-key handling). The implementation hits `GET /search?query=...`. Each hit yields an `InstrumentSearchResult` whose `instrument` is a **placeholder** `Instrument.crypto(chainId: 0, contractAddress: nil, symbol: hit.symbol, name: hit.name, decimals: 18)`; `cryptoMapping.coingeckoId` is populated from the hit, `cryptocompareSymbol` and `binanceSymbol` stay `nil`. `requiresResolution: true` signals the caller to call `TokenResolutionClient.resolve(chainId:contractAddress:symbol:isNative:)` before passing the resolved result to `registry.registerCrypto(_:mapping:)`. If `query` matches `^0x[0-9a-fA-F]{40}$`, the search endpoint is bypassed and `TokenResolutionClient.resolve(...)` is called directly; its result has `requiresResolution: false`.
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

#### 2.5 Statelessness and concurrency

The service is a `struct` conforming to `Sendable`. Every call to `search(query:kinds:)` is independent: no shared mutable state, no actor-queue serialisation. Concurrent searches fan out in parallel (which is the natural pattern for a debounced picker — the caller can issue a fresh search while the previous one is still in flight).

Cancellation and debouncing are the caller's responsibility. `Task.cancel()` propagates through the underlying `URLSession` tasks because `CryptoSearchClient` and `StockTickerValidator` (and the existing `TokenResolutionClient`) all implement cancellation-cooperative request paths — each provider-side task in the `async let` fan-out inherits the caller's cancellation.

#### 2.6 Closure type for stored providerMappings

The `providerMappings` closure stored in `FullConversionService` (see §3.2) is typed `@Sendable () async throws -> [CryptoProviderMapping]`. The existing callsite must be updated to the throwing signature; all callers inside `FullConversionService.cryptoUsdPrice(for:on:)` adopt `try await` to propagate registry failures rather than silently dropping them.

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

The stored closure type in `FullConversionService.init` changes from

```swift
providerMappings: @Sendable @escaping () async -> [CryptoProviderMapping]
```

to

```swift
providerMappings: @Sendable @escaping () async throws -> [CryptoProviderMapping]
```

so that a registry read failure is propagated as a thrown error rather than collapsed to an empty mapping table. Callers inside `FullConversionService.cryptoUsdPrice(for:on:)` already invoke the closure with `await`; this changes to `try await`, and `cryptoUsdPrice` therefore throws when the registry fails — which surfaces naturally through `FullConversionService.convert(_:from:to:on:)` and reaches the caller as a `ConversionError` / propagated error. This matches the project's instrument-conversion guide rule that failed conversions must be surfaced, not silently substituted.

In `ProfileSession+Factories.makeBackend` (CloudKit branch):

```swift
// before
providerMappings: { await cryptoPrices.registeredItems().map(\.mapping) }
// after
providerMappings: {
  try await registry.allCryptoRegistrations().map(\.mapping)
}
```

The pre-change code's silent-failure behaviour was an artefact of the broken KVS layer always returning `[]`; preserving that silence after moving to a real backing store is a regression in observability and would hide genuine SwiftData errors. The throwing closure is the correct contract once registrations actually persist.

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

- `loadRegistrations()`: wrap in `do { registrations = try await registry.allCryptoRegistrations() } catch { self.error = error.localizedDescription; logger.error("Failed to load crypto registrations: \(error, privacy: .public)") }`. Surfaces failures in the existing `error: String?` property and logs via the store's `os.Logger`. No silent `try?`.
- `confirmRegistration()` → `try await registry.registerCrypto(r.instrument, mapping: r.mapping)` (for the resolved registration — the split API in §1.3 removes the nil-mapping ambiguity).
- `removeRegistration(_:)` → `try await registry.remove(instrumentId: r.id)` then `await cryptoPriceService.purgeCache(instrumentId: r.id)`.
- `resolveToken(...)` unchanged — still calls `cryptoPriceService.resolveRegistration(...)`.
- API-key methods (`hasApiKey`, `saveApiKey`, `clearApiKey`) unchanged.

#### 3.4 `ProfileSession+Factories` wiring order

In the CloudKit branch of `makeBackend`:

```swift
let profileContainer = try! containerManager.container(for: profile.id)
let registry = CloudKitInstrumentRegistryRepository(modelContainer: profileContainer)
// onRecordChanged / onRecordDeleted are wired by CloudKitBackend's init so
// registry writes queue into the profile's CKSyncEngine. See §3.4.1.
let conversionService = FullConversionService(
  exchangeRates: exchangeRates,
  stockPrices: stockPrices,
  cryptoPrices: cryptoPrices,
  providerMappings: {
    try await registry.allCryptoRegistrations().map(\.mapping)
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

`ProfileSession` adds a stored property `let instrumentRegistry: (any InstrumentRegistryRepository)?`, populated from the CloudKit backend's new property for `.cloudKit` profiles and left `nil` for `.remote` / `.moolah` profiles. Crypto Settings views gate on this property being non-nil (see §3.6).

`ProfileSession.cryptoTokenStore` — today a non-optional `let cryptoTokenStore: CryptoTokenStore` — also becomes optional (`let cryptoTokenStore: CryptoTokenStore?`) because it now depends on the registry. For CloudKit profiles it is constructed with the registry and `cryptoPriceService`; for Remote/moolah profiles it is `nil`. Every existing caller of `session.cryptoTokenStore` must nil-check. The call-sites inside the existing `SettingsView` / `SettingsView+iOS` are already gated on `activeSession?.instrumentRegistry != nil` (§3.6), so in practice the nil-check collapses to a single guard at the navigation-link level; test fixtures and UITestSeedHydrator that previously constructed a `CryptoTokenStore` unconditionally are updated to do so only when the seeded profile has a CloudKit backend.

##### 3.4.1 Sync-queue hook wiring

`CloudKitBackend.init` wires the registry's sync-queue hooks to the profile's `SyncCoordinator`. `CloudKitInstrumentRegistryRepository` takes `onRecordChanged: @Sendable (String) -> Void` and `onRecordDeleted: @Sendable (String) -> Void` parameters in its initializer (matching the pattern used by `CloudKitTransactionRepository.onInstrumentChanged`). `CloudKitBackend` wires both to call `syncCoordinator.queueSave(recordName: id, zoneID: profileZoneID)` or the equivalent delete hook. Without this wiring, registry writes commit to SwiftData but never upload to CloudKit.

#### 3.5 Initial prefetch on session load

Wherever `ProfileSession` currently calls the zero-argument `cryptoPriceService.prefetchLatest()` at session load, replace with:

```swift
do {
  let regs = try await registry.allCryptoRegistrations()
  if !regs.isEmpty { await cryptoPriceService.prefetchLatest(for: regs) }
} catch {
  logger.warning(
    "Skipping crypto prefetch — registry read failed: \(error, privacy: .public)"
  )
}
```

Prefetch is best-effort, so the registry-read failure is logged but not rethrown; the rest of session setup proceeds. The log distinguishes "no registrations" from "read failure", which the zero-argument `prefetchLatest()` it replaces did not.

#### 3.6 `SettingsView` / `SettingsView+iOS` fallback paths

Both currently construct a fallback `CryptoPriceService` using `ICloudTokenRepository()` when `activeSession` is `nil`. After deletion of `ICloudTokenRepository`, those fallback paths will no longer compile. Resolution: **gate the Crypto Settings navigation on the active CloudKit-backed session's registry being available**, not on `sessions.values.first`.

- **iOS (`SettingsView+iOS.swift`).** Replace `cryptoTokenStoreForSettings` with the active session's `cryptoTokenStore`. The crypto navigation link is hidden entirely when `activeSession?.cryptoTokenStore == nil`, which covers "no active session" and "active session is a Remote/moolah profile". No fallback store is ever constructed.
- **macOS (`SettingsView.swift`).** The existing macOS code path that reads `sessionManager.sessions.values.first` is replaced with a lookup keyed on `profileStore.activeProfileID` — this picks the active profile's session, not an arbitrary one. The crypto section is hidden when that active session has no registry. This is important because a macOS user may have both a CloudKit and a Remote profile open simultaneously, and selecting "first" could incorrectly resolve to the Remote profile and surface the crypto settings for the wrong backend.

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

New file `MoolahTests/Domain/InstrumentRegistryRepositoryContractTests.swift`, run against `CloudKitInstrumentRegistryRepository` on in-memory SwiftData with captured sync-queue hooks:

- `all()` merges DB rows with ambient fiat ISO list; no duplicates.
- `all()` on a fresh profile contains every ISO currency from `Locale.Currency.isoCurrencies` and zero non-fiat entries.
- `all()` after `registerStock(_:)` includes the stock.
- `allCryptoRegistrations()` returns only crypto rows with at least one populated provider-mapping field.
- `registerCrypto(instrument, mapping:)` round-trips all eight crypto fields (id/kind/name/decimals/ticker/chainId/contract + three mapping fields).
- `registerCrypto` with a non-crypto instrument traps (documented programmer error; tested via `XCTExpectAssertionFailure`-style helper if present, otherwise noted in the spec and not unit-tested).
- `registerStock(instrument)` round-trips ticker+exchange without mapping fields; traps if given a non-stock instrument.
- `registerCrypto(existingId, newMapping)` upserts — re-registering a crypto instrument replaces the mapping and metadata fields rather than duplicating.
- `remove(id)` deletes the row; `remove(fiatId)` is a no-op.
- `remove(unknownId)` is a no-op and does not throw.
- Sync-queue hooks: `onRecordChanged` fires exactly once per successful `registerCrypto` / `registerStock`; `onRecordDeleted` fires exactly once per successful `remove` of a non-fiat id; neither fires for no-op calls (fiat register, unknown-id remove).
- Change-stream fan-out: two consumers that each called `observeChanges()` both receive a yield for a single `registerStock` call; a third consumer that cancels its iteration mid-test does not block or leak the continuation (the repository's fan-out dictionary drops it via the `onTermination` handler).
- Change-stream does not yield for no-op calls (unknown-id remove).
- Read failure: seeding a failure-injecting in-memory context and calling `all()` produces a thrown error (propagation contract, not silent empty).
- Corrupt row defence: an `InstrumentRecord` with `kind == "cryptoToken"` but all three provider-mapping fields `nil` (simulating an `ensureInstrument`-inserted row) is not returned from `allCryptoRegistrations()` and does not crash `all()`.

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
- `loadRegistrations()` surfaces a backing-store failure into the store's `error` property and does not leave `registrations` populated with stale data.
- `confirmRegistration()` writes through the registry (calls `registerCrypto`, not `registerStock`).
- `confirmRegistration()` failure surfaces into `error` and leaves in-memory state unchanged.
- `removeRegistration(_:)` removes from the registry **and** calls `cryptoPriceService.purgeCache(instrumentId:)`.
- `removeRegistration(_:)` failure surfaces into `error` and the price cache is not purged.
- `resolveToken(...)` path unchanged — assert it still produces a `resolvedRegistration` matching the resolver's output.

#### 6.6 Integration — `FullConversionService` via registry

End-to-end tests in `MoolahTests/Shared/`: with a `TestBackend`:

- **Happy path.** Register a crypto instrument via `registry.registerCrypto(_:mapping:)`, invoke `FullConversionService.convert(...)` for a crypto amount, assert the `providerMappings` closure resolved against the registry and the conversion produced the expected fiat value.
- **Missing mapping.** An `InstrumentRecord` with `kind == "cryptoToken"` but all mapping fields `nil` (simulating an `ensureInstrument`-auto-inserted row) does not appear in `allCryptoRegistrations()`; `FullConversionService.convert(...)` for that instrument throws `ConversionError.noProviderMapping(instrumentId:)` rather than silently returning a zero or stale value.
- **Registry failure.** Inject a failing registry (throws on `allCryptoRegistrations()`); `FullConversionService.convert(...)` for any crypto amount throws the underlying error (propagated via the `throws` closure) rather than silently degrading to an empty mapping table.

### 7. Rollout

#### 7.1 Branching

Feature work happens on `feat/instrument-registry` in `.worktrees/instrument-registry`. PR to `main` via the merge-queue skill. No direct pushes to `main`.

#### 7.2 PR shape

One coherent PR. The pieces are tightly coupled — removing `CryptoTokenRepository` requires both the registry implementation and the `CryptoPriceService` rewire to land together, or the build breaks mid-stack. The PR description explicitly lists these post-merge greps:

- `NSUbiquitousKeyValueStore` — zero hits anywhere.
- `CryptoTokenRepository` — zero hits.
- `ICloudTokenRepository` — zero hits.
- `com.apple.developer.ubiquity-kvstore-identifier` — zero hits in entitlements or scripts.

**CloudKit Dashboard schema deployment.** The three new `CKRecord` fields (`coingeckoId`, `cryptocompareSymbol`, `binanceSymbol`) must be visible in the CloudKit Production schema before the first production build is distributed, or CloudKit will silently drop them on upload. The rollout sequence is:

1. Land the PR on `main`; CI builds a TestFlight artefact.
2. On a TestFlight build against the Development environment, register one record carrying each of the three new keys (e.g. register Bitcoin with a full mapping).
3. In the CloudKit Dashboard, confirm the fields appear in the Development schema under `CD_InstrumentRecord`, then deploy the Development schema to Production.
4. Only after step 3 is a production build safe to distribute.

This is the standard procedure from `guides/SYNC_GUIDE.md` for adding fields to an already-synced record type.

**Conflict resolution for the new fields.** `InstrumentRecord` uses the existing server-wins strategy (via `handleSentRecordZoneChanges` → `SyncErrorRecovery.classify` → update-system-fields re-queue). Two devices concurrently registering the same crypto instrument produce one of two outcomes: identical mappings (benign, no semantic conflict — both devices independently derived the same provider ids from the same CoinGecko response) or differing mappings (last-writer-wins at the CloudKit level). Either outcome is acceptable; no per-field merge is needed. The spec does not introduce new conflict-resolution code.

#### 7.3 Follow-up GitHub issue

Filed before the implementation PR opens. Working title: **"Instrument registry UI: unified picker & call-site migration"**. Body sketch:

> Follow-up to the instrument-registry backend work (plans/2026-04-24-instrument-registry-design.md). The registry, repository, and search service now exist; the UI has not yet been updated to take advantage of them.
>
> **In scope for this issue**
>
> - Build a generic `InstrumentPicker` SwiftUI view that uses `InstrumentSearchService`.
>   - Shows the profile's registered instruments first, then on-type search results grouped by kind (Currency / Stock / Crypto).
>   - Selecting an unregistered crypto search result runs `TokenResolutionClient` then writes to the registry via `registerCrypto(_:mapping:)`.
>   - Selecting an unregistered stock result validates via `StockTickerValidator` then writes via `registerStock(_:)`.
>   - Fiat selection is always immediate (ambient).
> - Replace `CurrencyPicker` call sites with `InstrumentPicker` filtered to `.fiatCurrency`:
>   - Profile creation (`ProfileFormView`).
>   - Account creation / editing.
>   - Transaction forms where currency overrides the account.
> - Redesign the Crypto Settings "Add Token" flow to sit on top of `InstrumentSearchService` rather than the current contract-address form.
> - "Resolve mapping" affordance for crypto `InstrumentRecord` rows that exist but have no provider mapping (e.g. inserted by CSV import via `ensureInstrument`). When a position references such a row and the conversion service returns `ConversionError.noProviderMapping`, the picker exposes a "Resolve" action that runs `TokenResolutionClient` and upserts the mapping via `registerCrypto`.
> - Unified local + remote change signal so the picker updates when another device registers an instrument. Today `InstrumentRegistryRepository.observeChanges()` fires only for local writes; remote changes arrive through `CKSyncEngine` → `batchUpsertInstruments` and bypass the registry's fan-out. Bridge the two signals so the UI has a single subscription.
> - Find or integrate a stock-name source so stock search can match on company name, not just ticker.
>
> **Separate technical-debt issues to file alongside this one**
>
> - Fix the `Instrument.stock(ticker:exchange:name:decimals:)` id formula: it currently produces `"\(exchange):\(name)"` but the canonical id used throughout the picker design and CSV flow is `"\(exchange):\(ticker)"`. Align the factory, update all existing tests and call sites.
> - Remove `InstrumentRecord`'s hand-written init and `from(_:)` factory in favour of the synthesized memberwise init. After the three new fields land, the init has 11 parameters and is pure boilerplate.
>
> **Out of scope**
>
> - Server-side changes.
> - Remote / moolah-server profile support (single-instrument backends; registry doesn't apply).

The follow-up issue must be filed (and its number known) **before** the implementation PR lands, so that any `TODO(#N)` comments in the implementation code reference a real issue number per `guides/CODE_GUIDE.md` §20.

#### 7.4 Risk summary

- **Schema change** is additive and nullable; SwiftData lightweight migration covers it; CloudKit fields default to absent/nil.
- **Sync fan-out** — new fields are on an already-synced record type. The encode/decode extension and the `batchUpsertInstruments` field-copy block (§2 of the spec's sync notes and §1.1 encode/decode pattern) are the only sync-engine touches.
- **Deletion of `ICloudTokenRepository`** is pure subtraction; the only caller is `CryptoPriceService`'s init, which is also being changed. Compiler enforces the caller update.
- **Throwing `providerMappings` closure** changes the `FullConversionService.init` signature. All existing call sites of `FullConversionService.init` must be updated to pass a throwing closure (or `{ [] }` if they had no mappings source). This is surfaced as a compile error at every call site, so the migration cannot silently miss one.
- **Settings fallback gating** is the only user-visible behaviour change: crypto settings become unavailable when no CloudKit-backed profile is active.
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
