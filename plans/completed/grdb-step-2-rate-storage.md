# Step 2 — Rate Storage to GRDB (detailed plan)

**Status:** In progress.
**Roadmap context:** `plans/grdb-migration.md` §6 → Step 2.
**Worktree:** `.worktrees/rate-storage-grdb/` on branch `refactor/rate-storage-grdb`.
**Parent branch:** `build/add-grdb-spm` (PR #556 — once merged, rebase this branch onto `main`).

---

## 1. Goal

Move the FX / stock / crypto rate caches off gzipped JSON files in `Caches/` and into per-profile SQLite tables managed by GRDB. The existing `ExchangeRateService` / `StockPriceService` / `CryptoPriceService` actors keep their **public API and protocols unchanged** (per the existing decision in `plans/grdb-migration.md` §4 — "Don't redesign the rate services and what they store. Just change how they store it"). Conversion lookups continue to happen in Swift; multi-step conversion paths stay deferred (no SQL conversion arithmetic in Step 2).

---

## 2. What's already done on the branch

Commit `60811a5` on `refactor/rate-storage-grdb`:

| File | Purpose |
|---|---|
| `Backends/GRDB/ProfileDatabase.swift` | `DatabaseQueue` factory: `open(at:)` + `openInMemory()`. Applies project PRAGMA defaults. Runs `ProfileSchema.migrator`. |
| `Backends/GRDB/ProfileSchema.swift` | `DatabaseMigrator` with `v1_exchange_rate`, `v1_stock_price`, `v1_crypto_price` migrations. Tables `STRICT`, price tables `WITHOUT ROWID`, indexes per `DATABASE_SCHEMA_GUIDE.md` §4. |
| `Backends/GRDB/Records/ExchangeRateRecord.swift` | One row in `exchange_rate`. `Sendable`, `Codable`, `FetchableRecord, PersistableRecord`. |
| `Backends/GRDB/Records/ExchangeRateMetaRecord.swift` | Per-base meta: `earliest_date`, `latest_date`. |
| `Backends/GRDB/Records/StockPriceRecord.swift` | One row in `stock_price`. |
| `Backends/GRDB/Records/StockTickerMetaRecord.swift` | Per-ticker meta: `instrument_id`, `earliest_date`, `latest_date`. |
| `Backends/GRDB/Records/CryptoPriceRecord.swift` | One row in `crypto_price` (USD). |
| `Backends/GRDB/Records/CryptoTokenMetaRecord.swift` | Per-token meta: `symbol`, `earliest_date`, `latest_date`. |

Build green on macOS at the scaffolding commit. `format-check` clean.

---

## 3. What's left

### 3.1 Rewrite the three rate services

Three files, same shape of change:

- `Shared/ExchangeRateService.swift`
- `Shared/StockPriceService.swift`
- `Shared/CryptoPriceService.swift`

For each:

1. **Constructor signature change.** Replace `cacheDirectory: URL?` with `database: any DatabaseWriter`. The `dateFormatter` and other internal state stay. The `client` and `cacheDirectory` parameter pair becomes `client` and `database`.
2. **Keep the in-memory cache structures.** `private var caches: [String: ExchangeRateCache]` (and the equivalents on the other two) stay as the hot read path. They hydrate from SQL on first access and persist to SQL on update. The `ExchangeRateCache` / `StockPriceCache` / `CryptoPriceCache` value types in `Domain/Models/` stay unchanged.
3. **Replace `loadCacheFromDisk(base:)` (et al.).** Now reads from SQL:
   ```swift
   private func loadCacheFromDatabase(base: String) async {
       guard let cache = try? await database.read({ db in
           let rates = try ExchangeRateRecord
               .filter(Column("base") == base)
               .fetchAll(db)
           let meta = try ExchangeRateMetaRecord.fetchOne(db, key: base)
           return Self.assemble(base: base, rates: rates, meta: meta)
       }) else { return }
       caches[base] = cache
   }
   ```
   `assemble` is a static helper that turns flat `[ExchangeRateRecord]` rows into the nested `[date: [quote: Decimal]]` shape the in-memory cache uses. Note the `Double → Decimal` conversion at the boundary.
4. **Replace `saveCacheToDisk(base:)` (et al.).** Single transaction:
   ```swift
   private func saveCacheToDatabase(base: String) async {
       guard let cache = caches[base] else { return }
       try? await database.write { db in
           try ExchangeRateRecord
               .filter(Column("base") == base)
               .deleteAll(db)
           for (date, byQuote) in cache.rates {
               for (quote, rate) in byQuote {
                   let record = ExchangeRateRecord(
                       base: base, quote: quote, date: date,
                       rate: NSDecimalNumber(decimal: rate).doubleValue)
                   try record.insert(db)
               }
           }
           try ExchangeRateMetaRecord(
               base: base,
               earliestDate: cache.earliestDate,
               latestDate: cache.latestDate
           ).upsert(db)
       }
   }
   ```
   Consider an incremental save (`merge` only inserts new rows) instead of delete-and-rewrite, depending on profiling. The simple delete-and-rewrite is correct and fits one transaction; optimise later if needed.
5. **Stock service variant.** `StockPriceCache` carries `instrument: Instrument` (the ticker's denomination, discovered from the Yahoo client). The `stock_ticker_meta.instrument_id` column stores `instrument.id`. On load, materialise back to `Instrument` via `Instrument.fiat(code:)` (or however the existing service constructs it on first fetch — read the file to confirm).
6. **Crypto service variant.** `CryptoPriceCache.symbol` is display-only; goes into `crypto_token_meta.symbol`. Prices are USD-denominated, so the column is `price_usd`. No anchor-instrument trickery.
7. **Remove the gzip helpers.** `compress(_:)` / `decompress(_:)` and `cacheFileURL(base:)` are no longer needed. Delete cleanly.

**Public surface stays exactly the same.** Confirm by diffing the function signatures in the rewrite — `rate(from:to:on:)`, `rates(from:to:in:)`, `convert(_:to:on:)`, `prefetchLatest(base:)` (and the equivalents on the other two services) keep their async signatures and return types.

### 3.2 Wire the `DatabaseQueue` lifecycle into `ProfileSession`

`App/ProfileSession.swift`:

- Add a stored property `let database: DatabaseQueue` near the top.
- Construct it in `init(...)` via `try ProfileDatabase.open(at: ...)`. Path:
  ```swift
  URL.moolahScopedApplicationSupport
      .appendingPathComponent("Moolah", isDirectory: true)
      .appendingPathComponent("profiles", isDirectory: true)
      .appendingPathComponent(profile.id.uuidString, isDirectory: true)
      .appendingPathComponent("data.sqlite")
  ```
  This mirrors the existing `importStagingDirectory(for:)` pattern (`ProfileSession.swift:229-234`).
- The `init` already throws via no-throw construction today; making it `throws` is a wider-blast change. Two options:
  - **Preferred:** keep `init` non-throwing; wrap the open in a `try!` only if it can never legitimately fail (it can — disk full, permissions). Better: add `init(...) throws` and update the (small set of) call sites in `App/SessionManager.swift` and previews. Trace the call sites first; if they're all `Task { ... }` blocks they can absorb a `throw` cheaply.
  - **Fallback:** lazy-load the queue. Adds complexity; avoid unless `init throws` propagation is genuinely too invasive.

**Lifecycle:** `DatabaseQueue` cleans up on dealloc — no explicit close needed when the session goes out of scope. On profile delete, the directory at `profiles/<id>/` should be removed (along with `-wal` / `-shm` sidecars per `DATABASE_SCHEMA_GUIDE.md` §7); locate the existing profile-delete path and verify it removes the whole directory rather than just one known file.

### 3.3 Thread the queue through to the rate services

`App/ProfileSession+Factories.swift`:

- `MarketDataServices` struct stays.
- `Self.makeMarketDataServices()` becomes `Self.makeMarketDataServices(database:)`.
- Pass `self.database` from `ProfileSession.init`.
- Update the three constructors at `:33-35` to pass `database:` instead of relying on the default `cacheDirectory: nil`.

### 3.4 One-shot legacy JSON cache cleanup

Single-launch wipe of the old gzipped-JSON directories so users don't keep dead bytes around. Probably the right place is `App/MoolahApp+Setup.swift` (run once during first launch after the upgrade).

```swift
// gated by UserDefaults flag "v2.rates.cache.cleared"
private func cleanupLegacyRateCachesOnce() {
    let key = "v2.rates.cache.cleared"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    let caches = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)
        .first
    guard let caches else { return }
    for sub in ["exchange-rates", "stock-prices", "crypto-prices"] {
        try? FileManager.default.removeItem(at: caches.appendingPathComponent(sub))
    }
    UserDefaults.standard.set(true, forKey: key)
}
```

This is best-effort. Network re-fetch repopulates the GRDB tables on demand via the existing `prefetchLatest(...)` paths.

### 3.5 Tests

- `MoolahTests/Shared/ExchangeRateServiceTests.swift` (and the equivalents for stocks/crypto) — replace the temp-directory fixtures with in-memory `DatabaseQueue` via `try ProfileDatabase.openInMemory()`. Existing test bodies should still apply with minimal change since the public API hasn't changed.
- New test: **rollback on multi-statement save**. Seed prior state, force a constraint violation mid-save (e.g. by writing a record with an oversized value to trip a CHECK), assert the previous state survives. Reference pattern: `MoolahTests/Backends/SQLiteCoinGeckoCatalogStorageTests.swift:77-104`.
- The existing `MoolahTests/Support/Fixtures/` JSON files are still useful as they feed the network-mocked clients, not the cache layer.

### 3.6 Reviewer agents

Run before opening the PR:

- `database-schema-review` — schema + migrator + PRAGMAs (already in commit `60811a5`, but run anyway in case a follow-up edit touches them).
- `database-code-review` — record types, service rewrites, repository pattern, transactions, plan-pinning tests (note: rate lookups don't have plan-pinning tests since we're not doing SQL aggregation in this step).
- `concurrency-review` — `DatabaseQueue` lifecycle in `ProfileSession`, any actor-isolation changes.
- `code-review` — general style.

---

## 4. File-level inventory of remaining edits

| File | Action |
|---|---|
| `Shared/ExchangeRateService.swift` | Rewrite persistence layer; constructor takes `database` |
| `Shared/StockPriceService.swift` | Rewrite persistence layer; constructor takes `database` |
| `Shared/CryptoPriceService.swift` | Rewrite persistence layer; constructor takes `database` |
| `App/ProfileSession.swift` | Add `let database: DatabaseQueue` + open-on-init |
| `App/ProfileSession+Factories.swift` | Thread `database` to `MarketDataServices` constructors |
| `App/MoolahApp+Setup.swift` | One-shot legacy JSON cache cleanup |
| `App/SessionManager.swift` | If `ProfileSession.init` becomes `throws`, propagate |
| `MoolahTests/Shared/ExchangeRateServiceTests.swift` | In-memory DB seam |
| `MoolahTests/Shared/ExchangeRateServiceTestsMore.swift` | Same |
| `MoolahTests/Shared/StockPriceServiceTests.swift` | Same |
| `MoolahTests/Shared/StockPriceServiceTestsMore.swift` | Same |
| `MoolahTests/Shared/CryptoPriceServiceTests.swift` | Same |
| `MoolahTests/Shared/CryptoPriceServiceTestsMore.swift` | Same |
| `MoolahTests/Shared/InstrumentConversionServiceCryptoTests.swift` | If it constructs the service directly, update |
| `MoolahTests/Shared/InstrumentConversionServiceStockTests.swift` | Same |
| Profile-delete code path | Verify it removes the whole `profiles/<id>/` directory, not just known sub-files |
| New test file (rollback) | Multi-statement save rollback test for one of the three services |

(Search for `cacheDirectory:` and `ExchangeRateService(client:` / `StockPriceService(client:` / `CryptoPriceService(client:` to find all construction sites that need updating.)

---

## 5. Acceptance criteria

- `just build-mac` ✅ and `just build-ios` ✅ on the branch.
- `just test` passes — all existing rate-service tests adapted to the new construction shape.
- `just format-check` clean.
- Network behaviour unchanged from the user's perspective: rates fetched on demand, cached for offline reuse, prefetch-latest still works.
- After first launch with the new build:
  - `Caches/exchange-rates/`, `Caches/stock-prices/`, `Caches/crypto-prices/` directories deleted.
  - `Application Support/moolah/profiles/<id>/data.sqlite` exists with rate tables populated as the user uses the app.
- All four reviewer agents (`database-schema-review`, `database-code-review`, `concurrency-review`, `code-review`) report clean, or any findings are addressed before the PR is queued.

---

## 6. Workflow constraints

- **Branch is local-only** until PR #556 (build/add-grdb-spm) merges. After it merges:
  - `git -C .worktrees/rate-storage-grdb fetch origin && git -C .worktrees/rate-storage-grdb rebase origin/main`
  - The rebase will detect that commit `d288b43` (Step 1's content) is already in main and skip it; the scaffolding commit `60811a5` and any new commits land cleanly on top.
- **Do not push** the branch before #556 merges — pushing the unrebased branch and opening a PR before main has Step 1's content would make the PR diff include both Step 1 and Step 2 changes.
- **PR convention:** open against `main` with `gh pr create --base main`, queue via `~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR>`. See the project's merge-queue skill.
- **Pre-PR:** the four reviewer agents run against the working tree only — no PR-description evidence. EXPLAIN-QUERY-PLAN tests are not relevant in Step 2 (no SQL aggregation), but reviewer findings on the schema/code are.
- **Format & build before commit:** `just format` then `just format-check`; `just build-mac` and `just build-ios`. Pre-commit checklist in `CLAUDE.md` is non-optional.

---

## 7. Reference reading

- `plans/grdb-migration.md` — overall roadmap and decisions.
- `guides/DATABASE_SCHEMA_GUIDE.md` — schema rules (STRICT, indexes, PRAGMAs, migrations, backup).
- `guides/DATABASE_CODE_GUIDE.md` — Swift / GRDB rules (concurrency, records, queries, SQL injection, tests).
- `guides/CONCURRENCY_GUIDE.md` — actor isolation and Sendable rules.
- `Domain/Models/ExchangeRateCache.swift`, `Domain/Models/StockPriceCache.swift`, `Domain/Models/CryptoPriceCache.swift` — in-memory cache shapes (unchanged).
- `Backends/CoinGecko/SQLiteCoinGeckoCatalog.swift` and `MoolahTests/Backends/SQLiteCoinGeckoCatalogStorageTests.swift` — reference patterns for actor scoping, transaction discipline, rollback tests.
- `App/ProfileSession.swift` — the per-profile lifecycle this work plugs into.
