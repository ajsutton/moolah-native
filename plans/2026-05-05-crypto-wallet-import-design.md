# Crypto Wallet Auto-Import — Design Spec

**Status:** Draft · 2026-05-05
**Depends on (still-Draft):** `plans/2026-04-18-transfer-detection-design.md` — extended in §[Transfer-detection extension] below.
**Depends on (in production):** the multi-leg `Transaction` / `TransactionLeg` model, `Instrument` (with `cryptoToken` kind), `CryptoRegistration` + `CryptoProviderMapping` (stored in GRDB via `InstrumentRegistryRepository`), `CryptoPriceService`, `InstrumentConversionService`, `KeychainStore` with iCloud sync, `ImportOrigin` on `Transaction`, the CSV import pipeline (`Shared/CSVImport/`), the existing `URLSession`-based provider-client pattern (`Backends/CoinGecko/CoinGeckoClient.swift` is the canonical shape).

---

## Goal

Automatically populate a Moolah account with the live transaction history and current holdings of an Ethereum-family self-custody wallet, so the user sees current portfolio value per wallet and a complete, deduplicated transaction record across re-syncs without further action.

Crypto-exchange transactions (CoinStash, Binance, etc.) are **out of scope here** — exchanges import via the existing CSV pipeline. This design covers self-custody wallets only.

## Success criteria

- Adding a wallet account: the user pastes a `0x…` address, picks a chain, and within one sync cycle the account shows the full transaction history (subject to provider limitations) and current per-token positions.
- Re-syncs are idempotent: running the importer N times yields the same database state. Newly-observed on-chain transactions appear; existing transactions are unchanged unless rolled back by a chain reorg.
- A user-edited transaction (added category, edited payee/notes, added earmark) survives re-sync without losing the user's edits.
- Two tracked wallets transferring between each other produce a single two-leg transfer transaction (auto-merged on shared `txHash`), not two single-leg transactions in the suggestion inbox.
- A wallet that holds tokens with no available pricing displays correctly: the position is visible with quantity, the wallet's fiat total is computed without errors, and the unpriced token is surfaced for user triage.
- Discovering one spam token in a wallet does not break that wallet's running balance, total, or any other valuation calculation. **Critically:** an unpriced token reads as "fiat value = 0" at aggregation, not as "rate unavailable" — the two states must remain distinguishable so a real provider failure still marks affected totals unavailable.

## Scope

**In scope (v1):**

- Wallet auto-import via Alchemy on Ethereum, Optimism, Base, Polygon.
- New `AccountType.crypto`, treated as `.investment` for sidebar grouping and any `.investment`-filtering query (via `AccountType.isInvestmentLike`).
- Multi-leg transactions for on-chain events: a `.transfer` leg in the value token + an `.expense` leg in the chain native token for gas (when this wallet is the sender).
- Token discovery + auto-resolution via the existing `CryptoPriceService` resolution pipeline, coalesced through an `actor` so concurrent discoveries of the same token produce one registration.
- `pricingStatus` on `CryptoRegistration`: `.priced` / `.unpriced` / `.spam`. Conversion service returns a discriminated result so unpriced ≠ rate failure.
- Auto-classification: Alchemy `isSpam` → `.spam`; resolution success → `.priced`; otherwise `.unpriced`.
- Discovered Tokens inbox in the Crypto preferences tab.
- Sync triggers: app launch, scene-foreground, manual per-account refresh, hourly stale-check timer while running. macOS + iOS, foreground only.
- Reorg handling: re-fetch the last 32 blocks each cycle; additive reconciliation only.
- Transfer-detection extension: same-`txHash` + opposite-sign auto-merge across tracked accounts (no suggestion).
- Per-chain block-explorer deep-links from each transaction.
- API key management (single Alchemy key, synced Keychain).

**Out of scope (deferred to follow-up designs):**

- Bitcoin (different API surface, UTXO model).
- Arbitrum and other EVM chains beyond the v1 four (additive: extend `ChainConfig`).
- Internal transactions on Optimism / Base (Alchemy gap; user reconciles manually if they notice drift).
- NFT display or import (filtered out at fetch).
- DEX swap correlation and DeFi protocol grouping (each token movement appears as its own transaction or leg).
- Manual price entry for unpriced legit tokens (`.unpriced` ⇒ $0 fiat in v1).
- ENS/SNS resolution.
- iOS `BackgroundTasks` (no background sync — foreground only).
- Auto-detection of cross-chain bridge transfers (different Instruments → outside transfer-detection criteria).
- Tax / cost-basis reporting (separate future project; this design produces the underlying data).
- Etherscan V2 supplementary fetcher for missed internal transactions (deferred unless real users complain).

## Architecture overview

```
Alchemy (per chain: eth-mainnet, opt-mainnet, base-mainnet, polygon-mainnet)
   │  getAssetTransfers + getTokenMetadata
   ▼
AlchemyClient (Sendable struct holding URLSession + key — same shape as CoinGeckoClient)
   │  raw transfers + token metadata
   ▼
WalletSyncEngine (per-account orchestration; non-actor Sendable service)
   ├── CryptoTokenDiscoveryService (actor: in-flight Task coalescer + GRDB write)
   ├── TransferEventBuilder (group transfers by txHash → multi-leg events with gas)
   └── per-account: produces [BuiltTransaction]; does NOT persist
   ▼  (TaskGroup completes; ALL per-account results collected)
@MainActor sequential pass:
   ├── CrossAccountTransferMerger (same txHash + opposing legs → single transaction)
   ├── per-leg dedup against existing legs by (accountId, externalId)
   ├── persist via TransactionRepository (GRDB → CKSyncEngine to other devices)
   ├── ImportRulesEngine (existing) → user-facing payee / category / notes
   └── update WalletSyncState (per-device, GRDB-local, not synced)
```

The pipeline mirrors `Shared/CSVImport/` in shape: a per-source ingestion stage, a parser/builder, a dedup stage, then writes through the standard `TransactionRepository`. The orchestration store is `@MainActor`-isolated and owns the foreground sync timer.

**Key restructure (load-bearing for race-safety):** the parallel per-account work runs entirely as pure builds (no repository writes); the merge / dedup / persist / rules / state-update steps run as a single sequential `@MainActor` pass *after* the TaskGroup completes. This eliminates the race where two concurrent per-account syncs both create a "merged" transaction.

## Data model changes

### `AccountType.crypto`

Add the case alongside `.bank`, `.creditCard`, `.asset`, `.investment`. Add:

```swift
extension AccountType {
  /// Whether this type should be treated as an investment account for sidebar
  /// grouping and any query that filters investments. `true` for `.investment`
  /// and `.crypto`.
  var isInvestmentLike: Bool {
    self == .investment || self == .crypto
  }
}
```

Every existing site that compares `account.type == .investment` or filters by `.investment` is updated to use `isInvestmentLike` (or a `Set<AccountType>` containing both). This includes sidebar grouping, performance roll-ups, holdings views, and `AccountType.isCurrent`.

**Defensive enum decode (sync-safety):** the `Account` CloudKit/GRDB record mapper decodes `type` as a string. Implementation step 1 must update `AccountRow.fieldValues(from:)` (and the Codable path on `AccountType`) to provide a safe fallback for unrecognised type strings — map unknown to `.asset` and log a warning via `os.Logger`. This protects older app builds from crashing when they receive a `type = "crypto"` record from a newer device. The fallback is verified by a test that decodes a synthetic record with `type = "future-account-type"` and asserts no crash and a warning is logged.

### `Account` extensions for crypto

`Account` gains two optional fields:

- `walletAddress: String?` — `0x…` lowercased (case-insensitive checksum normalised on entry). Required when `type == .crypto`, nil otherwise.
- `chainId: Int?` — EVM chain ID (1, 10, 8453, 137). Required when `type == .crypto`, nil otherwise.

Form-layer validation enforces presence; persisted shape allows `nil` so non-crypto accounts pay no storage cost. CloudKit record mapping adds the two fields as additive optional fields.

The account's `instrument` is the chain's native Instrument (ETH for ETH/OP/Base, MATIC for Polygon) — set automatically at account creation, not user-pickable. Per-token positions emerge from leg aggregation as today.

### `TransactionLeg.externalId`

Add `externalId: String?` to `TransactionLeg`, grouped with the other `let`-typed identity fields (not the `var` user-annotation fields):

```swift
struct TransactionLeg: Codable, Sendable, Hashable {
  let accountId: UUID?
  let instrument: Instrument
  let quantity: Decimal
  let externalId: String?     // NEW: source-provided identifier (on-chain txHash for crypto)
  var type: TransactionType
  var categoryId: UUID?
  var earmarkId: UUID?
  // …
}
```

For wallet-imported legs, `externalId` is the on-chain `txHash`. **Per-leg dedup keys on `(accountId, externalId)`** — not on the transaction. This is the key idempotency mechanism: a wallet→wallet transfer auto-merged into a two-leg transaction has each leg carrying its own `externalId` (same hash on both, since same on-chain event), so re-imports see "leg already exists for this account+hash" and create nothing.

The gas leg on a multi-leg on-chain event carries the same `externalId` as the value-transfer leg (it's the same on-chain transaction). Dedup is on `(accountId, externalId)` regardless of leg type.

`ImportOrigin` (existing, on `Transaction`) carries the per-import audit context (raw quantities, parser identifier, sync session ID); `externalId` on each leg is the per-leg dedup key. The two play different roles and both are needed.

### `CryptoRegistration.pricingStatus`

Extend `CryptoRegistration` with a new `pricingStatus`:

```swift
enum TokenPricingStatus: String, Codable, Sendable {
  case priced     // provider mapping resolved; live price fetched
  case unpriced   // no provider mapping; treat as $0 fiat value (NOT a fetch failure)
  case spam       // hidden from UI; treat as $0 fiat value
}

struct CryptoRegistration: Codable, Sendable, Hashable, Identifiable {
  let instrument: Instrument
  let mapping: CryptoProviderMapping
  var pricingStatus: TokenPricingStatus    // NEW
  // …
}
```

**Storage:** existing GRDB-backed `InstrumentRegistryRepository` (`GRDBInstrumentRegistryRepository`) is extended — `pricingStatus` becomes a column on the underlying instrument-registry row. CKSyncEngine carries the field across devices via the existing instrument-registry sync path. **Built-in presets** ship with `.priced`. **Codable / column migration:** legacy rows decode as `.priced` (preserving existing behaviour); a one-shot GRDB migration adds the column with default `'priced'`.

**Cross-device conflict resolution.** A user can mark a token `.spam` on device A while device B's daily resolver flips the same token from `.unpriced` to `.priced`. CKSyncEngine's default "server wins" would let the resolver clobber the user's `.spam`. To prevent that, the GRDB sync handler that applies an incoming change for the instrument-registry row uses this merge rule:

| Local status | Incoming status | Result |
|---|---|---|
| `.spam` | any | **`.spam`** (user intent wins; never auto-revert) |
| any | `.spam` | `.spam` (accept user-intent from other device) |
| `.priced` | `.unpriced` | `.priced` (resolution success is sticky) |
| `.unpriced` | `.priced` | `.priced` (resolution success wins) |
| same | same | (no-op) |

Implemented in the GRDB+Sync apply-batch path for the instrument-registry record type.

### `WalletSyncState`

Per-device sync checkpoint. Stored in GRDB **without sync** (CKSyncEngine excludes it) — each device tracks its own Alchemy fetch progress. A device restored from backup with a stale local store will simply re-fetch from `lastSyncedBlockNumber - 32` (or from genesis if absent), which is exactly the right behaviour.

```swift
/// Per-device sync checkpoint for a wallet account. NOT synced cross-device.
/// `lastError` is a structured value, not a localised string — the store
/// formats it for display.
struct WalletSyncState: Codable, Sendable, Identifiable {
  let id: UUID                          // == account id; kept on this name for clarity
  var lastSyncedBlockNumber: UInt64
  var lastSyncedAt: Date
  var lastError: WalletSyncError?
}

enum WalletSyncError: Codable, Sendable, Hashable {
  case missingApiKey
  case invalidApiKey
  case rateLimited(retryAfter: Date?)
  case network(underlyingDescription: String)
  case providerMalformedResponse(stage: String)
}

protocol WalletSyncStateRepository: Sendable {
  /// Loads checkpoints for every wallet account on this device.
  /// Used by `CryptoSyncStore` at app launch to pick stale accounts.
  func loadAll() async throws -> [WalletSyncState]
  /// Loads the checkpoint for a single account, or nil if never synced.
  /// Used per-sync-cycle to read `lastSyncedBlockNumber`.
  func load(accountId: UUID) async throws -> WalletSyncState?
  /// Persists the checkpoint, upserting on `accountId`. Called once per
  /// sync cycle on success, and after a failed cycle to record `lastError`.
  func save(_ state: WalletSyncState) async throws
  /// Removes the checkpoint for an account. Called when the account is
  /// deleted; idempotent — succeeds with no effect when no checkpoint exists.
  func delete(accountId: UUID) async throws
}
```

**Storage:** new GRDB table `wallet_sync_state`, marked excluded from CKSyncEngine (per-device only). Production `GRDBWalletSyncStateRepository`; test `InMemoryWalletSyncStateRepository`. Added to `BackendProvider` as `walletSyncState: any WalletSyncStateRepository` so feature code accesses it via `@Environment(BackendProvider.self)` like every other repository.

`Domain/Models/WalletSyncState.swift` and `Domain/Repositories/WalletSyncStateRepository.swift` import only `Foundation` — no presentation strings, no backend types.

## Token discovery & classification

When `WalletSyncEngine` encounters a token Instrument that has no `CryptoRegistration`, it requests resolution from `CryptoTokenDiscoveryService`. To prevent duplicate `CryptoRegistration` creates for the same `(chainId, contractAddress)` from concurrent transfers (across the parallel per-account TaskGroup), the discovery service is an `actor` using the in-flight task coalescer pattern:

```swift
actor CryptoTokenDiscoveryService {
  private var inFlight: [Instrument.ID: Task<CryptoRegistration, Error>] = [:]
  private let registry: InstrumentRegistryRepository
  private let priceService: CryptoPriceService
  private let alchemy: AlchemyClient

  func resolveOrLoad(
    chainId: Int, contractAddress: String?, symbol: String, name: String, decimals: Int
  ) async throws -> CryptoRegistration {
    let id = Instrument.crypto(/*…*/).id
    if let existing = try await registry.cryptoRegistration(byId: id) { return existing }
    if let task = inFlight[id] { return try await task.value }

    let task = Task<CryptoRegistration, Error> { try await performResolution(/*…*/) }
    inFlight[id] = task
    do {
      let result = try await task.value
      inFlight[id] = nil      // serialised on actor — safe without an extra Task
      return result
    } catch {
      inFlight[id] = nil
      throw error
    }
  }
}
```

Resolution algorithm (`performResolution`):

1. Construct the Instrument via `Instrument.crypto(chainId:contractAddress:symbol:name:decimals:)` from Alchemy's transfer metadata.
2. Run resolution via the existing `CryptoPriceService` pipeline (CoinGecko by contract → CryptoCompare coin list → Binance pair).
3. Query Alchemy's `getTokenMetadata` for the `isSpam` flag.
4. Persist a new `CryptoRegistration` via `InstrumentRegistryRepository`:
   - `pricingStatus = .spam` if `isSpam == true`.
   - `pricingStatus = .priced` if any provider mapping was resolved (and not flagged spam).
   - `pricingStatus = .unpriced` otherwise.
5. New `.unpriced` registrations surface in the Discovered Tokens inbox.

**Periodic re-resolution:** at most once per day per token (gate on `lastResolutionAttemptAt`), every `.unpriced` registration re-runs resolution as part of the daily sync cycle. If a provider now returns a result, status flips to `.priced` and any cached conversions for the affected instrument are invalidated (see §[Instrument conversion semantics]).

**Status transitions back to `.unpriced`** (e.g. provider stops returning the token): out of scope. Resolution success is sticky-positive.

## Sync engine

### Sync trigger taxonomy

| Trigger | Behaviour |
|---|---|
| App launch | Sync any crypto account whose `lastSyncedAt` is older than 24 h. |
| Scene → `.active` (background→foreground transition on iOS, focus on macOS) | Same as launch. |
| User taps "Sync now" on an account | Sync the requesting account regardless of staleness. |
| Hourly stale-check timer (foreground only) | Every hour, sync any account whose `lastSyncedAt` is older than 24 h. |

The hourly timer is a single `Task` (`timerTask`) owned by `CryptoSyncStore`. The store observes `scenePhase` and:

1. On `.active`: cancels any prior `timerTask` (`timerTask?.cancel()`), then assigns a new `Task { await runTimerLoop() }` to `timerTask`.
2. On `.background` / `.inactive`: cancels `timerTask` and assigns `nil`.
3. The loop body checks `Task.isCancelled` immediately after every `Task.sleep(for:)` suspension before dispatching the next sync batch and before sleeping again. A cancelled task exits cleanly without writing state.
4. The loop body wraps the per-tick sync work in `Task.checkCancellation()` at the start so a late cancellation doesn't leak a fetch.

`BackgroundTasks` (`BGAppRefreshTask`) is explicitly out of scope.

### Sync algorithm

The algorithm is split into two phases — a **parallel build phase** (per account, no shared writes) and a **sequential apply phase** (single `@MainActor` pass) — to eliminate the cross-account merge race.

```text
PARALLEL BUILD (withTaskGroup; up to 4 concurrent per-account tasks):
  For each stale account in this sync cycle:
    1. Load WalletSyncState for this account.
    2. fromBlock = max(0, lastSyncedBlockNumber - 32)            ← reorg window
    3. Call alchemy_getAssetTransfers (twice — fromAddress + toAddress) on this chain:
         fromBlock = fromBlock, toBlock = "latest"
         category  = ["external", "erc20"] + (["internal"] iff chain ∈ {ethereum, polygon})
    4. Group transfers by txHash → events.
    5. For each event:
        a. For each transferred token: ensure CryptoRegistration exists via
           CryptoTokenDiscoveryService.resolveOrLoad(...) (actor-coalesced).
        b. Construct legs: one .transfer leg per token movement involving this wallet,
           plus one .expense gas leg in the chain native token (only on the from-side wallet).
        c. Each leg's externalId = the event's txHash.
        d. Build a candidate Transaction with these legs; set ImportOrigin
           (raw fields, sync session ID).
    6. RETURN [BuiltTransaction] for this account. NO repository writes here.

SEQUENTIAL APPLY on @MainActor (after TaskGroup completes; one batch):
  Collect = union of all per-account [BuiltTransaction] from the build phase.
  7. Cross-account auto-merge pass: for each event in Collect, find any other event in
     Collect (or any existing leg in the repository) with a matching transfer-leg
     externalId, opposing-sign quantity, same instrument, on a different account.
     Merge into a single transaction whose legs union both sides; gas legs preserved.
  8. Per-leg dedup against existing TransactionLegs by (accountId, externalId).
     Skip duplicates.
  9. Persist new transactions through TransactionRepository (single batch where possible).
 10. Run ImportRulesEngine over new transactions (payee / category / notes).
 11. For each successfully-synced account: update WalletSyncState
     { lastSyncedBlockNumber = head, lastSyncedAt = now, lastError = nil }.
     Where `now` is supplied by an injected `clock: () -> Date` (the store passes
     `{ Date() }`; tests pass a pinned clock).
```

Per-account failures in the build phase don't abort the cycle — failed accounts produce no `BuiltTransaction` and have `lastError` set in step 11 instead. Other accounts still apply normally.

### Reorg handling

The fetch always covers `[lastSyncedBlockNumber - 32, head]`. Per-leg `(accountId, externalId)` dedup means previously-imported, still-canonical transactions are no-ops. A transaction rolled back by a reorg simply won't appear in the new fetch.

**Reconciliation in v1 is additive only.** We do **not** remove a previously imported transaction even if it disappears from a subsequent fetch. Rationale: silent deletion of a user-categorised transaction is far worse than the rare drift on a deep reorg; the user can delete manually if they ever notice. A future v2 could mark suspect transactions for review, but the cost/value isn't there yet.

### NFT filtering

Alchemy's `getAssetTransfers` accepts a `category` parameter. We pass `["external", "erc20"]` (plus `"internal"` on supported chains). NFT categories (`erc721`, `erc1155`, `specialnft`) are deliberately excluded — they're not value flows in the financial sense and out of scope for v1. They never reach the importer.

## Transfer-detection extension

The current draft (`plans/2026-04-18-transfer-detection-design.md`) constrains pairing candidates to single-leg transactions. A wallet-side multi-leg event (transfer leg + gas leg) would be excluded. Two extensions are needed:

### Extension A — eligibility predicate

> A transaction is *transfer-detection-eligible* iff it has exactly one leg of type `.transfer` (the "value-bearing leg") **or** exactly one leg of type `.income`/`.expense` (legacy single-leg cash). Any number of additional `.expense` legs in a different instrument from the value-bearing leg are permitted (these are fees: gas, broker fees, …).

This preserves the existing intent (exclude trades — they have two `.trade` legs and don't meet the new criterion either) while enabling on-chain transfers with gas, and brokerage cash transactions that happen to carry an attached fee leg, to participate. Detection's amount/instrument matching always operates on the **value-bearing leg**.

### Extension B — deterministic same-`externalId` channel

> Before the standard amount/instrument/date suggestion pass runs, the importer (CSV or crypto) checks for cross-account legs with matching `externalId`. When two transfer-detection-eligible transactions on different tracked accounts have value-bearing legs with the same non-nil `externalId`, the same instrument, and opposite-sign quantities, they are merged immediately into a single multi-leg transfer transaction with **no suggestion** and no inbox row. Each side's fee legs (gas) are preserved on the merged transaction.

A merged on-chain transfer therefore has shape `[transfer leg from A, transfer leg from B, optional gas leg from A, optional gas leg from B]` — the existing multi-leg storage handles this directly.

The standard suggestion flow continues to handle fuzzy matches (CSV from an exchange ↔ on-chain wallet, where the on-chain hash isn't on both sides). Shared `externalId` is a strict superset of the existing pairing — there's no false-positive channel to add.

**Unmerge / dismissed-pair semantics** carry over from the existing design unchanged.

The transfer-detection design doc must be updated with these two extensions before either CSV or crypto import implements the same-`externalId` channel.

## CloudKit sync interaction

This design adds three classes of changes to data that already syncs via `CKSyncEngine`:

1. **`Account` gains `walletAddress` and `chainId`.** The `Account` CloudKit record (via `AccountRow` in GRDB and the corresponding `AccountRecordCloudKitFields`) gains two new optional fields — `walletAddress: STRING?` and `chainId: INT?`. Schema added to `CloudKit/schema.ckdb`; generated wire layer regenerated via `just generate` (per `modifying-cloudkit-schema` skill). Old records decode with `nil`.

2. **`TransactionLeg.externalId`.** `TransactionLeg` is its own CloudKit record type (`TransactionLegRow` in GRDB; `TransactionLegRecordCloudKitFields` for sync), **not** an embedded field on `Transaction`. The `externalId: STRING?` field is added at the leg-record level in `schema.ckdb`, the generated wire struct, the `toCKRecord` / `fieldValues(from:)` mappers, and the `applyBatchSaveTransactionLeg` upsert path. Old records decode with `nil`. Implementation step 1 explicitly enumerates these touch points to ensure none is skipped.

3. **`CryptoRegistration.pricingStatus`** (in the GRDB instrument-registry row, synced via the existing instrument-registry CKSyncEngine path). Schema column added; record mapping updated; sync apply-batch handler implements the merge rule from §[Data model changes]. Built-in presets and legacy rows default to `.priced`.

4. **No new record types.** `WalletSyncState` is per-device and excluded from CKSyncEngine. No new sync zones or conflict-resolution code beyond the `pricingStatus` merge rule.

The crypto importer **writes through the same `TransactionRepository`** every other write path uses. `CKSyncEngine` then picks the new `Transaction` and `TransactionLeg` records up and pushes them to other devices like any other write.

### Multi-device race window — honest description

Per-leg `(accountId, externalId)` dedup is the right idempotency mechanism *within a single device*. Across devices, dedup is **eventually consistent**, not atomic:

- Device A and device B both run a wallet sync concurrently before either has received the other's CKSyncEngine push.
- Each device independently fetches Alchemy data, runs steps 7–9 of the sync algorithm, and writes its own `Transaction` + `TransactionLeg` rows for the same on-chain hash.
- Both devices push their writes to CKSyncEngine. The two sets of records have different UUIDs and so do not conflict at the CKRecord level — they coexist as duplicates.
- Each device subsequently receives the other's records. The applied records arrive as fresh `TransactionLegRow` upserts keyed by their UUID primary keys; **the upsert path does not re-run the `(accountId, externalId)` dedup** (that check lives only in `WalletSyncEngine` step 8 on the import path).

**Result:** in the rare case of true cross-device simultaneity, the user ends up with two `Transaction` rows pointing at the same on-chain `txHash` until cleanup.

**v1 cleanup mechanism.** A post-CKSyncEngine-fetch reconciliation pass — `CrossDeviceLegDeduper` — runs on `@MainActor` after every CKSyncEngine `fetchedRecordZoneChanges` callback. It scans for `TransactionLegRow` groups sharing `(accountId, externalId)` where both are non-nil and reduces each group to one canonical leg (lowest UUID by lexical order — deterministic on every device, so both devices converge on the same canonical leg). Orphaned `Transaction` rows whose legs were all collapsed into another transaction are deleted.

**Critical implementation detail:** the deduper performs all deletions through `TransactionRepository.delete(id:)` (and the corresponding leg-delete repository method), **not** by writing directly to GRDB. This routes every delete through the repository's existing CKSyncEngine `onRecordDeleted` hook so the change propagates to other devices' CKSyncEngine state. Bypassing the repository would silently desync the deduper's local cleanup from CloudKit.

This is a small, bounded sweep — it runs only when CKSyncEngine reports new records, only on legs with a non-nil `externalId`, and the deterministic tiebreak ensures the two devices reach the same end state without further coordination.

**User-deletion edge case.** If a user deletes the canonical leg (the one with the lowest UUID) on device A while device B still has its non-canonical duplicate, the next CKSyncEngine fetch on device B will not see the deleted leg, and B's deduper will promote its surviving leg to canonical. CKSyncEngine then propagates that to A, where the deduper does nothing (only one leg exists). Result: the original delete is effectively reversed by the duplicate's promotion. This is correct *additive-only reconciliation* behaviour — the user's intent ("delete this on-chain event") is preserved on whichever device they re-delete from. The same is true of any other delete that races with a duplicate. v1 accepts this; revisit only if it's confusing in practice.

Tested explicitly: simulate two-device race → both devices converge to one `Transaction` row with one leg per account.

### Privacy-classified logging

`os.Logger` calls in the sync path follow `guides/SYNC_GUIDE.md` privacy rules:

| Field | Privacy | Rationale |
|---|---|---|
| Token symbol (e.g. "USDC") | `.public` | Public token identifier, not user-specific. |
| Contract address (e.g. "0xa0b8…") | `.private` | A contract address in a log (combined with the device) lets a log reader infer which tokens this user holds. Conservative default. |
| Wallet address | `.private` | Public on-chain data, but pairing it with the device identifies the user's holdings. |
| Chain ID | `.public` | Numeric, not user-specific. |
| Sync block numbers | `.public` | Public chain data. |
| API key | Never logged at any level. |

## Concurrency model

Per `guides/CONCURRENCY_GUIDE.md`:

- **`CryptoSyncStore`** (in `Features/Crypto/`) is `@MainActor @Observable`. Owns `timerTask: Task<Void, Never>?`, the `scenePhase` observation, the per-account "Sync now" command, and the injected `clock: () -> Date`. Holds observable state for sync progress and errors. Receives `BackendProvider` via `@Environment` and reads `walletSyncState`, `transactions`, etc. from it.

- **`WalletSyncEngine`** is a `Sendable struct` — not a class, not an actor. (`struct` chosen over `final class` because all stored properties are themselves `Sendable` references, so implicit `Sendable` synthesis applies and there's no need for justifying a `final class` per CONCURRENCY_GUIDE §2.) Stored properties (all `Sendable`):
  - `let alchemy: AlchemyClient` (Sendable struct, see below)
  - `let discovery: CryptoTokenDiscoveryService` (actor reference)
  - `let rateLimiter: RateLimiter` (actor reference)

  No mutable state on the engine itself. Per-account sync runs as a structured `Task` inside the store's `withTaskGroup`. The engine's per-account method returns `[BuiltTransaction]` and writes nothing.

- **`AlchemyClient`** is a `Sendable struct` holding `URLSession` and the API key — same shape as `Backends/CoinGecko/CoinGeckoClient.swift`. No `APIClient` wrapper (that pattern doesn't exist in this codebase; the project's network clients consistently use `URLSession` directly behind a domain-specific protocol). Calls go through `RateLimiter` for throttling.

- **`actor RateLimiter`** — token-bucket, 25 req/s (Alchemy free tier). Blocks the caller's `Task` until a token is available.

- **`actor CryptoTokenDiscoveryService`** — in-flight task coalescer (see §[Token discovery & classification] for the full pattern). The actor serialises the "check repository → launch resolution → store result" critical section so two concurrent callers for the same `(chainId, contractAddress)` produce one `CryptoRegistration`, not two.

- **All repository writes** happen on `@MainActor`, matching project convention. The single sequential apply phase (steps 7–11 of the sync algorithm) runs on `@MainActor` end-to-end.

- **Cross-account auto-merge** runs as part of the single `@MainActor` apply pass *after* the parallel build TaskGroup has fully completed and all `[BuiltTransaction]` results have been collected. There is no concurrent path that can produce duplicate merged transactions.

- **Hourly timer cancellation** — see §[Sync trigger taxonomy] for the explicit cancellation contract.

No callbacks, no completion handlers, no `Task.detached`, no `@unchecked Sendable`. All long-running work is structured concurrency.

## Instrument conversion semantics

Per `guides/INSTRUMENT_CONVERSION_GUIDE.md` (the load-bearing piece for the user's stated concern about not conflating "unpriced" with "rate unavailable"):

### Discriminated rate result — not a plain `Decimal`

`CryptoPriceService.priceUSD(for:on:)` is changed to return a discriminated result:

```swift
enum CryptoPriceLookup: Sendable {
  case priced(Decimal)         // real provider rate
  case knownZero               // token is .unpriced or .spam — value is intentionally 0
  // (failure is still represented by a thrown error, as today)
}

extension CryptoPriceService {
  func priceLookup(for instrument: Instrument, on date: Date) async throws -> CryptoPriceLookup
}
```

The conversion service distinguishes the three states:

- **`.priced(rate)`** — multiply leg quantity by `rate` as today. Use in any aggregation.
- **`.knownZero`** — the leg's fiat contribution is exactly `0`. Aggregations include the position with `0` fiat value; running balance and totals continue normally; the position remains visible in the position list with its native quantity.
- **Thrown error** — provider failure / network issue. Per existing `INSTRUMENT_CONVERSION_GUIDE.md` Rule 11: caller marks the affected total *unavailable*, surfaces the error, and does **not** substitute `0`.

This discrimination is the load-bearing fix for the user's stated concern: `.unpriced` and `.spam` tokens never enter the "rate unavailable" path, and a real provider failure for a `.priced` token is never silently zeroed.

`InstrumentConversionService` exposes a parallel discriminated method (`convert(...) -> ConversionResult` returning `.value(InstrumentAmount)` / `.knownZero(targetInstrument)` / throws) so all aggregation code paths — wallet totals, sidebar grouping, P&L, expense breakdown, capital-gains — handle the three cases explicitly.

### Multi-instrument leg arithmetic

A wallet transaction has potentially mixed-instrument legs: a `.transfer` leg in (say) USDC plus a `.expense` gas leg in ETH. A merged cross-account transfer can have four legs across two instruments (`USDC` and `ETH`) and two accounts. Per `INSTRUMENT_CONVERSION_GUIDE.md` Rule 1, summing `InstrumentAmount` values across mismatched instruments traps. All aggregation paths must therefore convert each leg individually to the target instrument **before** any sum.

Implementation step 1 includes an audit task: enumerate every site that does `legs.reduce(...)`, `legs.map(\.amount).reduce(...)`, or similar, and verify each goes through `InstrumentConversionService` per leg. New sites added as part of this design (wallet account total, transaction display amount for multi-instrument crypto txs, performance roll-ups for `.crypto` accounts) are written using the discriminated `convert(...)` from above. Existing sites that already operate on single-instrument transactions are flagged in the audit; any that turn out to be unsafe for multi-instrument input are fixed as part of this work.

### Conversion-date discipline

- Per-leg display amounts on a transaction row use the leg's transaction date (historic) — same as stocks, fiat, and existing crypto.
- Running balance on the transaction list uses `Date()` (the existing `INSTRUMENT_CONVERSION_GUIDE.md` Rule 5 carve-out so balances tie out to the live account total).
- Wallet account total in the sidebar uses `Date()`.
- Discovery resolution probes go through `InstrumentConversionService` (the canonical conversion seam, per Rule 4) at `Date()`, not directly through `CryptoPriceService`. The discovery service uses the same probe path as any other "is this instrument priceable today?" check; centralising on the seam keeps the date and dispatch decisions consistent and avoids parallel conversion stacks.

### Cache invalidation on `pricingStatus` change

Any user action that changes a `pricingStatus` (`.spam` → `.unpriced`, `.unpriced` → `.spam`, manual re-resolve flipping `.unpriced` → `.priced`) invalidates the `InstrumentConversionService` cache for the affected instrument before returning to the caller. The store mutation method (`CryptoTokenStore.setStatus(_:for:)`) calls `conversionService.invalidateCache(for: instrument)` synchronously after persisting the new status. Tests verify that un-spamming a token causes balance recomputation rather than serving stale `.knownZero` results.

## API key management

A single Alchemy API key is stored via the existing `KeychainStore` with iCloud sync (`kSecAttrSynchronizable: true`, accessibility `kSecAttrAccessibleAfterFirstUnlock`). Service: `"com.moolah.api-keys"`. Account: `"alchemy"`.

The Crypto preferences tab (existing `Features/Settings/CryptoSettingsView.swift`) gains:

- An **Alchemy API key** field with status (valid / invalid / not set). "How to get a key" link (Alchemy free-tier signup).
- A list of crypto accounts with last-sync timestamp and per-account "Sync now" button.
- The Discovered Tokens inbox.

Without a valid key, sync is disabled with an inline prompt to add one. New crypto accounts can still be created (so the user can stage them), but won't sync until the key is set.

## UI surface

### Account creation

Selecting `.crypto` from the account-type picker presents:

- **Name** (free-form, e.g. "Hardware Wallet — Ethereum").
- **Chain** picker (Ethereum / OP Mainnet / Base / Polygon).
- **Wallet address** field (validated `0x…` 42 chars, lowercased; checksum tolerated). Pasting an ENS name shows "ENS resolution not supported in v1 — paste a 0x address".

The account's `instrument` is set automatically to the chain's native token. Per-token positions are computed from imported legs.

### Wallet account view

Same overall shape as an investment account, with:

- Header: truncated wallet address with copy button + chain name.
- "Last synced" timestamp + "Sync now" button.
- "View on block explorer" link in the account's overflow menu (chain-aware URL builder).
- Standard transaction list, position list, performance section.

### Transaction detail (crypto)

Standard fields plus, on each leg with an `externalId`:

- "View on block explorer" link → `etherscan.io/tx/<hash>` etc. (per-chain via `BlockExplorerLink`).
- Counterparty address — truncated, copyable, **not** rendered as a clickable URL (we don't make arbitrary on-chain addresses look authoritative).

Counterparty address is captured into a new `Transaction.notes` line at import time when the tx has a clear single counterparty (e.g. "From: 0xabc…"). Storing it as a structured field on `TransactionLeg` would be cleaner but is deferred until UX warrants — keeping the data-model surface tight.

### Discovered Tokens inbox

Lives in the Crypto preferences tab. Lists every `CryptoRegistration` with `pricingStatus == .unpriced`. Each row:

- Token symbol, name, chain, contract address (truncated).
- "Held by N accounts · X transactions" hint.
- Actions: **Mark as spam** (status → `.spam`, hides everywhere, invalidates conversion cache). **Re-resolve now** (re-runs the resolution pipeline; on success, invalidates conversion cache).
- Future: **Set manual price** (deferred to v2; out of v1 scope).

Sidebar/preferences badge surfaces the count when > 0.

### Spam tokens management

A separate "Marked as spam" section in Crypto preferences lists tokens with `pricingStatus == .spam`. Toggling back to `.unpriced` un-hides them and invalidates the conversion cache so historical balances recompute. This is the recovery path if Alchemy's `isSpam` mis-flags a legit token.

## Privacy & security

- API key in synced Keychain only. Never written to UserDefaults, files, logs, CloudKit records, or error reports.
- Wallet addresses are public on-chain data. Storing in the `Account` row (and therefore in CloudKit) is acceptable.
- Network calls go device → Alchemy directly. Alchemy sees device IP ↔ wallet address. Acceptable trade-off for personal-use scope; surfaced in Crypto preferences "About" copy.
- No third-party analytics on crypto sync.
- `KeychainStore` accessibility: `kSecAttrAccessibleAfterFirstUnlock` so foreground sync immediately after device boot works.
- `os.Logger` privacy classifications: see the table in §[CloudKit sync interaction] for the per-field rationale. Contract addresses are deliberately `.private` despite being public on-chain data — pairing them with a device identifier in logs would let a log reader infer holdings.

## Error handling

| Condition | Surface | Recovery |
|---|---|---|
| No Alchemy key configured | "Add API key" prompt in Crypto preferences and on every crypto account view. | User adds key in preferences. |
| Alchemy key rejected (401) | Persistent banner in Crypto preferences with the specific error. Sync skipped until fixed. `WalletSyncState.lastError = .invalidApiKey`. | User re-enters or rotates key. |
| Rate limit (429) | Per-account exponential backoff (1s, 2s, 4s, 8s; max 4 retries). After exhaustion, account marked `.rateLimited(retryAfter:)`. | Manual refresh available; auto-retry on next trigger. |
| Network failure | `WalletSyncState.lastError = .network(...)`. Last-synced timestamp surfaces staleness. | Manual refresh; auto-retry on next trigger. |
| Provider returns malformed token metadata | Skip that transfer in this sync, log a warning via `os.Logger` (token symbol `.public`, contract address `.private`), continue. `WalletSyncState.lastError = .providerMalformedResponse(stage:)`. | Will be retried in the next sync cycle (within reorg window). |
| Token resolution failure (no provider returns the contract) | Status `.unpriced` (NOT an error, NOT a `WalletSyncState.lastError`). Surfaced in Discovered Tokens inbox. | Periodic re-resolution; user can mark spam or wait. |
| Conversion failure for a `.priced` token (provider down) | Existing conversion-service behaviour: leg display amount `nil`, banner suggests retry. NOT confused with `.knownZero` from `.unpriced` / `.spam`. | User retries; cache fallback. |
| Cross-device race on the same wallet | See §[Multi-device race window] above. `CrossDeviceLegDeduper` collapses duplicates after CKSyncEngine fetch. | Automatic. No user action. |

## Testing

TDD throughout. Tests use `TestBackend` (CloudKitBackend with in-memory containers) for store/repository tests, pure unit tests for clients and builders, fixture JSON for Alchemy responses. Per `guides/TEST_GUIDE.md` and `guides/UI_TEST_GUIDE.md`.

1. **`AlchemyClient` tests** — request shape per chain (network slug, fromBlock, address, category list — including the chain-conditional `internal` inclusion), response decoding for all transfer categories, error mapping (401 / 429 / 5xx / network).
2. **`AccountType` decode tests** — unrecognised type string decodes to `.asset` and emits a single warning log; recognised types decode unchanged.
3. **`CryptoTokenDiscoveryService` tests** — new token landing produces a `CryptoRegistration` with the right status; `isSpam` honoured; resolution-success transitions `.unpriced` → `.priced`; periodic re-resolution rate-gated; **two concurrent `resolveOrLoad` calls for the same `(chainId, contractAddress)` produce exactly one `CryptoRegistration` and one network round-trip** (in-flight coalescer behaviour).
4. **`pricingStatus` cross-device merge tests** — local `.spam` survives an incoming `.priced` change; incoming `.spam` overrides any local status; `.priced` always wins over `.unpriced`.
5. **`TransferEventBuilder` tests** — single-token send produces transfer leg + gas leg with same `externalId`; ERC-20 send same; receive-only event produces single transfer leg with no gas; coincident events on same hash get one transaction with multiple transfer legs.
6. **Reorg tests** — second sync covering overlapping blocks produces no duplicates (per-leg dedup). Rolled-back transaction (absent from second fetch) not deleted.
7. **`CrossAccountTransferMerger` tests** — two tracked wallets, same hash, opposing legs → single multi-leg transfer transaction; gas legs preserved; `ImportOrigin` reflects both sides; **the merge runs only after the parallel build phase completes** (test verifies the algorithm structure, not just outcome).
8. **`CrossDeviceLegDeduper` tests** — simulate two-device race producing duplicate `Transaction` + `TransactionLeg` rows; both devices' deduper passes converge on the same canonical leg by deterministic UUID tiebreak; orphaned transactions deleted.
9. **User-edit preservation** — edit category on imported tx; re-sync; verify category preserved (per-leg dedup → leg already exists → no overwrite).
10. **Discriminated conversion-result tests** — `.unpriced` token → `priceLookup` returns `.knownZero` (no throw, distinct from rate failure); `.spam` → `.knownZero`; `.priced` → `.priced(rate)`; provider failure for `.priced` token → throws; aggregations correctly handle all three (known-zero contributes 0; failure marks total unavailable). Test names assert that "unpriced" and "rate unavailable" produce different observable effects on the wallet total.
11. **Multi-instrument leg arithmetic tests** — a four-leg merged transfer (USDC transfer + ETH gas, two accounts) sums correctly without trapping; aggregations convert per-leg before summing.
12. **Cache invalidation on `pricingStatus` change** — set token to `.priced`, compute wallet total (cached), flip to `.spam`, observe wallet total recomputes (not stale).
13. **Sync trigger tests** — launch fires sync for stale accounts; foreground re-creates `timerTask` after cancellation; manual refresh fires for one account; backgrounded scene cancels `timerTask`; cancelled timer task exits cleanly without writing state.
14. **Transfer-detection eligibility tests** — multi-leg with one transfer + fee leg eligible; two-`.trade`-leg trade ineligible; existing two-`.transfer`-leg transfer ineligible (already a transfer).
15. **Clock-injection tests** — `WalletSyncEngine.sync(...)` is called with a pinned `clock`; `WalletSyncState.lastSyncedAt` exactly matches the pinned date.
16. **End-to-end (TestBackend)** — fixture sync produces correct positions, balances, transactions; second sync is a no-op; cross-device race produces no permanent duplicates after the deduper runs.

Fixture Alchemy responses live in `MoolahTests/Support/Fixtures/alchemy/` keyed by chain + scenario (`eth-simple-eth-send.json`, `op-erc20-transfer.json`, `polygon-spam-airdrop.json`, …).

## Benchmarks

Per `guides/BENCHMARKING_GUIDE.md`. New entries:

- `cryptoSync_singleWallet_500txs` — full sync of one wallet with 500 historical txs.
- `cryptoSync_5wallets_parallel` — concurrent sync of 5 accounts.
- `cryptoSync_dedup_500new_against_5000existing` — re-sync overhead.
- `cryptoSync_tokenDiscovery_50newtokens` — discovery + resolution overhead.
- `cryptoSync_crossDeviceDeduper_100duplicates` — deduper sweep cost.

Signpost boundaries at each pipeline stage (`os_signpost(.begin/.end)` on Alchemy fetch, transfer building, dedup, persistence, rules engine, deduper). No optimisation work until a benchmark or user report shows a real problem.

## Integration with existing architecture

| Layer | Files | Purpose |
|---|---|---|
| Domain/Models | `WalletSyncState.swift` (new); `WalletSyncError.swift` (new); extensions to `Account.swift`, `AccountType` (`isInvestmentLike`, `.crypto`), `CryptoRegistration.swift` (`pricingStatus`), `TransactionLeg.swift` (`externalId`) | Persistent + audit types. No display strings, no backend imports. |
| Domain/Repositories | `WalletSyncStateRepository.swift` (new); `BackendProvider.swift` extended with `walletSyncState: any WalletSyncStateRepository` | Per-account sync checkpoint CRUD; DI integration |
| Shared/CryptoImport | `AlchemyClient.swift` (Sendable struct, URLSession-based — same shape as `CoinGeckoClient`), `WalletSyncEngine.swift`, `TransferEventBuilder.swift`, `CryptoTokenDiscoveryService.swift` (actor), `CrossAccountTransferMerger.swift`, `CrossDeviceLegDeduper.swift`, `ChainConfig.swift`, `BlockExplorerURL.swift`, `RateLimiter.swift` (actor) | Pipeline stages and helpers. Imports Foundation (which provides `URLSession` on Apple platforms). |
| Shared (existing) | `CryptoPriceService.swift` updated for `priceLookup(...) -> CryptoPriceLookup`; `InstrumentConversionService.swift` updated for discriminated result + `invalidateCache(for:)` | Discriminated rate result; cache invalidation hook |
| Features/Crypto | `CryptoSyncStore.swift` (new), `CryptoAccountCreationView.swift` (new), `WalletAccountHeaderView.swift` (new), `BlockExplorerLink.swift` (new) | New domain folder for wallet sync orchestration and wallet-specific views. (Existing `Features/Settings/CryptoSettingsView.swift` and `CryptoTokenStore.swift` remain in place for the preferences UI.) |
| Features/Settings | `CryptoSettingsView.swift` (existing) updated; `DiscoveredTokensInboxView.swift` (new); `SpamTokensView.swift` (new) | Preferences UI |
| Backends/CloudKit | Updates to `Account` and `TransactionLeg` record mappings for new fields; instrument-registry sync apply-batch implements the `pricingStatus` merge rule | CloudKit sync of new fields + conflict resolution |
| Backends/GRDB | New `wallet_sync_state` table (excluded from CKSyncEngine); GRDB migration adds `pricingStatus` column to instrument-registry rows; `GRDBWalletSyncStateRepository.swift` (new) | Local-only sync state; instrument-registry schema update |
| CloudKit | `CloudKit/schema.ckdb` updates + regen via `cktool` (per `modifying-cloudkit-schema` skill) | Schema source of truth |

`Domain/Models` stays clean (no SwiftUI / SwiftData / GRDB / CloudKit / URLSession imports). `Shared/CryptoImport` imports `Foundation` (which transitively provides `URLSession` on Apple platforms — explicitly noted because the strict reading is "no third-party imports", and `URLSession` is part of Foundation here). `Features/*` imports SwiftUI and talks to repositories via `BackendProvider`.

## Implementation order

1. Domain model: `AccountType.crypto` + `isInvestmentLike` (with audit of every `.investment` use site); defensive `AccountType` decode fallback; `Account` `walletAddress` / `chainId`; `TransactionLeg.externalId` (placed with `let` identity fields); `CryptoRegistration.pricingStatus`; `WalletSyncState` + `WalletSyncError`. CloudKit schema regen via `cktool`. GRDB migration. Audit of every existing leg-aggregation site for multi-instrument safety (see §[Instrument conversion semantics]).
2. `CryptoPriceService.priceLookup(...)` + `InstrumentConversionService.convert(...) -> ConversionResult` discriminated returns. Tests verify `.unpriced` / `.spam` produce `.knownZero` distinct from rate-unavailable.
3. `WalletSyncStateRepository` (GRDB-local implementation + in-memory test impl); `BackendProvider` extension.
4. `ChainConfig` + `AlchemyClient` (request/response, fixtures; same shape as `CoinGeckoClient`).
5. `CryptoTokenDiscoveryService` (actor coalescer + resolution + isSpam classification).
6. `pricingStatus` cross-device merge rule in the GRDB instrument-registry sync apply-batch handler. Tests for all four merge cases.
7. `TransferEventBuilder` (raw transfers → multi-leg events).
8. `WalletSyncEngine` (single-account build phase: fetch + group + build, no writes).
9. Transfer-detection extension: eligibility predicate + same-`externalId` auto-merge channel. Update `plans/2026-04-18-transfer-detection-design.md` with the agreed extension before implementing.
10. `CrossAccountTransferMerger` (sequential `@MainActor` apply pass).
11. `CrossDeviceLegDeduper` (post-CKSyncEngine reconciliation).
12. `CryptoSyncStore` (foreground triggers + hourly timer + scenePhase + clock injection + cancellation discipline).
13. `CryptoAccountCreationView`.
14. `CryptoSettingsView` updates (API key, accounts list, Discovered Tokens inbox, Spam tokens view; cache invalidation on status change).
15. Wallet account view enhancements (last-synced, refresh, explorer link).
16. Transaction-detail crypto fields (explorer link per leg).
17. Benchmarks.

Steps 1–11 require no UI work and are independently testable. Each open question below must have a corresponding GitHub issue created before any `// TODO` comment is added in code (per CLAUDE.md and CODE_GUIDE §20: bare `TODO:` is disallowed; `TODO(#N): reason — link` is the only allowed form).

## Open questions

1. **Periodic re-resolution cadence.** "At most once per day per `.unpriced` token" is the strawman. Defer tuning until we see how often new tokens get listed in practice. (To be tracked as a GitHub issue if it survives implementation.)
2. **Counterparty address structured storage.** v1 stores in `notes`. A future structured `counterpartyAddress` field on `TransactionLeg` would enable address-book features and "filter by counterparty"; gated on UX demand.
3. **Internal-transaction reconciliation hint on OP/Base.** v1 silently undercounts native-token contract-driven flows on these chains. A one-time dismissable note ("internal contract transfers aren't tracked on this chain — your balance may diverge from on-chain") on first wallet creation per chain might be friendlier; decide once we have feedback.
4. **Multi-recipient airdrop edge case.** A contract sending the same token to multiple of the user's tracked wallets in one tx: each wallet sees `+X` of the token. Two same-`externalId` legs with same-sign quantities — explicitly *not* a transfer. The auto-merge predicate (opposite-sign required) handles this correctly; the open question is whether we should annotate the two transactions as "linked" for UX. Defer.
5. **Optimistic deduper run before persistence.** v1 runs `CrossDeviceLegDeduper` after CKSyncEngine fetch. A more aggressive variant could run a deduper pass *before* persisting the import results, comparing against incoming CKSyncEngine fetches in flight. v1 is simpler; revisit if cross-device duplicates turn out to be common in practice.
