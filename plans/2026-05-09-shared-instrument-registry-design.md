# Shared Instrument Registry on the Profile-Index Zone

**Status:** Design — pending implementation plan.
**Scope:** Move the instrument registry, the discovered-tokens inbox, and the price-cache tables out of per-profile storage and onto the existing iCloud-account-scoped `profile-index` CloudKit zone and `profile-index.sqlite` GRDB DB. Out of scope: Settings UI relocation; CSV import preferences; import rules; the follow-up release that drops the legacy per-profile rows (its `ProfileSchema` migration ID `"v10_drop_shared_instrument_legacy"` is reserved here so the number cannot drift).

## Motivation

Today the instrument registry is per-profile. `InstrumentRecord` lives in the `profile-<UUID>` CloudKit zone (`SyncCoordinator+Zones.swift:139`); the local `instrument` table lives in the per-profile `data.sqlite` (`ProfileSchema.swift`); the rate-cache tables (`crypto_price`, `stock_price`, `exchange_rate` and their `*_meta` peers) live alongside it. CloudKit record IDs are zone-scoped, so two profiles holding the same instrument id (e.g. `bitcoin`) are stored as two independent records and two independent rows.

Three concrete consequences:

1. **Spam decisions don't propagate across profiles.** Marking a token spam in profile A flips a field on A's `InstrumentRecord(id: "bitcoin")`; profile B's separate record is untouched.
2. **Discovered-token resolutions don't propagate.** Resolving `0xabc…` to "USDC" in profile A leaves profile B's wallet sync re-asking the same question.
3. **Price API calls duplicate.** Two profiles holding bitcoin both fetch and cache the price independently. The Alchemy/CoinGecko keys are already shared (synced keychain), so the duplication is purely wasted work.

These are all variants of the same architectural mistake: data that conceptually belongs to the iCloud user is stored at the profile level. Moving it up one level fixes all three at once.

## Why the profile-index zone

The `profile-index` zone already exists, already has the right scope, and already runs the infrastructure we'd otherwise duplicate:

- Owner is `CKCurrentUserDefaultName` — one zone per iCloud account, not per profile (`ProfileIndexSyncHandler.swift:35-38`).
- Already runs its own `CKSyncEngine` instance via `SyncCoordinator`.
- Already has lifecycle coverage in the coordinator: zone deletion, account switch, encrypted-data reset, system-fields management.
- Backed by its own GRDB DB at `profile-index.sqlite` via `GRDBProfileIndexRepository`.
- `InstrumentRecord` is already declared in `schema.ckdb:113`. CloudKit record types are not zone-scoped — the same type can be written into any zone with no schema change.

Reusing this zone avoids inventing a new `user-shared` zone, a new `CKSyncEngine` instance, and new lifecycle plumbing.

The name `profile-index` becomes a slight misnomer once it carries instruments and prices. It's an internal identifier (never user-visible) and renaming a CloudKit zone requires a data migration. We leave the zone name as-is and update comments only.

## What moves and what stays

**Move to the profile-index zone (CloudKit) and `profile-index.sqlite` (local):**

- `InstrumentRecord` — the canonical registry rows (stock + crypto). Carries pricing status (`priced` / `unpriced` / `spam`) and provider mappings.
- Local-only price-cache tables: `crypto_price`, `crypto_token_meta`, `stock_price`, `stock_ticker_meta`, `exchange_rate`, `exchange_rate_meta`. These are not synced to CloudKit at all; they're pure local caches with cap-at-yesterday retention (`Shared/PriceCacheCap.swift`).
- The discovered-tokens inbox. **No new record type required** — the inbox is a derived view over `InstrumentRecord` rows where `pricingStatus == .unpriced` (see `InstrumentRegistryRepository.swift:53-72`).

**Stays per-profile (`profile-<UUID>` zone and per-profile `data.sqlite`):**

- `account`, `transaction`, `transaction_leg`, `investment_value`, `earmark`, `earmark_budget_item`, `category`.
- `csv_import_profile`, `import_rule`.
- `wallet_sync_state` — per-account last-sync timestamps, Alchemy invocation history.
- The Crypto settings tab's "Accounts" subsection remains a per-profile view (it's the profile's wallet accounts, not the registry).

## Cross-zone reference safety

Per-profile rows continue to reference instruments by id string only (`AccountRow.swift:9-13`, `instrumentId: String`). The lookup path already tolerates a registry miss: `instruments[instrumentId] ?? Instrument.fiat(code: instrumentId)` (`AccountRow+Mapping.swift:44`, `GRDBAccountRepository+Positions.swift:47,81`). This fallback was already required because CloudKit gives no ordering guarantee within a zone — a transaction record and its instrument record can arrive in either order from the same fetch batch. The cross-zone case isn't materially different from today's intra-zone case.

If anything, the cross-zone version is slightly more stable: the profile-index zone has to come up before any per-profile session can open (the profile list is a prerequisite for opening any session), so by the time per-profile `toDomain` paths run, the registry is more likely to be populated than today's intra-zone arrival-order race.

No change to the fallback policy is required.

## Sync handler extensions

This section enumerates every code path that today is `ProfileRow`-specific and must be extended to dispatch by `recordType` for `InstrumentRecord`. Without these, the relocated data has no functioning downlink, uplink, conflict-resolution, lifecycle, or self-heal path.

### Downlink: `applyRemoteChanges`

Today `ProfileIndexSyncHandler.applyRemoteChanges` (`ProfileIndexSyncHandler.swift:47`) hard-rejects any record whose type is not `ProfileRow.recordType`. Extend to dispatch:

- `ProfileRow.recordType` → existing `ProfileRow.fieldValues(from:)` + `applyRemoteChangesSync(saved:deleted:)`.
- `InstrumentRow.recordType` → `InstrumentRow.fieldValues(from:)` + a new `applyInstrumentRemoteChangesSync(saved:deleted:)` on the shared instrument repository.

Both branches must run in the same `db.write { ... }` transaction so a mid-batch failure rolls back cleanly per `guides/DATABASE_CODE_GUIDE.md`.

After applying, the handler invokes a `@Sendable () -> Void` "remote-instrument-changed" closure (see §Cross-zone observer signal below) that hops to `@MainActor` and fans out to subscribers.

### Uplink: `recordToSave`

Today's `recordToSave(for: CKRecord.ID)` (`ProfileIndexSyncHandler.swift:112-121`) decodes the recordName as a UUID for `ProfileRow` lookup. Instrument records use string-keyed recordNames (`"bitcoin"`, `"AUD"`, contract addresses). Extend the lookup to dispatch:

- If the record name parses as a UUID → `ProfileRow` path (existing).
- Otherwise → string-keyed instrument repository lookup. Build the CKRecord using `CKRecord.ID(recordName: instrumentId, zoneID: zoneID)` (string-keyed), not the UUID-keyed `CKRecord.ID(recordType:uuid:zoneID:)` form.

The two-path shape mirrors the existing `ProfileDataSyncHandler+RecordLookup.swift:28-35` precedent.

### `queueAllExistingRecords`

Extend to enumerate both tables and return the combined list. Use the UUID-keyed CKRecord.ID form for profiles and the string-keyed form for instruments. Document inline that the two record types have no inter-record dependencies in this zone (per `SYNC_GUIDE.md` Rule 14, ordering is immaterial; the comment must say so explicitly so a later reviewer knows the order is not load-bearing).

### Startup self-heal: `queueUnsyncedRecordsForAllProfiles`

Extend the existing startup scan (`SyncCoordinator+Backfill.swift:107`) to include the shared `instrument` table — rows whose `encoded_system_fields IS NULL` are queued for upload to the profile-index zone. This provides idempotency for the data-union upload step: if the app crashes between the GRDB write commit and `CKSyncEngine`'s state-file persist, the next launch's startup scan re-queues any instrument row that didn't make it.

### Conflict dispatch: `handleSentRecordZoneChanges`

Today the method calls `applyServerRecordChangedMerge(serverRecord:)` unconditionally for every `.serverRecordChanged` failure (`ProfileIndexSyncHandler.swift:200-215`); that helper only knows about `ProfileRow.dataFormatVersion`. Extend the call site to dispatch by `serverRecord.recordType`:

- `ProfileRow` → existing `applyServerRecordChangedMerge(serverRecord:)` (`dataFormatVersion` merge — keep unchanged).
- `InstrumentRecord` → new `applyInstrumentServerRecordChangedMerge(serverRecord:)` implementing the rule defined in §Conflict resolution.

### System-fields write path: UUID-vs-string dispatch

`ProfileIndexSyncHandler`'s system-fields helpers — `updateEncodedSystemFields` (`ProfileIndexSyncHandler.swift:172-179`), `clearEncodedSystemFields` (`ProfileIndexSyncHandler.swift:184-192`), `writeSystemFields` (`ProfileIndexSyncHandler.swift:239-248`), and `resolveSystemFields` (`ProfileIndexSyncHandler.swift:228-236`) — all begin with `guard let profileId = recordID.uuid else { return }`. After this work they must dispatch by record-name shape:

- `recordID.uuid != nil` → existing `GRDBProfileIndexRepository.setEncodedSystemFieldsSync(id: UUID, data:)` path.
- otherwise → new `setEncodedSystemFieldsSync(id: String, data:)` on the instrument repository.

Without this dispatch, every successful `InstrumentRecord` save to the profile-index zone fails to persist server-returned system fields, causing a `.serverRecordChanged` on every subsequent upload of the same instrument. `ProfileIndexInstrumentUploadTests` (§Testing) covers a full roundtrip through `handleSentRecordZoneChanges` asserting that `encoded_system_fields` is persisted.

### `deleteLocalData` and `clearAllSystemFields`

Today's `deleteLocalData` (`ProfileIndexSyncHandler.swift:150-157`) wipes the `profile` table only; `clearAllSystemFields` (`ProfileIndexSyncHandler.swift:163-168`) clears `profile.encoded_system_fields` only. After this work both must cover the new tables. See §Lifecycle for the full event-by-event matrix.

### Cross-zone observer signal

Today `ProfileDataSyncHandler` carries an `onInstrumentRemoteChange` closure fired from `reportSuccess` when `changedTypes` contains `InstrumentRow.recordType` (`ProfileDataSyncHandler.swift:41-46`). After the move the same closure pattern is applied at the profile-index handler.

**Mechanism — closure injection at construction:**

`ProfileIndexSyncHandler.init` gains an `onInstrumentRemoteChange: (@Sendable () -> Void)?` parameter, mirroring the existing per-profile shape. The closure is wired during `SharedInstrumentScope` construction; its body invokes the existing `GRDBInstrumentRegistryRepository.notifyExternalChange()` (`Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository.swift:231`) via a `Task { @MainActor in repository.notifyExternalChange() }` hop. **No new repository method named `notifyRemoteChange()` is introduced** — the existing `notifyExternalChange()` is the only API; it is `@MainActor`-isolated; the handler is nonisolated-`Sendable`; the `Task { @MainActor in … }` hop is the boundary crossing.

The fan-out itself happens through the already-public `InstrumentRegistryRepository.observeChanges()` `AsyncStream` (`InstrumentRegistryRepository.swift:101-103`). Subscribers across all sessions receive the signal automatically; no per-session wiring is needed.

**Protocol doc-comment update is a tracked task.** The doc-comment for `observeChanges()` (`InstrumentRegistryRepository.swift:80-100`) currently states the stream "fires only for *local* mutations" and excludes remote-change notifications. After this work the stream fires for both local mutations and remote-arriving rows on the profile-index zone. The implementation plan must include a discrete task to update the doc-comment so a future reader of the protocol is not misled. Without it, callers may continue to wire redundant per-profile remote-change subscriptions.

The `@MainActor` isolation on `observeChanges()` itself is preserved unchanged — it's already a documented carve-out (`CONCURRENCY_GUIDE.md §2`) for synchronous continuation registration.

### Sync hook installation

`wireProfileIndexHooks` today wires `onRecordChanged` / `onRecordDeleted` for the profile repository (`SyncCoordinator+ProfileIndexHooks.swift`). Extend to also wire the shared `InstrumentRegistryRepository` so every registry mutation (`registerCrypto`, `update`, `remove`) queues an upload to the profile-index zone via `queueSave(recordName:zoneID:)` (string-keyed). Hooks are installed exactly once during `SharedInstrumentScope` construction.

### `RecordTypeRegistry`

If the dispatch wiring uses `RecordTypeRegistry.allTypes` (rather than a local switch), `InstrumentRecord` must be added to it for the profile-index zone. The implementation plan is responsible for confirming whether the registry is consulted on this code path and updating it where required.

### Per-profile handler decommissioning

`ProfileDataSyncHandler` today carries an `onInstrumentRemoteChange` closure (`ProfileDataSyncHandler.swift:41-46`) fired from `reportSuccess` when the per-profile zone delivers an `InstrumentRecord`. After this work it must be retired:

- Remove the `InstrumentRow.recordType` branch from `ProfileDataSyncHandler.applyRemoteChanges`. After Step 5's server-side `queueDeletion` drains the legacy per-profile `InstrumentRecord` rows, no further deliveries are expected; until that drain completes, any straggler delivery from a not-yet-upgraded peer device is best ignored — applying it would write into a per-profile `instrument` table that's about to be dropped.
- Remove the `onInstrumentRemoteChange` parameter from `ProfileDataSyncHandler.init` and the `reportSuccess` firing condition.
- Remove the per-profile wiring sites in `ProfileSession+CloudKitBackendBuild.swift` (currently `wireInstrumentRemoteChangeFanOut`).

The above three sub-tasks land in the same binary as the rest of the work item. They become safe at the same time as Step 3's DI rewiring because no new code path writes `InstrumentRecord` to a per-profile zone after that point. Until Step 5 ships in a follow-up release, the legacy per-profile rows still exist on the server and may be delivered as remote-change batches; ignoring them in `applyRemoteChanges` is the correct response (the shared zone has the canonical copy).

## DI / ownership

A new app-level holder, `SharedInstrumentScope` (working name; implementation plan to confirm), constructed alongside `SessionManager` and `ProfileContainerManager` and reachable through `BackendProvider`. **Isolation: `@MainActor final class`.** UI consumers (Settings, sidebar widgets, sync stores) are all `@MainActor`-isolated; the actor types it owns are accessed via `await` and are themselves `Sendable`. `@MainActor` confinement avoids the `@unchecked Sendable` carve-out that would otherwise be required, and matches the existing `SessionManager` ownership pattern.

### Ownership matrix

| Component | Type today | Lifetime after | Notes |
|---|---|---|---|
| `InstrumentRegistryRepository` (protocol) | `Sendable` protocol | App-wide singleton | Implementations are concrete classes that conform to `Sendable`. The `subscribers` dictionary in `GRDBInstrumentRegistryRepository` is `@MainActor`-confined per its existing carve-out; that pattern is preserved. |
| `CryptoPriceService` | `actor` | App-wide singleton | `DatabaseWriter` wired explicitly to the **profile-index DB**, not any per-profile DB. |
| `StockPriceService` | `actor` | App-wide singleton | `DatabaseWriter` wired to the **profile-index DB**. |
| `ExchangeRateService` | `actor` | App-wide singleton | `DatabaseWriter` wired to the **profile-index DB**. |
| `InstrumentSearchService` | `struct Sendable` | App-wide singleton | Stateless. |
| `CryptoTokenDiscoveryService` | `actor` | App-wide singleton | `inFlight` task map lives on the actor (see §Discovery cancellation). |
| `SharedRegistryStore` (working name) | `@MainActor @Observable` | App-wide singleton | Owns shared registry-data fields. Replaces `CryptoTokenStore`'s data-side. Holds a `Task<Void, Never>` for its lifetime that consumes the registry's `observeChanges()` stream; the task is started in `init` and cancelled in `deinit`. |
| `SettingsCryptoStore` (working name) | `@MainActor @Observable` | Per-session | Owns only `isLoading` / `error` for the current Settings screen. Replaces `CryptoTokenStore`'s UI-state side. Calls into `SharedRegistryStore` for data; catches errors locally. |

`SharedInstrumentScope` holds **no** strong references to any `ProfileSession`. Cross-session change notifications go via the registry's `observeChanges()` `AsyncStream` (one continuation per subscriber, automatically removed on cancellation); session teardown therefore can't leak the scope.

### Concurrent mutations on the shared registry

`SharedRegistryStore`'s mutating methods (`registerCrypto`, `setStatus`, `removeRegistration`, `loadRegistrations`) delegate to `InstrumentRegistryRepository`, which serialises writes through GRDB's serial dispatch queue. No additional `isLoading` guard at the store level — the GRDB queue is the one source of order. If two sessions submit conflicting mutations concurrently, GRDB serialises them and both complete; the registry observers fire after each.

### `CryptoTokenStore` split

Today's `CryptoTokenStore` mixes registry data (`registrations`, `instruments`, `providerMappings`, `registrationsVersion`) with per-action UI state (`isLoading`, `error`) and a single-slot `onRegistrationsChanged` callback. Lifting the whole thing app-level would leak one session's transient errors onto every Settings screen, and the single-slot callback can't be shared across sessions without losing all but the most recent assignment.

The split:

- **`SharedRegistryStore`** — app-level. Owns `registrations`, `instruments`, `providerMappings`, `registrationsVersion`, plus the methods that mutate the shared registry (`registerCrypto`, `setStatus`, `removeRegistration`, `loadRegistrations`). Mutating methods throw to the caller; this store does **not** carry an `error` field.
- **`SettingsCryptoStore`** — per-session. Owns `isLoading` and `error`. Calls into `SharedRegistryStore` for data; catches errors locally and surfaces them in its own UI state. Lives inside `ProfileSession` like other per-session stores.

### Discovery cancellation

`CryptoTokenDiscoveryService.inFlight` is held on the actor itself, not on any per-session task array. When a profile session is torn down, `cleanupSync` does **not** cancel discovery tasks — those tasks are deduplicated across sessions, so cancelling them from session A would also cancel session B's await on the same in-flight task. A new `DiscoveryCancellationIsolationTests` (see §Testing) confirms this invariant.

Errors from `resolveOrLoad` propagate through the service's API to the per-profile `CryptoSyncStore` that initiated the call; that store catches them and surfaces them in its own per-session UI state. The shared registry never carries error state.

### Migration concurrency

The data-union runner is structured as a small helper type with `nonisolated async` methods, called from a `@MainActor` boot path that `await`s its completion before any session opens. Per-profile DB I/O is performed via `await database.write { ... }` on each per-profile `DatabaseQueue`, which dispatches the work onto GRDB's serial executor (off the main thread) and resumes the awaiter on the calling actor. The runner's own coroutine state may be on the main actor under Swift 6.2 default isolation; that is acceptable because the runner spends almost all of its time suspended on `await` and the main thread is free during those waits.

Per-profile DBs are opened **sequentially**, not in a `TaskGroup`, to bound memory and disk-WAL pressure. No `Task.detached`. No `Task.sleep` — the runner returns when the union commits.

## Conflict resolution

Standard CKSyncEngine flow: `.serverRecordChanged` is reported on save; the local row is merged with the server record. The default is field-level last-write-wins by `___modTime`. We layer one custom rule:

**`pricingStatus` is spam-sticky.** If either the local or the server record has `pricingStatus == .spam`, the merged record has `pricingStatus = .spam` regardless of `___modTime`. For `.priced` vs `.unpriced`, take the newer by `___modTime`.

**Other fields (`name`, provider mappings, `decimals`, `kind`, `contract_address`, etc.) follow plain newest-wins.** A spam-wins merge does **not** force the local record's other fields to win — only `pricingStatus`. Edge case: device A flags spam at t=1, device B updates the provider mapping at t=2 → merged record carries device B's mapping but `pricingStatus = .spam`. Acceptable: provider mappings on spam rows are unused (the wallet sync ignores spam rows, and the price service doesn't query them). Documented as a known characteristic, not a bug.

Implemented as `applyInstrumentServerRecordChangedMerge(serverRecord:)` on `ProfileIndexSyncHandler`, parallel to the existing `applyServerRecordChangedMerge(serverRecord:)` for `dataFormatVersion`. Dispatched per §Sync handler extensions → Conflict dispatch.

## Discovered-tokens inbox semantics

A discovered token surfaces in *every* profile's inbox once any profile's wallet sync turns it up, because the inbox is a derived query over the global registry. Resolving it in any profile clears it from all of them.

Edge case acknowledged but not solved: profile B sees token X in its inbox even if B never held X. Resolving once benefits everyone (B gets a clean inbox; A gets the resolution). The cardinality is small (the per-iCloud-account universe of unresolved tokens), so this is fine in practice.

## Local schema

A single new `ProfileIndexSchema` migration `"v3_shared_instrument_registry"` (next ID after `v2_data_format_version` per `ProfileIndexSchema.swift:46-48`) adds the new tables to `profile-index.sqlite`.

**Verbatim semantics.** "Schemas are copied from the per-profile DDL" means: copy the *current* (post-v8) shape of each table in a single `CREATE TABLE` statement. The implementation does **not** replay the historical per-profile evolution. The new migration body is one `CREATE TABLE` per table, in the final post-v8 form, plus the indexes listed below.

### `instrument`

Mirrors the post-v8 per-profile shape from `ProfileSchema+CoreFinancialGraph.swift` + `ProfileSchema+CryptoWalletFields.swift`. Required constraints (non-negotiable per `DATABASE_SCHEMA_GUIDE.md` §4 / §8 and `SYNC_GUIDE.md` §8):

- `id TEXT NOT NULL PRIMARY KEY`.
- `record_name TEXT NOT NULL UNIQUE` — used as `CKRecord.ID.recordName` for the upload path.
- For `InstrumentRecord` the invariant `id == record_name` always holds (both are the instrument's id string, e.g. `"bitcoin"`, `"AUD"`, `"1:0xa0b8…"`). This is asserted in the union pass and in a CI-time `RegistryInvariantTests` check; it lets the upsert in §Migration step 2 use `ON CONFLICT(id)` unambiguously.
- `kind TEXT NOT NULL CHECK (kind IN ('fiatCurrency', 'stock', 'cryptoToken'))` — values are the `Instrument.Kind` raw values (`fiatCurrency`, `stock`, `cryptoToken`); copied verbatim from `ProfileSchema+CoreFinancialGraph.swift:68`.
- `pricing_status TEXT NOT NULL DEFAULT 'priced' CHECK (pricing_status IN ('priced', 'unpriced', 'spam'))`.
- `encoded_system_fields BLOB` (nullable; CKSyncEngine system-fields blob).
- `STRICT`.

The exact column list and default values are taken verbatim from the per-profile DDL — the implementation plan transcribes them.

### Price-cache tables

All three `*_meta` tables — `crypto_token_meta`, `stock_ticker_meta`, **and `exchange_rate_meta`** — are `WITHOUT ROWID` (post-v4 shape per `ProfileSchema+RateCacheWithoutRowid.swift`). The body tables `crypto_price`, `stock_price`, and `exchange_rate` are ROWID (post-v1 shape).

**No secondary indexes** are added in this work item. The per-profile `exchange_rate_lookup ON exchange_rate (base, quote, date)` index is **not** carried into the shared DB: no production query uses `(base, quote, date)` as SQL predicates — `loadCache` fetches `WHERE base = ?` (which scans the PK's leading column) and the service resolves quote/date lookups in-memory from the loaded `caches[base]` dictionary. Carrying the index forward into the fresh shared DB would add write amplification on a write-heavy table for zero read benefit. Existing per-profile data keeps the index until the follow-up `v10_drop_shared_instrument_legacy` migration drops the table outright; no re-creation needed in the shared DB.

The previously-proposed `stock_ticker_meta_by_instrument_id` is also dropped for the same reason — `instrument_id` is a stored attribute, never a lookup column (see `Shared/StockPriceService.swift` for the ticker-keyed access pattern).

The `INSERT … ON CONFLICT(id) DO UPDATE` strategy used by the data-union pass must be deliberate — see §Migration step 2.

### Doc-comment retention rationale

The new migration's doc-comment in `ProfileIndexSchema.swift` reproduces the "kept forever" justification for the price-cache tables verbatim from `ProfileSchema.swift:48-55` (`DATABASE_SCHEMA_GUIDE.md` §9 requirement).

### `notifyRateCacheChange` rewiring

`db.notifyRateCacheChange(...)` is a per-`Database`-handle helper (`Backends/GRDB/Observation/RateCacheTable.swift`). After the price tables move, every writer must call it on the **profile-index `DatabaseQueue`'s** handle. Existing `InstrumentConversionService.observeRates()` subscriptions must be re-attached to the profile-index queue.

**Teardown ordering is part of the rewiring task.** The implementation plan must cancel the old per-profile `ValueObservation` tasks **before** starting the new shared-DB ones. Otherwise both fire for a window after launch, producing duplicate rate-cache change notifications. Cancellation goes via the existing `Task` handles stored in whichever owner held the per-profile observation; the new task is started by `SharedInstrumentScope.init` only after the old ones are confirmed cancelled.

### PRAGMA discipline

Per-profile DBs opened during the union pass go through `ProfileDatabase.open(at:)` (or its read-only sibling), which already applies `GRDBPragmas.applyDefaults`. The migration code does not touch raw `sqlite3_open`, does not use `FileManager.copyItem`, and does not bypass GRDB's WAL handling. `FileManager.removeItem` is not invoked at all in this work item — sidecar cleanup is not part of this migration.

## Migration

Two distinct operations with two distinct gating mechanisms.

### Step 1 — Schema migration (GRDB-managed)

Register `"v3_shared_instrument_registry"` in `ProfileIndexSchema.migrator`. The body creates every new table in its final post-v8 shape via one `CREATE TABLE` per table, plus the indexes listed in §Local schema. Idempotent and rerun-safe via GRDB's `grdb_migrations` table — no separate gate needed.

### Step 2 — Data union (UserDefaults-flag-gated, one-shot)

Pattern modelled on `SwiftDataToGRDBMigrator+ProfileIndex.swift:22-49`. UserDefaults key: `com.moolah.migration.shared-registry-union.v1.completed`. Once true, the runner is a no-op forever.

When the flag is unset, the runner:

1. Enumerates per-profile DBs by reading the profile-index `profile` table, **sorted ascending by `profile.id`** (BLOB UUID; `ORDER BY id`). The sort order is the migration's tie-breaker key and is stable across re-runs.
2. For each profile in that order, opens its `data.sqlite` via `ProfileDatabase.open(at:)` (a fresh `DatabaseQueue` with `GRDBPragmas.applyDefaults`). No `FileManager.copyItem`, no raw `sqlite3_open`.
3. Reads `instrument`, `crypto_token_meta`, `stock_ticker_meta`, `crypto_price`, `stock_price`, `exchange_rate`, `exchange_rate_meta`.
4. Merges into the shared tables under one `db.write { ... }` on the profile-index queue. **The merge does not decode `encoded_system_fields`** (`DATABASE_SCHEMA_GUIDE.md` §8 / `SYNC_GUIDE.md`: opaque-bytes contract). Per-id rules:
   - `pricing_status`: `.spam` if any participating row is `.spam`; else `.priced` if any is `.priced`; else `.unpriced`. (Matches the runtime spam-wins rule.)
   - Provider-mapping fields (`coingecko_id`, `binance_symbol`, `contract_address`, etc.): any non-null wins over null. On conflict between two non-null values, the row from the **later-iterated profile** (higher `profile.id` in the ascending sort) wins. Deterministic and stable across re-runs.
   - `encoded_system_fields`: copied verbatim (byte-for-byte) from whichever row "wins" the deterministic ordering. Never decoded. **NULL is acceptable** — if the winning row's blob is NULL (the row was never sync-roundtripped on this device), the merged row starts with NULL system fields and the next upload to the profile-index zone produces a fresh CKRecord create. This is the correct first-write behaviour; do not "prefer non-null" in the merge.
   - The shared-table INSERT uses `ON CONFLICT(id) DO UPDATE` — `id` is the table's primary key. Because `id == record_name` is enforced (see §Local schema → `instrument`), there is no ambiguity between the PK and the `record_name` UNIQUE constraint.
   - For price-cache tables, on `(id, date)` collision keep the row whose `*_meta` row's `latest_date` is more recent. (Column name from `ProfileSchema+RateCacheWithoutRowid.swift`; the meta tables carry `(earliest_date, latest_date)`, no `last_fetched_at`.)
5. Closes each per-profile `DatabaseQueue` after reading.
6. After all profiles are processed and the GRDB write commits, sets the UserDefaults flag.

Per-profile DB open failure (corrupt file, locked) logs and skips that profile. **Known limitation:** skipped profiles' instrument rows are absent from the shared registry until manually re-added. A per-profile retry flag is a follow-up if real-world reports surface; not in scope here. The limitation is documented for users in the release notes.

### Step 3 — Single-binary atomicity (DI rewiring)

Steps 1 and 2 ship in **the same binary** as the DI rewiring that reroutes every `registerCrypto` / `update` / `remove` / `ensureInstrument` callsite from `ProfileSession.instrumentRegistry` to `SharedInstrumentScope.instrumentRegistry`. There is **no** intermediate released build where the migration has run but old per-profile-zone writes are still live.

**Audit-before-merge — primary mechanism is code search, not the runtime trap.** A pre-merge audit enumerates every callsite that directly or indirectly calls `onRecordChanged` / `onRecordDeleted` for an instrument repository, and verifies each is wired to the profile-index zone. The audit task lives in the implementation plan; pass criterion is zero `InstrumentRecord` write callsites that resolve to a `profile-<UUID>` zone.

**`DEBUG`-build runtime trap is a secondary CI signal.** Placement: inside `ProfileDataSyncHandler.recordToSave(for:)` (and equivalent `nextRecordZoneChangeBatch` / queueing paths in the per-profile data handler). The trap fires synchronously on the engine executor whenever `recordToSave` would build an `InstrumentRecord` for a `profile-<UUID>` zone, regardless of which `Task` initiated the upload. Because the trap is a `precondition`, it is process-level and does not depend on actor context. The trap is a backstop only — if a callsite is missed but never exercised in CI, the trap never fires; the code-search audit must be exhaustive on its own.

### Step 4 — Self-heal startup scan

§Sync handler extensions → Startup self-heal: extending `queueUnsyncedRecordsForAllProfiles` to enumerate the shared `instrument` table closes the residual idempotency gap between "GRDB write committed" and "CKSyncEngine state persisted".

### Step 5 — Follow-up cleanup (separate spec, ID committed)

A subsequent release ships `ProfileSchema` migration `"v10_drop_shared_instrument_legacy"` that drops the per-profile `instrument`, `crypto_token_meta`, `stock_ticker_meta`, `crypto_price`, `stock_price`, `exchange_rate`, `exchange_rate_meta` tables on every per-profile DB (small body; just `DROP TABLE` calls — these tables have no FK dependencies post-v5). Server-side, `InstrumentRecord` rows in `profile-<UUID>` zones are deleted via `queueDeletion(recordName:zoneID:)` (string-keyed) routed through the existing `ProfileDataSyncHandler` deletion path. The migration ID is reserved here so it cannot drift into a different number; the body and the deletion-queueing details are deferred to that spec.

## Lifecycle

| Event | Action on `profile-index.sqlite` |
|---|---|
| Account sign-out | Wipe `profile`, `instrument`, all six price-cache tables. (Price caches are wiped because they're keyed against the registry; keeping them after sign-out would leak data across iCloud accounts.) |
| Account switch | Same as sign-out. |
| Zone `.deleted` for `profile-index` | Same as sign-out. |
| Zone `.purged` for `profile-index` | Same as sign-out. (Symmetric with `.deleted`; user invoked destructive intent.) |
| Encrypted-data reset | Clear `encoded_system_fields` on `profile` and `instrument`. Re-queue both via the extended `queueAllExistingRecords`. Price-cache rows untouched. |
| Profile delete (single profile) | No change to shared tables — they belong to the iCloud account, not the profile. Per-profile `data.sqlite` deletion proceeds as today. |

Implementation: extend `ProfileIndexSyncHandler.deleteLocalData` and `clearAllSystemFields` to cover the new tables. The `GRDBProfileIndexRepository` (or a peer instrument-repo) gains the new `deleteAllSync()` / `clearAllSystemFieldsSync()` overloads invoked from the handler.

## Testing

- **`SharedRegistryMigrationTests`** — given two pre-populated per-profile DBs with overlapping instruments and conflicting `pricing_status`, run the union runner once and assert the deterministic merge. Re-run with the flag unset must produce the same state (idempotency). Cover the NULL `encoded_system_fields` path (winning row had no sync roundtrip yet → merged row has NULL → next upload is a fresh create).
- **`ProfileIndexInstrumentApplyTests`** — feed a synthetic `InstrumentRecord` `CKRecord` through `ProfileIndexSyncHandler.applyRemoteChanges`. Assertions:
  - The row is upserted with the right fields and `encoded_system_fields` is preserved byte-for-byte (synchronous).
  - The injected `onInstrumentRemoteChange` closure fires exactly once (synchronous count, mirrors the existing `InstrumentRemoteChangeFanOutTests` pattern). **Do not** assert that the `Task { @MainActor in repository.notifyExternalChange() }` hop reaches the registry from this test — that's an unstructured task and would require a forbidden `Task.sleep` race. The hop's downstream effect is already covered by `MoolahTests/Backends/CloudKitInstrumentRegistryNotifyTests`; composing those two contracts is sufficient.
  - With the closure parameter set to `nil`, `applyRemoteChanges` must not crash. Guards against a future refactor introducing a force-unwrap on the optional closure.
- **`ProfileIndexInstrumentUploadTests`** — register a crypto instrument via the shared registry. Assert `recordToSave` returns a CKRecord with the expected string-keyed recordName; `queueAllExistingRecords` includes both `ProfileRow` and `InstrumentRow` IDs; a successful upload through `handleSentRecordZoneChanges` persists the server-returned system fields onto the `instrument` row (covers the UUID-vs-string dispatch in §System-fields write path).
- **`SpamWinsConflictTests`** — drive `.serverRecordChanged` failures where local has `.priced` and server has `.spam` (and the inverse); assert the merged local row is `.spam` regardless of timestamp ordering. Cover the non-`pricingStatus` field invariant: a newer-timestamped server record with `.priced` and a fresher `coingecko_id` produces a merged row with the new `coingecko_id` but `pricing_status = .spam`.
- **`CrossProfileSpamPropagationTests`** — in one `@MainActor` test, two `ProfileSession`s share a `SharedInstrumentScope` and a backing `BackendProvider`. **Setup-order is load-bearing:** call `registry.observeChanges()` on profile B's view of the registry **before** calling `setStatus(.spam)` on profile A. The continuation must be registered in `subscribers` *prior* to the mutation so the signal is not missed. Then start a child `Task` that runs `for await _ in stream { … break }`, holding the task handle. After the mutation, await the child task with a bounded backstop: if the propagation breaks, cancel the child and assert it produced a non-`nil` element before cancellation. Never `Task.sleep`.
- **`ProfileIndexLifecycleTests`** — invoke `deleteLocalData` on the handler; assert all six listed tables are wiped. Invoke `clearAllSystemFields`; assert `encoded_system_fields` is `NULL` on both `profile` and `instrument`.
- **`DiscoveryCancellationIsolationTests`** — profile A and B both await `resolveOrLoad("0xabc...")` within the same actor cycle; tearing down session A does not cancel session B's await on the same in-flight task. Confirms the discovery actor's `inFlight` map is not coupled to per-session task arrays.
- **`RegistryInvariantTests`** — asserts the `id == record_name` invariant on every InstrumentRecord round-trip (`fieldValues(from:)` reading, `toCKRecord(in:)` writing, and post-merge rows in the shared `instrument` table).
- **`RateQueryPlanTests` extension** — pin against `profile-index.sqlite` the same query shapes that the per-profile suite already pins. Concretely: `WHERE base = ?` against `exchange_rate` uses the PK's leading-column scan (mirrors the existing `exchangeRateLoadCacheUsesPrimaryKey` test); PK lookups against `crypto_price`, `stock_price`, `exchange_rate_meta`, `stock_ticker_meta`, `crypto_token_meta` use their respective primary keys. **No** test for `exchange_rate_lookup` — that index is intentionally not carried into the shared DB (see §Local schema → Price-cache tables).

`TestBackend.create()` gains an optional `sharedScope: SharedInstrumentScope?` parameter; when omitted it constructs a fresh in-memory shared scope. Tests that need cross-profile interaction pass the same scope to multiple `TestBackend.create` calls.

**Task-sleep policy.** All new tests above use bounded `for await … { break }` consumption against the registry's `observeChanges()` stream — never `Task.sleep`. The pre-existing `MoolahTests/Backends/CloudKitInstrumentRegistryNotifyTests.swift:23,40` uses `Task.sleep` to race notifications; modernising those tests is out of scope for this work item but tracked as a follow-up — the design does not adopt their pattern for any new test.

## Risks & open questions

- **Stale provider mapping after spam-wins merge.** Documented as accepted; mappings on spam rows are unused by the wallet sync and the price service.
- **Skipped profile during union pass.** Known limitation; manual re-add is the recovery. A per-profile retry flag is a follow-up if real-world reports surface.
- **`encoded_system_fields` byte-for-byte copy.** Never decoded in the migration; the merge tie-breaker uses content fields and deterministic profile-id ordering. NULL is acceptable in the merged row.
- **Discovery error propagation.** Errors return through `CryptoTokenDiscoveryService.resolveOrLoad` to per-session callers; the shared registry never carries error state.
- **Audit-before-DI ordering.** Implementation plan enforces that the codepath audit completes before the migration binary can ship. `DEBUG`-build runtime trap is a backstop; the audit is the primary mechanism.
- **`RecordTypeRegistry` coverage.** Implementation plan confirms whether the registry is consulted on the profile-index dispatch path and updates it where needed.
- **`observeChanges()` doc-comment update.** Tracked task in the implementation plan; the protocol-level comment must be updated to reflect that the stream now fires for both local and remote-arriving changes.
- **`notifyRateCacheChange` observer teardown.** Tracked task; old per-profile `ValueObservation` tasks are cancelled before new shared-DB ones start.
- **Schema baseline file (`schema-prod-baseline.ckdb`).** Unchanged. We're not adding or modifying CloudKit record types; only the runtime zone placement of an existing type changes.
- **First-run cost.** The migration walks every profile DB once. Realistic counts (≤ 10 profiles per user, ~hundreds of instruments per profile) bound the cost; not user-visible.

## Out of scope (explicit)

- **Settings UI relocation** — option A from the brainstorming session. Once the registry is global, the macOS Settings → Crypto tab shrinks to a global view (registered tokens, spam, discovered tokens, API keys) plus a per-profile "Accounts" subsection. Separate spec.
- **CSV import preferences and import rules** — genuinely per-profile (rules reference categories and accounts that are per-profile). Separate spec.
- **`v10_drop_shared_instrument_legacy` follow-up migration** — separate spec; ID reserved here.

## Acceptance criteria

- Two profiles on the same iCloud account see the same registered tokens, the same spam list, the same discovered-tokens inbox, and (transparently) share price-cache rows.
- Marking a token spam in one profile's settings is reflected in the other profile's settings within one CKSyncEngine cycle (verified via `for await` on the registry's `observeChanges()` stream).
- Resolving a discovered token in one profile clears it from every profile's inbox.
- A first-launch upgrade run preserves every existing instrument row (no data loss); the deterministic merge rule is applied per the migration spec.
- Sign-out and account-switch wipe `profile`, `instrument`, and the price-cache tables from `profile-index.sqlite`.
- All new tests above pass; existing contract / store / sync tests continue to pass.
- `RateQueryPlanTests` (extended for the shared DB) confirms `WHERE base = ?` against `exchange_rate` uses the PK's leading-column scan (no `exchange_rate_lookup` index exists in the shared DB; see §Local schema → Price-cache tables).
- `DEBUG`-build runtime trap catches any residual `InstrumentRecord` write to a `profile-<UUID>` zone (zero hits in CI).
- `RegistryInvariantTests` confirms `id == record_name` for every InstrumentRecord roundtrip.
- The `observeChanges()` doc-comment in `Domain/Repositories/InstrumentRegistryRepository.swift:80-100` is updated to reflect that the stream now fires for both local mutations and remote-arriving rows on the profile-index zone. (Pre-merge gate, not a follow-up — without this update, callers may continue to wire redundant per-profile remote-change subscriptions.)
- The `v10_drop_shared_instrument_legacy` migration ID is reserved by an inline comment in `Backends/GRDB/ProfileSchema.swift` (added in the same PR as this design doc) so a parallel unrelated migration cannot silently claim `v10` before the follow-up spec ships.
- No change to user-visible Settings UI in this work item; the UI relocation is a separate spec built on this.
