# Instrument Registry UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the existing instrument registry backend into a usable UI: a curated `/coins/list`-backed crypto picker, Yahoo-backed stock search, a sync→registry change-fan-out, and a tightened `ensureInstrument` boundary.

**Architecture:** Bottom-up. (1) Stand up a new SQLite-backed `CoinGeckoCatalog` and integrate `refreshIfStale()` into the session lifecycle. (2) Add a parallel `StockSearchClient` over Yahoo's name-search endpoint. (3) Rewire `InstrumentSearchService` and `InstrumentPickerStore` so the picker handles fiat / stock / crypto registration end-to-end. (4) Replace the contract-address `AddTokenSheet` with a thin search-only wrapper. (5) Add a `notifyExternalChange()` fan-out that sync uses. (6) Tighten `ensureInstrument` so the unmapped-crypto state cannot recur. (7) End-to-end UI test.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, SwiftData (existing), `SQLite3` (system), `URLSession`, XCTest, XCUITest.

**Reference:** [`plans/2026-04-27-instrument-registry-ui-design.md`](2026-04-27-instrument-registry-ui-design.md) for design rationale and decision tags D1–D10.

---

## File Map

### New files (production)

- `Shared/CoinGeckoCatalog.swift` — protocol + value types (`CatalogEntry`, `PlatformBinding`).
- `Backends/CoinGecko/SQLiteCoinGeckoCatalog.swift` — concrete actor combining SQLite store and refresh logic.
- `Backends/CoinGecko/CoinGeckoCatalogSchema.swift` — schema constant + version. Bumping the version invalidates existing files.
- `Domain/Repositories/StockSearchClient.swift` — protocol + `StockSearchHit`, `QuoteType`.
- `Backends/YahooFinance/YahooFinanceStockSearchClient.swift` — Yahoo `/v1/finance/search` impl.
- `Domain/Repositories/RepositoryError.swift` — only if not already present; otherwise extend in place.

### Modified production files

- `Shared/InstrumentSearchService.swift` — replaces `CryptoSearchClient` with `CoinGeckoCatalog`; adds `StockSearchClient` dependency; drops `providerSources`.
- `Shared/InstrumentPickerStore.swift` — drops `.stocksOnly`; extends `select(_:)` to register crypto via `resolve()` → `registerCrypto`.
- `Features/Settings/AddTokenSheet.swift` — rewritten as a thin `InstrumentPickerSheet` wrapper.
- `Features/Settings/CryptoTokenStore.swift` — drops `resolveToken`, `confirmRegistration`, `resolvedRegistration`, `isResolving`.
- `Backends/CloudKit/Repositories/CloudKitInstrumentRegistryRepository.swift` — adds `notifyExternalChange()`.
- `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift` (and `+BatchUpsert.swift`, `+QueueAndDelete.swift`) — accept `onInstrumentRemoteChange: @Sendable () -> Void`; fire once per sync transaction that touched any `InstrumentRecord`.
- `App/ProfileSession+Factories.swift` — wires the new closure and the catalog into the registry/search-service factory.
- `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift` — `ensureInstrument` throws on unmapped crypto.
- `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift` — same.

### Test files (new)

- `MoolahTests/Backends/SQLiteCoinGeckoCatalogTests.swift`
- `MoolahTests/Backends/YahooFinanceStockSearchClientTests.swift`
- `MoolahTests/Shared/InstrumentSearchServiceTests.swift` (extend if exists)
- `MoolahTests/Shared/InstrumentPickerStoreTests.swift` (extend if exists)
- `MoolahTests/Backends/CloudKit/CloudKitInstrumentRegistryRepositoryTests.swift` (extend if exists; otherwise create)
- `MoolahTests/Backends/CloudKit/Sync/ProfileDataSyncHandlerInstrumentChangeTests.swift`
- `MoolahTests/Backends/CloudKit/CloudKitTransactionRepositoryEnsureInstrumentTests.swift`
- `MoolahTests/Backends/CloudKit/CloudKitAccountRepositoryEnsureInstrumentTests.swift`
- `MoolahUITests_macOS/InstrumentPickerCryptoSearchTests.swift`
- `MoolahTests/Support/Fixtures/coingecko-coins-list-small.json` (≤30 entries; ETag `W/"a"`)
- `MoolahTests/Support/Fixtures/coingecko-coins-list-small-updated.json` (same shape, different rows; ETag `W/"b"`)
- `MoolahTests/Support/Fixtures/coingecko-asset-platforms.json`
- `MoolahTests/Support/Fixtures/yahoo-finance-search-apple.json`

### Conventions

- Every command runs from the worktree root (`.worktrees/instrument-registry-ui-impl`).
- Pipe test output to `.agent-tmp/<descriptive-name>.txt` per CLAUDE.md.
- `just generate` after editing `project.yml`.
- `just format` before every commit.
- Test seeds: `MoolahTests/Support/TestCurrency.swift` provides `Currency.defaultTestCurrency`.

---

## Task Index

| # | Task | Layer |
|---|---|---|
| 1 | `CoinGeckoCatalog` protocol + value types | Shared |
| 2 | `CoinGeckoCatalogSchema` constant | Backend |
| 3 | `SQLiteCoinGeckoCatalog` — open / schema bootstrap / replace-all transaction | Backend |
| 4 | `SQLiteCoinGeckoCatalog` — FTS5 search (two-step) | Backend |
| 5 | `SQLiteCoinGeckoCatalog` — ETag-aware refresh | Backend |
| 6 | `StockSearchClient` protocol + `YahooFinanceStockSearchClient` | Backend |
| 7 | `InstrumentSearchService`: catalog + stock search, drop `providerSources` | Shared |
| 8 | `ProfileSession` integration: build the catalog, call `refreshIfStale()` | App |
| 9 | `InstrumentPickerStore`: register crypto on `select(_:)`, drop `.stocksOnly` | Shared |
| 10 | `AddTokenSheet` rewrite + `CryptoTokenStore` trim | UI |
| 11 | `CloudKitInstrumentRegistryRepository.notifyExternalChange()` | Backend |
| 12 | Sync change-fan-out: `ProfileDataSyncHandler` + closure wiring | Backend / Sync |
| 13 | `RepositoryError.unmappedCryptoInstrument` case | Domain |
| 14 | Tighten `ensureInstrument` — transaction repo | Backend |
| 15 | Tighten `ensureInstrument` — account repo | Backend |
| 16 | XCUITest: register a crypto token from the picker | UI test |

Branch: `feature/instrument-registry-ui` (one PR per task; queue via merge-queue per project policy).

---

## Task 1 — `CoinGeckoCatalog` protocol + value types

**Files:**
- Create: `Shared/CoinGeckoCatalog.swift`
- Test: `MoolahTests/Shared/CoinGeckoCatalogTypesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Shared/CoinGeckoCatalogTypesTests.swift
import XCTest
@testable import Moolah

final class CoinGeckoCatalogTypesTests: XCTestCase {
  func testPlatformBindingNormalisesContractAddressToLowercase() {
    let binding = PlatformBinding(slug: "ethereum", chainId: 1, contractAddress: "0xABCDef1234")
    XCTAssertEqual(binding.contractAddress, "0xabcdef1234")
  }

  func testCatalogEntryReturnsHighestPriorityPlatform() {
    let entry = CatalogEntry(
      coingeckoId: "usd-coin",
      symbol: "USDC",
      name: "USD Coin",
      platforms: [
        PlatformBinding(slug: "polygon-pos", chainId: 137, contractAddress: "0xpolygon"),
        PlatformBinding(slug: "ethereum", chainId: 1, contractAddress: "0xethereum"),
      ]
    )
    XCTAssertEqual(entry.preferredPlatform?.slug, "ethereum")
  }

  func testCatalogEntryWithoutPlatformsReturnsNilPreferred() {
    let entry = CatalogEntry(coingeckoId: "btc", symbol: "BTC", name: "Bitcoin", platforms: [])
    XCTAssertNil(entry.preferredPlatform)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mkdir -p .agent-tmp
just test CoinGeckoCatalogTypesTests 2>&1 | tee .agent-tmp/task1.txt
```

Expected: FAIL with `cannot find 'PlatformBinding' in scope` (or similar — type doesn't exist yet).

- [ ] **Step 3: Add the file to project.yml + write the implementation**

Add `Shared/CoinGeckoCatalog.swift` to the `Moolah` target's source group in `project.yml` if not auto-globbed (verify by running `just generate` and checking the resulting Xcode project).

```swift
// Shared/CoinGeckoCatalog.swift
import Foundation

/// One coin from the cached CoinGecko catalogue snapshot. Carries every
/// platform binding the picker needs to call `TokenResolutionClient.resolve()`.
struct CatalogEntry: Sendable, Hashable, Identifiable {
  let coingeckoId: String
  let symbol: String
  let name: String
  let platforms: [PlatformBinding]

  var id: String { coingeckoId }

  /// First platform binding by canonical priority — used by the picker to
  /// resolve a search hit to a `(chainId, contractAddress)` pair. `nil`
  /// when the coin is platformless (cross-chain natives like BTC, ETH).
  var preferredPlatform: PlatformBinding? { platforms.first }
}

/// One coin's binding to a single chain. `chainId` is `nil` when the
/// platform slug isn't known to `/asset_platforms` (typically non-EVM).
struct PlatformBinding: Sendable, Hashable {
  let slug: String
  let chainId: Int?
  let contractAddress: String

  init(slug: String, chainId: Int?, contractAddress: String) {
    self.slug = slug
    self.chainId = chainId
    self.contractAddress = contractAddress.lowercased()
  }
}

/// Read-only catalogue of CoinGecko coins. Backed by a refreshable SQLite
/// snapshot of `/coins/list?include_platform=true`. See
/// `plans/2026-04-27-instrument-registry-ui-design.md` §4.1 / §6 for shape.
protocol CoinGeckoCatalog: Sendable {
  /// Returns up to `limit` matching entries with their full platform list
  /// attached, ordered by FTS BM25 rank. Empty when the snapshot is missing
  /// or the query has no hits.
  func search(query: String, limit: Int) async -> [CatalogEntry]

  /// Triggered once per app session. Never blocks the caller; refresh runs
  /// on a background task and logs failures via `os_log`. Honours the 24 h
  /// max-age and ETag conditional-GET semantics described in design §5.4.
  func refreshIfStale() async
}
```

`CatalogEntry`'s `platforms` ordering is established by `SQLiteCoinGeckoCatalog` (Task 4). The `preferredPlatform` accessor is a derived convenience.

- [ ] **Step 4: Run tests to verify they pass + format**

```bash
just test CoinGeckoCatalogTypesTests 2>&1 | tee .agent-tmp/task1.txt
just format
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Shared/CoinGeckoCatalog.swift MoolahTests/Shared/CoinGeckoCatalogTypesTests.swift project.yml
git commit -m "feat(catalog): add CoinGeckoCatalog protocol and value types"
rm .agent-tmp/task1.txt
```

---

## Task 2 — `CoinGeckoCatalogSchema` constant

**Files:**
- Create: `Backends/CoinGecko/CoinGeckoCatalogSchema.swift`
- Test: `MoolahTests/Backends/CoinGeckoCatalogSchemaTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Backends/CoinGeckoCatalogSchemaTests.swift
import XCTest
@testable import Moolah

final class CoinGeckoCatalogSchemaTests: XCTestCase {
  func testSchemaVersionStartsAtOne() {
    XCTAssertEqual(CoinGeckoCatalogSchema.version, 1)
  }

  func testSchemaContainsCoreTables() {
    let ddl = CoinGeckoCatalogSchema.statements.joined(separator: "\n")
    XCTAssertTrue(ddl.contains("CREATE TABLE meta"))
    XCTAssertTrue(ddl.contains("CREATE TABLE coin"))
    XCTAssertTrue(ddl.contains("CREATE TABLE coin_platform"))
    XCTAssertTrue(ddl.contains("CREATE TABLE platform"))
    XCTAssertTrue(ddl.contains("CREATE VIRTUAL TABLE coin_fts USING fts5"))
  }

  func testSchemaInstallsFtsTriggers() {
    let ddl = CoinGeckoCatalogSchema.statements.joined(separator: "\n")
    XCTAssertTrue(ddl.contains("CREATE TRIGGER coin_ai"))
    XCTAssertTrue(ddl.contains("CREATE TRIGGER coin_ad"))
    XCTAssertTrue(ddl.contains("CREATE TRIGGER coin_au"))
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test CoinGeckoCatalogSchemaTests 2>&1 | tee .agent-tmp/task2.txt
```

Expected: FAIL — `cannot find 'CoinGeckoCatalogSchema' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Backends/CoinGecko/CoinGeckoCatalogSchema.swift
import Foundation

/// Single source of truth for the CoinGecko-catalogue SQLite schema.
/// Bump `version` whenever the on-disk shape changes; the catalogue
/// implementation drops and recreates the file rather than running a
/// migration. See design §3 D4.
enum CoinGeckoCatalogSchema {
  static let version: Int = 1

  static let statements: [String] = [
    "PRAGMA journal_mode = WAL;",
    "PRAGMA foreign_keys = ON;",

    """
    CREATE TABLE meta (
      schema_version  INTEGER NOT NULL,
      last_fetched    REAL,
      coins_etag      TEXT,
      platforms_etag  TEXT
    );
    """,

    "INSERT INTO meta (schema_version) VALUES (\(version));",

    """
    CREATE TABLE coin (
      rowid          INTEGER PRIMARY KEY,
      coingecko_id   TEXT NOT NULL UNIQUE,
      symbol         TEXT NOT NULL,
      name           TEXT NOT NULL
    );
    """,

    """
    CREATE TABLE coin_platform (
      coingecko_id     TEXT NOT NULL,
      platform_slug    TEXT NOT NULL,
      contract_address TEXT NOT NULL,
      PRIMARY KEY (coingecko_id, platform_slug),
      FOREIGN KEY (coingecko_id) REFERENCES coin(coingecko_id) ON DELETE CASCADE
    );
    """,

    """
    CREATE INDEX coin_platform_chain_contract
      ON coin_platform(platform_slug, contract_address);
    """,

    """
    CREATE TABLE platform (
      slug      TEXT PRIMARY KEY,
      chain_id  INTEGER,
      name      TEXT NOT NULL
    );
    """,

    """
    CREATE VIRTUAL TABLE coin_fts USING fts5(
      symbol, name,
      content='coin',
      content_rowid='rowid',
      tokenize='unicode61 remove_diacritics 1'
    );
    """,

    """
    CREATE TRIGGER coin_ai AFTER INSERT ON coin BEGIN
      INSERT INTO coin_fts(rowid, symbol, name) VALUES (new.rowid, new.symbol, new.name);
    END;
    """,

    """
    CREATE TRIGGER coin_ad AFTER DELETE ON coin BEGIN
      INSERT INTO coin_fts(coin_fts, rowid, symbol, name)
      VALUES('delete', old.rowid, old.symbol, old.name);
    END;
    """,

    """
    CREATE TRIGGER coin_au AFTER UPDATE ON coin BEGIN
      INSERT INTO coin_fts(coin_fts, rowid, symbol, name)
      VALUES('delete', old.rowid, old.symbol, old.name);
      INSERT INTO coin_fts(rowid, symbol, name) VALUES (new.rowid, new.symbol, new.name);
    END;
    """,
  ]

  /// Built-in priority order for picking a coin's preferred chain when it
  /// is listed on multiple platforms. Slugs not in this list fall through
  /// to the order returned from SQLite.
  static let platformPriority: [String] = [
    "ethereum",
    "polygon-pos",
    "binance-smart-chain",
    "base",
    "arbitrum-one",
    "optimism",
    "avalanche",
  ]
}
```

- [ ] **Step 4: Run tests to verify they pass + format**

```bash
just test CoinGeckoCatalogSchemaTests 2>&1 | tee .agent-tmp/task2.txt
just format
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Backends/CoinGecko/CoinGeckoCatalogSchema.swift MoolahTests/Backends/CoinGeckoCatalogSchemaTests.swift project.yml
git commit -m "feat(catalog): add CoinGeckoCatalog SQLite schema"
rm .agent-tmp/task2.txt
```

---

## Task 3 — `SQLiteCoinGeckoCatalog`: open / schema bootstrap / replace-all

**Files:**
- Create: `Backends/CoinGecko/SQLiteCoinGeckoCatalog.swift`
- Create: `MoolahTests/Backends/SQLiteCoinGeckoCatalogStorageTests.swift`

This task installs the storage layer only — search and refresh come in Tasks 4 and 5.

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Backends/SQLiteCoinGeckoCatalogStorageTests.swift
import XCTest
@testable import Moolah

final class SQLiteCoinGeckoCatalogStorageTests: XCTestCase {
  private var tempDir: URL!

  override func setUpWithError() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("catalog-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  func testOpenCreatesFreshSchema() async throws {
    let catalog = try SQLiteCoinGeckoCatalog(directory: tempDir)
    let dbURL = tempDir.appendingPathComponent("catalog.sqlite")
    XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
    let meta = try await catalog.readMetaForTesting()
    XCTAssertEqual(meta.schemaVersion, CoinGeckoCatalogSchema.version)
    XCTAssertNil(meta.lastFetched)
    XCTAssertNil(meta.coinsEtag)
    XCTAssertNil(meta.platformsEtag)
  }

  func testReplaceAllCoinsAndPlatformsCommitsAtomically() async throws {
    let catalog = try SQLiteCoinGeckoCatalog(directory: tempDir)
    let coins = [
      RawCoin(id: "bitcoin", symbol: "BTC", name: "Bitcoin", platforms: [:]),
      RawCoin(
        id: "uniswap", symbol: "UNI", name: "Uniswap",
        platforms: ["ethereum": "0x1F9840a85d5aF5bf1D1762F925BDADdC4201F984"]
      ),
    ]
    let platforms = [
      RawPlatform(slug: "ethereum", chainId: 1, name: "Ethereum"),
    ]
    try await catalog.replaceAllForTesting(coins: coins, platforms: platforms)

    let count = try await catalog.coinCountForTesting()
    XCTAssertEqual(count, 2)
    let platformCount = try await catalog.platformCountForTesting()
    XCTAssertEqual(platformCount, 1)
    let coinPlatformCount = try await catalog.coinPlatformCountForTesting()
    XCTAssertEqual(coinPlatformCount, 1)
  }

  func testReplaceAllReplacesPriorContent() async throws {
    let catalog = try SQLiteCoinGeckoCatalog(directory: tempDir)
    let first = [RawCoin(id: "bitcoin", symbol: "BTC", name: "Bitcoin", platforms: [:])]
    let second = [
      RawCoin(id: "ethereum", symbol: "ETH", name: "Ethereum", platforms: [:]),
      RawCoin(id: "tether", symbol: "USDT", name: "Tether", platforms: [:]),
    ]
    try await catalog.replaceAllForTesting(coins: first, platforms: [])
    try await catalog.replaceAllForTesting(coins: second, platforms: [])

    XCTAssertEqual(try await catalog.coinCountForTesting(), 2)
  }

  func testSchemaVersionMismatchRecreatesFile() async throws {
    _ = try SQLiteCoinGeckoCatalog(directory: tempDir)
    let dbURL = tempDir.appendingPathComponent("catalog.sqlite")
    let creationOriginal = try FileManager.default.attributesOfItem(atPath: dbURL.path)[.creationDate] as? Date

    // Simulate stored version from a future build.
    let stale = try SQLiteCoinGeckoCatalog(directory: tempDir)
    try await stale.writeMetaSchemaVersionForTesting(999)

    // Re-open should detect mismatch and recreate.
    let reopened = try SQLiteCoinGeckoCatalog(directory: tempDir)
    let metaAfter = try await reopened.readMetaForTesting()
    XCTAssertEqual(metaAfter.schemaVersion, CoinGeckoCatalogSchema.version)

    let creationNew = try FileManager.default.attributesOfItem(atPath: dbURL.path)[.creationDate] as? Date
    XCTAssertNotEqual(creationOriginal, creationNew)
  }
}
```

The `RawCoin` / `RawPlatform` / `MetaSnapshot` value types and the `*ForTesting` accessors are exposed as `internal` on the actor — they would otherwise be private. Mark them `// MARK: Test seams` and document their purpose.

- [ ] **Step 2: Run test to verify it fails**

```bash
just test SQLiteCoinGeckoCatalogStorageTests 2>&1 | tee .agent-tmp/task3.txt
```

Expected: FAIL — `cannot find 'SQLiteCoinGeckoCatalog' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Backends/CoinGecko/SQLiteCoinGeckoCatalog.swift
import Foundation
import SQLite3
import os

/// Catalogue actor backing `CoinGeckoCatalog` with a local SQLite database
/// at `<directory>/catalog.sqlite`. Public methods are `async`; all SQLite
/// work runs on the actor's serial executor so the connection is never
/// shared across threads. See design §4.1 / §6.
actor SQLiteCoinGeckoCatalog: CoinGeckoCatalog {
  private let directory: URL
  private let session: URLSession
  private let log = Logger(subsystem: "moolah.instrument-registry", category: "catalog")
  private var db: OpaquePointer?

  init(
    directory: URL,
    session: URLSession = .shared
  ) throws {
    self.directory = directory
    self.session = session
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true
    )
    try open()
  }

  deinit {
    if let db { sqlite3_close_v2(db) }
  }

  // MARK: - CoinGeckoCatalog

  func search(query: String, limit: Int) async -> [CatalogEntry] {
    [] // Implemented in Task 4.
  }

  func refreshIfStale() async {
    // Implemented in Task 5.
  }

  // MARK: - Schema bootstrap

  private var dbURL: URL {
    directory.appendingPathComponent("catalog.sqlite")
  }

  private func open() throws {
    if FileManager.default.fileExists(atPath: dbURL.path) {
      try connect()
      let storedVersion = try readSchemaVersion()
      if storedVersion != CoinGeckoCatalogSchema.version {
        sqlite3_close_v2(db)
        db = nil
        try FileManager.default.removeItem(at: dbURL)
        try FileManager.default.removeItem(
          at: dbURL.appendingPathExtension("wal").deletingPathExtension())
        try createFresh()
      }
    } else {
      try createFresh()
    }
  }

  private func connect() throws {
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    let rc = sqlite3_open_v2(dbURL.path, &handle, flags, nil)
    guard rc == SQLITE_OK, let handle else {
      throw CatalogError.sqlite("open failed: \(rc)")
    }
    db = handle
  }

  private func createFresh() throws {
    try connect()
    for stmt in CoinGeckoCatalogSchema.statements {
      try exec(stmt)
    }
  }

  // MARK: - Replace-all

  internal struct RawCoin: Sendable {
    let id: String
    let symbol: String
    let name: String
    /// platform slug → contract address (verbatim, normalised on insert)
    let platforms: [String: String]
  }

  internal struct RawPlatform: Sendable {
    let slug: String
    let chainId: Int?
    let name: String
  }

  internal struct MetaSnapshot: Sendable, Equatable {
    let schemaVersion: Int
    let lastFetched: Date?
    let coinsEtag: String?
    let platformsEtag: String?
  }

  internal func replaceAllForTesting(coins: [RawCoin], platforms: [RawPlatform]) throws {
    try replaceAll(coins: coins, platforms: platforms)
  }

  internal func readMetaForTesting() throws -> MetaSnapshot { try readMeta() }
  internal func coinCountForTesting() throws -> Int { try scalarInt("SELECT COUNT(*) FROM coin") }
  internal func platformCountForTesting() throws -> Int {
    try scalarInt("SELECT COUNT(*) FROM platform")
  }
  internal func coinPlatformCountForTesting() throws -> Int {
    try scalarInt("SELECT COUNT(*) FROM coin_platform")
  }
  internal func writeMetaSchemaVersionForTesting(_ version: Int) throws {
    try exec("UPDATE meta SET schema_version = \(version);")
  }

  fileprivate func replaceAll(coins: [RawCoin], platforms: [RawPlatform]) throws {
    try exec("BEGIN IMMEDIATE;")
    do {
      try exec("DELETE FROM coin;")
      try exec("DELETE FROM platform;")

      if !coins.isEmpty {
        var insertCoin: OpaquePointer?
        try prepare(
          "INSERT INTO coin (coingecko_id, symbol, name) VALUES (?, ?, ?);", &insertCoin)
        defer { sqlite3_finalize(insertCoin) }
        var insertCoinPlatform: OpaquePointer?
        try prepare(
          "INSERT INTO coin_platform (coingecko_id, platform_slug, contract_address) "
            + "VALUES (?, ?, ?);", &insertCoinPlatform)
        defer { sqlite3_finalize(insertCoinPlatform) }

        for coin in coins {
          try bind(insertCoin, 1, coin.id)
          try bind(insertCoin, 2, coin.symbol)
          try bind(insertCoin, 3, coin.name)
          try step(insertCoin)
          sqlite3_reset(insertCoin)

          for (slug, contract) in coin.platforms {
            guard !contract.isEmpty else { continue }
            try bind(insertCoinPlatform, 1, coin.id)
            try bind(insertCoinPlatform, 2, slug)
            try bind(insertCoinPlatform, 3, contract.lowercased())
            try step(insertCoinPlatform)
            sqlite3_reset(insertCoinPlatform)
          }
        }
      }

      if !platforms.isEmpty {
        var insertPlatform: OpaquePointer?
        try prepare(
          "INSERT INTO platform (slug, chain_id, name) VALUES (?, ?, ?);", &insertPlatform)
        defer { sqlite3_finalize(insertPlatform) }
        for platform in platforms {
          try bind(insertPlatform, 1, platform.slug)
          if let chainId = platform.chainId {
            try bind(insertPlatform, 2, chainId)
          } else {
            sqlite3_bind_null(insertPlatform, 2)
          }
          try bind(insertPlatform, 3, platform.name)
          try step(insertPlatform)
          sqlite3_reset(insertPlatform)
        }
      }

      try exec("COMMIT;")
    } catch {
      try? exec("ROLLBACK;")
      throw error
    }
  }

  // MARK: - Meta read / write

  private func readMeta() throws -> MetaSnapshot {
    var statement: OpaquePointer?
    try prepare(
      "SELECT schema_version, last_fetched, coins_etag, platforms_etag FROM meta LIMIT 1;",
      &statement)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw CatalogError.sqlite("meta table empty")
    }
    let version = Int(sqlite3_column_int64(statement, 0))
    let lastFetched: Date? = {
      let raw = sqlite3_column_double(statement, 1)
      if sqlite3_column_type(statement, 1) == SQLITE_NULL { return nil }
      return Date(timeIntervalSince1970: raw)
    }()
    let coinsEtag = readText(statement, column: 2)
    let platformsEtag = readText(statement, column: 3)
    return MetaSnapshot(
      schemaVersion: version,
      lastFetched: lastFetched,
      coinsEtag: coinsEtag,
      platformsEtag: platformsEtag
    )
  }

  private func readSchemaVersion() throws -> Int {
    return try readMeta().schemaVersion
  }

  // MARK: - Low-level SQLite helpers

  private func exec(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    let rc = sqlite3_exec(db, sql, nil, nil, &error)
    if rc != SQLITE_OK {
      let message = error.map { String(cString: $0) } ?? "code \(rc)"
      sqlite3_free(error)
      throw CatalogError.sqlite("exec failed: \(message)")
    }
  }

  private func prepare(_ sql: String, _ statement: inout OpaquePointer?) throws {
    let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard rc == SQLITE_OK else {
      throw CatalogError.sqlite("prepare failed: \(rc) for \(sql)")
    }
  }

  private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) throws {
    let rc = sqlite3_bind_text(
      statement, index, value, -1,
      unsafeBitCast(Int(-1), to: sqlite3_destructor_type.self)
    )
    guard rc == SQLITE_OK else { throw CatalogError.sqlite("bind text \(rc)") }
  }

  private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Int) throws {
    let rc = sqlite3_bind_int64(statement, index, Int64(value))
    guard rc == SQLITE_OK else { throw CatalogError.sqlite("bind int \(rc)") }
  }

  private func step(_ statement: OpaquePointer?) throws {
    let rc = sqlite3_step(statement)
    guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
      throw CatalogError.sqlite("step \(rc)")
    }
  }

  private func scalarInt(_ sql: String) throws -> Int {
    var statement: OpaquePointer?
    try prepare(sql, &statement)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw CatalogError.sqlite("scalar empty")
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func readText(_ statement: OpaquePointer?, column: Int32) -> String? {
    guard let cString = sqlite3_column_text(statement, column) else { return nil }
    return String(cString: cString)
  }

  enum CatalogError: Error, Equatable {
    case sqlite(String)
  }
}
```

The `unsafeBitCast(Int(-1), to: sqlite3_destructor_type.self)` is the SQLITE_TRANSIENT marker (forces SQLite to copy the bound string). This is the standard Swift workaround for the missing C macro.

- [ ] **Step 4: Run tests to verify they pass + format**

```bash
just generate
just test SQLiteCoinGeckoCatalogStorageTests 2>&1 | tee .agent-tmp/task3.txt
just format
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Backends/CoinGecko/SQLiteCoinGeckoCatalog.swift MoolahTests/Backends/SQLiteCoinGeckoCatalogStorageTests.swift project.yml
git commit -m "feat(catalog): SQLite-backed CoinGecko catalogue (storage layer)"
rm .agent-tmp/task3.txt
```

---

## Task 4 — `SQLiteCoinGeckoCatalog`: FTS5 search

**Files:**
- Modify: `Backends/CoinGecko/SQLiteCoinGeckoCatalog.swift` (replace `search(query:limit:)` body)
- Create: `MoolahTests/Backends/SQLiteCoinGeckoCatalogSearchTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Backends/SQLiteCoinGeckoCatalogSearchTests.swift
import XCTest
@testable import Moolah

final class SQLiteCoinGeckoCatalogSearchTests: XCTestCase {
  private var tempDir: URL!
  private var catalog: SQLiteCoinGeckoCatalog!

  override func setUpWithError() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("search-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    catalog = try SQLiteCoinGeckoCatalog(directory: tempDir)
  }

  override func tearDownWithError() throws {
    catalog = nil
    try? FileManager.default.removeItem(at: tempDir)
  }

  private func seedFixture() async throws {
    let coins: [SQLiteCoinGeckoCatalog.RawCoin] = [
      .init(id: "bitcoin", symbol: "BTC", name: "Bitcoin", platforms: [:]),
      .init(
        id: "ethereum", symbol: "ETH", name: "Ethereum",
        platforms: [:]
      ),
      .init(
        id: "uniswap", symbol: "UNI", name: "Uniswap",
        platforms: [
          "ethereum": "0x1F9840a85d5aF5bf1D1762F925BDADdC4201F984",
          "polygon-pos": "0xb33EaAd8d922B1083446DC23f610c2567fB5180f",
        ]
      ),
      .init(id: "tether", symbol: "USDT", name: "Tether", platforms: [:]),
      .init(id: "blockstack", symbol: "STX", name: "Stacks", platforms: [:]),
    ]
    let platforms: [SQLiteCoinGeckoCatalog.RawPlatform] = [
      .init(slug: "ethereum", chainId: 1, name: "Ethereum"),
      .init(slug: "polygon-pos", chainId: 137, name: "Polygon"),
    ]
    try await catalog.replaceAllForTesting(coins: coins, platforms: platforms)
  }

  func testSymbolPrefixHits() async throws {
    try await seedFixture()
    let results = await catalog.search(query: "btc", limit: 10)
    XCTAssertEqual(results.first?.coingeckoId, "bitcoin")
  }

  func testNameTokenHits() async throws {
    try await seedFixture()
    let results = await catalog.search(query: "uniswap", limit: 10)
    XCTAssertEqual(results.first?.coingeckoId, "uniswap")
  }

  func testPlatformsAttachedToHit() async throws {
    try await seedFixture()
    let results = await catalog.search(query: "uni", limit: 10)
    let uni = try XCTUnwrap(results.first { $0.coingeckoId == "uniswap" })
    XCTAssertEqual(uni.platforms.first?.slug, "ethereum")
    XCTAssertEqual(uni.platforms.first?.chainId, 1)
    XCTAssertEqual(uni.platforms.first?.contractAddress, "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984")
    XCTAssertTrue(uni.platforms.contains { $0.slug == "polygon-pos" })
  }

  func testPlatformOrderingHonoursPriority() async throws {
    try await seedFixture()
    let results = await catalog.search(query: "uni", limit: 10)
    let uni = try XCTUnwrap(results.first { $0.coingeckoId == "uniswap" })
    XCTAssertEqual(uni.platforms.map(\.slug), ["ethereum", "polygon-pos"])
  }

  func testEmptyQueryReturnsEmpty() async throws {
    try await seedFixture()
    let results = await catalog.search(query: "", limit: 10)
    XCTAssertTrue(results.isEmpty)
  }

  func testLimitIsRespected() async throws {
    try await seedFixture()
    let results = await catalog.search(query: "e*", limit: 2)
    XCTAssertLessThanOrEqual(results.count, 2)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test SQLiteCoinGeckoCatalogSearchTests 2>&1 | tee .agent-tmp/task4.txt
```

Expected: FAIL — `search` currently returns `[]`.

- [ ] **Step 3: Implement `search(query:limit:)`**

Replace the existing stub in `SQLiteCoinGeckoCatalog.swift`:

```swift
func search(query: String, limit: Int) async -> [CatalogEntry] {
  let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty, limit > 0 else { return [] }

  do {
    let ranked = try fetchRankedCoins(query: trimmed, limit: limit)
    guard !ranked.isEmpty else { return [] }
    let bindings = try fetchPlatformBindings(coingeckoIds: ranked.map(\.id))
    return ranked.map { row in
      CatalogEntry(
        coingeckoId: row.id,
        symbol: row.symbol,
        name: row.name,
        platforms: orderedPlatforms(for: row.id, bindings: bindings)
      )
    }
  } catch {
    log.error("search failed: \(String(describing: error), privacy: .public)")
    return []
  }
}

private struct RankedCoin {
  let id: String
  let symbol: String
  let name: String
}

private func fetchRankedCoins(query: String, limit: Int) throws -> [RankedCoin] {
  let ftsQuery = ftsQueryString(for: query)
  var statement: OpaquePointer?
  try prepare(
    """
    SELECT c.coingecko_id, c.symbol, c.name
    FROM coin_fts JOIN coin c ON c.rowid = coin_fts.rowid
    WHERE coin_fts MATCH ?
    ORDER BY rank
    LIMIT ?;
    """,
    &statement
  )
  defer { sqlite3_finalize(statement) }
  try bind(statement, 1, ftsQuery)
  try bind(statement, 2, limit)
  var rows: [RankedCoin] = []
  while sqlite3_step(statement) == SQLITE_ROW {
    let id = readText(statement, column: 0) ?? ""
    let symbol = readText(statement, column: 1) ?? ""
    let name = readText(statement, column: 2) ?? ""
    rows.append(RankedCoin(id: id, symbol: symbol, name: name))
  }
  return rows
}

private func fetchPlatformBindings(coingeckoIds: [String])
  throws -> [String: [PlatformBinding]] {
  guard !coingeckoIds.isEmpty else { return [:] }
  let placeholders = Array(repeating: "?", count: coingeckoIds.count).joined(separator: ", ")
  var statement: OpaquePointer?
  try prepare(
    """
    SELECT cp.coingecko_id, cp.platform_slug, cp.contract_address, p.chain_id
    FROM coin_platform cp
    LEFT JOIN platform p ON p.slug = cp.platform_slug
    WHERE cp.coingecko_id IN (\(placeholders));
    """,
    &statement
  )
  defer { sqlite3_finalize(statement) }
  for (offset, id) in coingeckoIds.enumerated() {
    try bind(statement, Int32(offset + 1), id)
  }
  var bindingsById: [String: [PlatformBinding]] = [:]
  while sqlite3_step(statement) == SQLITE_ROW {
    let coingeckoId = readText(statement, column: 0) ?? ""
    let slug = readText(statement, column: 1) ?? ""
    let contract = readText(statement, column: 2) ?? ""
    let chainId: Int? =
      sqlite3_column_type(statement, 3) == SQLITE_NULL
      ? nil : Int(sqlite3_column_int64(statement, 3))
    bindingsById[coingeckoId, default: []].append(
      PlatformBinding(slug: slug, chainId: chainId, contractAddress: contract)
    )
  }
  return bindingsById
}

private func orderedPlatforms(
  for coingeckoId: String,
  bindings: [String: [PlatformBinding]]
) -> [PlatformBinding] {
  let raw = bindings[coingeckoId] ?? []
  let priority = CoinGeckoCatalogSchema.platformPriority
  return raw.sorted { lhs, rhs in
    let lp = priority.firstIndex(of: lhs.slug) ?? Int.max
    let rp = priority.firstIndex(of: rhs.slug) ?? Int.max
    if lp != rp { return lp < rp }
    return lhs.slug < rhs.slug
  }
}

private func ftsQueryString(for query: String) -> String {
  // Tokenise on whitespace; quote each token to escape FTS punctuation;
  // append `*` for prefix match. e.g. "btc" → `"btc"*`, "apple inc" →
  // `"apple"* "inc"*`.
  let tokens =
    query
    .components(separatedBy: .whitespaces)
    .filter { !$0.isEmpty }
    .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
  return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
}
```

- [ ] **Step 4: Run tests to verify they pass + format**

```bash
just test SQLiteCoinGeckoCatalogSearchTests 2>&1 | tee .agent-tmp/task4.txt
just format
```

Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Backends/CoinGecko/SQLiteCoinGeckoCatalog.swift MoolahTests/Backends/SQLiteCoinGeckoCatalogSearchTests.swift
git commit -m "feat(catalog): FTS5 search with attached platform bindings"
rm .agent-tmp/task4.txt
```

---

## Task 5 — `SQLiteCoinGeckoCatalog`: ETag-aware refresh

**Files:**
- Modify: `Backends/CoinGecko/SQLiteCoinGeckoCatalog.swift` (replace `refreshIfStale()` stub; add network types and parsing)
- Create: `MoolahTests/Support/Fixtures/coingecko-coins-list-small.json`
- Create: `MoolahTests/Support/Fixtures/coingecko-coins-list-small-updated.json`
- Create: `MoolahTests/Support/Fixtures/coingecko-asset-platforms.json`
- Create: `MoolahTests/Backends/SQLiteCoinGeckoCatalogRefreshTests.swift`

- [ ] **Step 1: Write the fixtures**

`MoolahTests/Support/Fixtures/coingecko-coins-list-small.json`:

```json
[
  {"id": "bitcoin", "symbol": "btc", "name": "Bitcoin", "platforms": {}},
  {"id": "ethereum", "symbol": "eth", "name": "Ethereum", "platforms": {}},
  {"id": "uniswap", "symbol": "uni", "name": "Uniswap",
   "platforms": {"ethereum": "0x1F9840a85d5aF5bf1D1762F925BDADdC4201F984"}}
]
```

`MoolahTests/Support/Fixtures/coingecko-coins-list-small-updated.json`:

```json
[
  {"id": "bitcoin", "symbol": "btc", "name": "Bitcoin", "platforms": {}},
  {"id": "ethereum", "symbol": "eth", "name": "Ethereum", "platforms": {}},
  {"id": "uniswap", "symbol": "uni", "name": "Uniswap",
   "platforms": {"ethereum": "0x1F9840a85d5aF5bf1D1762F925BDADdC4201F984"}},
  {"id": "pepe", "symbol": "pepe", "name": "Pepe",
   "platforms": {"ethereum": "0x6982508145454Ce325dDbE47a25d4ec3d2311933"}}
]
```

`MoolahTests/Support/Fixtures/coingecko-asset-platforms.json`:

```json
[
  {"id": "ethereum", "chain_identifier": 1, "name": "Ethereum"},
  {"id": "polygon-pos", "chain_identifier": 137, "name": "Polygon POS"},
  {"id": "solana", "chain_identifier": null, "name": "Solana"}
]
```

- [ ] **Step 2: Write the failing test**

```swift
// MoolahTests/Backends/SQLiteCoinGeckoCatalogRefreshTests.swift
import XCTest
@testable import Moolah

final class SQLiteCoinGeckoCatalogRefreshTests: XCTestCase {
  private var tempDir: URL!

  override func setUpWithError() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("refresh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    URLProtocol.registerClass(StubURLProtocol.self)
  }

  override func tearDownWithError() throws {
    URLProtocol.unregisterClass(StubURLProtocol.self)
    StubURLProtocol.handlers = [:]
    try? FileManager.default.removeItem(at: tempDir)
  }

  private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
  }

  private func loadFixture(_ name: String) throws -> Data {
    let bundle = Bundle(for: type(of: self))
    let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"))
    return try Data(contentsOf: url)
  }

  func testRefreshDownloadsAndPopulates() async throws {
    let coinsData = try loadFixture("coingecko-coins-list-small")
    let platformsData = try loadFixture("coingecko-asset-platforms")
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/coins/list"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"a1\""), coinsData)
    }
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/asset_platforms"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"p1\""), platformsData)
    }

    let catalog = try SQLiteCoinGeckoCatalog(directory: tempDir, session: makeSession())
    await catalog.refreshIfStale()
    let count = try await catalog.coinCountForTesting()
    XCTAssertEqual(count, 3)
    let platforms = try await catalog.platformCountForTesting()
    XCTAssertEqual(platforms, 3)
    let meta = try await catalog.readMetaForTesting()
    XCTAssertEqual(meta.coinsEtag, "W/\"a1\"")
    XCTAssertEqual(meta.platformsEtag, "W/\"p1\"")
    XCTAssertNotNil(meta.lastFetched)
  }

  func testRefreshSendsIfNoneMatchOnSubsequentCall() async throws {
    let coinsData = try loadFixture("coingecko-coins-list-small")
    let platformsData = try loadFixture("coingecko-asset-platforms")
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/coins/list"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"a1\""), coinsData)
    }
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/asset_platforms"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"p1\""), platformsData)
    }
    let catalog = try SQLiteCoinGeckoCatalog(directory: tempDir, session: makeSession())
    await catalog.refreshIfStale()

    // Fast-forward `last_fetched` so the next call is "stale".
    try await catalog.bumpLastFetchedBackwardForTesting(by: 25 * 3600)

    var capturedHeaders: [String: String] = [:]
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/coins/list"] = { request in
      request.allHTTPHeaderFields?.forEach { capturedHeaders[$0.key] = $0.value }
      return (HTTPURLResponse.notModified(), Data())
    }
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/asset_platforms"] = { _ in
      (HTTPURLResponse.notModified(), Data())
    }
    await catalog.refreshIfStale()
    XCTAssertEqual(capturedHeaders["If-None-Match"], "W/\"a1\"")
  }

  func testRefreshSkippedWhenWithinMaxAge() async throws {
    let coinsData = try loadFixture("coingecko-coins-list-small")
    let platformsData = try loadFixture("coingecko-asset-platforms")
    var coinsCallCount = 0
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/coins/list"] = { _ in
      coinsCallCount += 1
      return (HTTPURLResponse.ok(etag: "W/\"a1\""), coinsData)
    }
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/asset_platforms"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"p1\""), platformsData)
    }
    let catalog = try SQLiteCoinGeckoCatalog(directory: tempDir, session: makeSession())
    await catalog.refreshIfStale()
    await catalog.refreshIfStale()

    XCTAssertEqual(coinsCallCount, 1)
  }

  func testRefreshOnNetworkErrorPreservesPriorSnapshot() async throws {
    let coinsData = try loadFixture("coingecko-coins-list-small")
    let platformsData = try loadFixture("coingecko-asset-platforms")
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/coins/list"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"a1\""), coinsData)
    }
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/asset_platforms"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"p1\""), platformsData)
    }
    let catalog = try SQLiteCoinGeckoCatalog(directory: tempDir, session: makeSession())
    await catalog.refreshIfStale()
    try await catalog.bumpLastFetchedBackwardForTesting(by: 25 * 3600)

    StubURLProtocol.handlers["api.coingecko.com:/api/v3/coins/list"] = { _ in
      throw URLError(.notConnectedToInternet)
    }
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/asset_platforms"] = { _ in
      throw URLError(.notConnectedToInternet)
    }
    await catalog.refreshIfStale()
    XCTAssertEqual(try await catalog.coinCountForTesting(), 3)  // unchanged
  }

  func testRefreshAcceptsUpdatedSnapshot() async throws {
    let firstCoins = try loadFixture("coingecko-coins-list-small")
    let secondCoins = try loadFixture("coingecko-coins-list-small-updated")
    let platforms = try loadFixture("coingecko-asset-platforms")
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/coins/list"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"a1\""), firstCoins)
    }
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/asset_platforms"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"p1\""), platforms)
    }
    let catalog = try SQLiteCoinGeckoCatalog(directory: tempDir, session: makeSession())
    await catalog.refreshIfStale()
    try await catalog.bumpLastFetchedBackwardForTesting(by: 25 * 3600)

    StubURLProtocol.handlers["api.coingecko.com:/api/v3/coins/list"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"a2\""), secondCoins)
    }
    await catalog.refreshIfStale()
    XCTAssertEqual(try await catalog.coinCountForTesting(), 4)
    let pepe = await catalog.search(query: "pepe", limit: 5)
    XCTAssertEqual(pepe.first?.coingeckoId, "pepe")
    let meta = try await catalog.readMetaForTesting()
    XCTAssertEqual(meta.coinsEtag, "W/\"a2\"")
  }
}

// Lightweight URLProtocol stub. Place at end of file so it's only visible
// to refresh tests; if reused later, lift to MoolahTests/Support/.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  static var handlers: [String: (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let host = url.host else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let key = "\(host):\(url.path)"
    guard let handler = Self.handlers[key] else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

extension HTTPURLResponse {
  static func ok(etag: String) -> HTTPURLResponse {
    HTTPURLResponse(
      url: URL(string: "https://example.invalid")!,
      statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["ETag": etag, "Content-Type": "application/json"])!
  }
  static func notModified() -> HTTPURLResponse {
    HTTPURLResponse(
      url: URL(string: "https://example.invalid")!,
      statusCode: 304, httpVersion: "HTTP/1.1", headerFields: [:])!
  }
}
```

- [ ] **Step 3: Run test to verify it fails**

```bash
just test SQLiteCoinGeckoCatalogRefreshTests 2>&1 | tee .agent-tmp/task5.txt
```

Expected: FAIL — `bumpLastFetchedBackwardForTesting` and the `refreshIfStale` body are stubs.

- [ ] **Step 4: Implement `refreshIfStale` and related parsing**

Add to `SQLiteCoinGeckoCatalog.swift` (replace stub):

```swift
private static let coinsListURL = URL(
  string: "https://api.coingecko.com/api/v3/coins/list?include_platform=true")!
private static let assetPlatformsURL = URL(
  string: "https://api.coingecko.com/api/v3/asset_platforms")!
private static let maxAge: TimeInterval = 24 * 3600

func refreshIfStale() async {
  do {
    let meta = try readMeta()
    if let lastFetched = meta.lastFetched,
      Date().timeIntervalSince(lastFetched) < Self.maxAge {
      return
    }
    let coinsResult = try await fetchConditional(
      url: Self.coinsListURL, ifNoneMatch: meta.coinsEtag
    )
    let platformsResult = try await fetchConditional(
      url: Self.assetPlatformsURL, ifNoneMatch: meta.platformsEtag
    )

    var newCoinsEtag = meta.coinsEtag
    var newPlatformsEtag = meta.platformsEtag

    var rawCoinsToInsert: [RawCoin]?
    var rawPlatformsToInsert: [RawPlatform]?

    switch coinsResult {
    case .notModified:
      break
    case .ok(let body, let etag):
      rawCoinsToInsert = try Self.parseCoins(body)
      newCoinsEtag = etag
    }
    switch platformsResult {
    case .notModified:
      break
    case .ok(let body, let etag):
      rawPlatformsToInsert = try Self.parsePlatforms(body)
      newPlatformsEtag = etag
    }

    if rawCoinsToInsert != nil || rawPlatformsToInsert != nil {
      try replaceAllOrPartial(
        coins: rawCoinsToInsert,
        platforms: rawPlatformsToInsert
      )
    }
    try writeMeta(
      lastFetched: Date(),
      coinsEtag: newCoinsEtag,
      platformsEtag: newPlatformsEtag
    )
  } catch {
    log.error("refresh failed: \(String(describing: error), privacy: .public)")
  }
}

private enum FetchOutcome {
  case ok(Data, etag: String?)
  case notModified
}

private func fetchConditional(url: URL, ifNoneMatch: String?) async throws -> FetchOutcome {
  var request = URLRequest(url: url)
  if let ifNoneMatch { request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match") }
  request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
  let (data, response) = try await session.data(for: request)
  guard let http = response as? HTTPURLResponse else { throw CatalogError.sqlite("non-HTTP") }
  switch http.statusCode {
  case 200:
    return .ok(data, etag: http.value(forHTTPHeaderField: "ETag"))
  case 304:
    return .notModified
  default:
    throw CatalogError.sqlite("status \(http.statusCode) for \(url.absoluteString)")
  }
}

private static func parseCoins(_ data: Data) throws -> [RawCoin] {
  struct Wire: Decodable {
    let id: String
    let symbol: String
    let name: String
    let platforms: [String: String]?
  }
  let decoded = try JSONDecoder().decode([Wire].self, from: data)
  return decoded.map { RawCoin(
    id: $0.id,
    symbol: $0.symbol.uppercased(),
    name: $0.name,
    platforms: ($0.platforms ?? [:]).filter { !$0.value.isEmpty }
  ) }
}

private static func parsePlatforms(_ data: Data) throws -> [RawPlatform] {
  struct Wire: Decodable {
    let id: String
    let chain_identifier: Int?
    let name: String
  }
  let decoded = try JSONDecoder().decode([Wire].self, from: data)
  return decoded.map { RawPlatform(slug: $0.id, chainId: $0.chain_identifier, name: $0.name) }
}

private func replaceAllOrPartial(coins: [RawCoin]?, platforms: [RawPlatform]?) throws {
  // If only one side changed, retain the other side's existing rows.
  if let coins, let platforms {
    try replaceAll(coins: coins, platforms: platforms)
    return
  }
  if let coins {
    try exec("BEGIN IMMEDIATE;")
    do {
      try exec("DELETE FROM coin;")
      try insertCoins(coins)
      try exec("COMMIT;")
    } catch {
      try? exec("ROLLBACK;")
      throw error
    }
  }
  if let platforms {
    try exec("BEGIN IMMEDIATE;")
    do {
      try exec("DELETE FROM platform;")
      try insertPlatforms(platforms)
      try exec("COMMIT;")
    } catch {
      try? exec("ROLLBACK;")
      throw error
    }
  }
}

private func insertCoins(_ coins: [RawCoin]) throws {
  var insertCoin: OpaquePointer?
  try prepare(
    "INSERT INTO coin (coingecko_id, symbol, name) VALUES (?, ?, ?);", &insertCoin)
  defer { sqlite3_finalize(insertCoin) }
  var insertPlatform: OpaquePointer?
  try prepare(
    "INSERT INTO coin_platform (coingecko_id, platform_slug, contract_address) VALUES (?, ?, ?);",
    &insertPlatform)
  defer { sqlite3_finalize(insertPlatform) }
  for coin in coins {
    try bind(insertCoin, 1, coin.id)
    try bind(insertCoin, 2, coin.symbol)
    try bind(insertCoin, 3, coin.name)
    try step(insertCoin)
    sqlite3_reset(insertCoin)
    for (slug, contract) in coin.platforms {
      try bind(insertPlatform, 1, coin.id)
      try bind(insertPlatform, 2, slug)
      try bind(insertPlatform, 3, contract.lowercased())
      try step(insertPlatform)
      sqlite3_reset(insertPlatform)
    }
  }
}

private func insertPlatforms(_ platforms: [RawPlatform]) throws {
  var insertPlatform: OpaquePointer?
  try prepare(
    "INSERT INTO platform (slug, chain_id, name) VALUES (?, ?, ?);", &insertPlatform)
  defer { sqlite3_finalize(insertPlatform) }
  for platform in platforms {
    try bind(insertPlatform, 1, platform.slug)
    if let chainId = platform.chainId { try bind(insertPlatform, 2, chainId) }
    else { sqlite3_bind_null(insertPlatform, 2) }
    try bind(insertPlatform, 3, platform.name)
    try step(insertPlatform)
    sqlite3_reset(insertPlatform)
  }
}

private func writeMeta(lastFetched: Date, coinsEtag: String?, platformsEtag: String?) throws {
  var statement: OpaquePointer?
  try prepare(
    "UPDATE meta SET last_fetched = ?, coins_etag = ?, platforms_etag = ?;", &statement)
  defer { sqlite3_finalize(statement) }
  sqlite3_bind_double(statement, 1, lastFetched.timeIntervalSince1970)
  if let coinsEtag { try bind(statement, 2, coinsEtag) } else { sqlite3_bind_null(statement, 2) }
  if let platformsEtag { try bind(statement, 3, platformsEtag) }
  else { sqlite3_bind_null(statement, 3) }
  try step(statement)
}

internal func bumpLastFetchedBackwardForTesting(by seconds: TimeInterval) throws {
  try exec("UPDATE meta SET last_fetched = COALESCE(last_fetched, 0) - \(seconds);")
}
```

- [ ] **Step 5: Run tests + format + commit**

```bash
just test SQLiteCoinGeckoCatalogRefreshTests 2>&1 | tee .agent-tmp/task5.txt
just format
git add Backends/CoinGecko/SQLiteCoinGeckoCatalog.swift MoolahTests/Backends/SQLiteCoinGeckoCatalogRefreshTests.swift MoolahTests/Support/Fixtures/coingecko-coins-list-small.json MoolahTests/Support/Fixtures/coingecko-coins-list-small-updated.json MoolahTests/Support/Fixtures/coingecko-asset-platforms.json
git commit -m "feat(catalog): ETag-aware refresh against /coins/list and /asset_platforms"
rm .agent-tmp/task5.txt
```

Expected: 5 tests pass.

---

## Task 8 — `ProfileSession` integration: build the catalog and call `refreshIfStale()`

**Files:**
- Modify: `App/ProfileSession.swift` (add `coinGeckoCatalog: CoinGeckoCatalog?` stored property)
- Modify: `App/ProfileSession+Factories.swift` (extend `makeRegistryWiring` to construct the catalog and trigger refresh)

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/App/ProfileSessionCatalogIntegrationTests.swift
import XCTest
@testable import Moolah

@MainActor
final class ProfileSessionCatalogIntegrationTests: XCTestCase {
  func testCloudKitProfileExposesCatalog() async throws {
    let backend = TestBackend.cloudKit()
    let session = ProfileSession.makeForTest(backend: backend)
    XCTAssertNotNil(session.coinGeckoCatalog)
  }

  func testRemoteProfileHasNoCatalog() async throws {
    let backend = TestBackend.remote()
    let session = ProfileSession.makeForTest(backend: backend)
    XCTAssertNil(session.coinGeckoCatalog)
  }
}
```

`TestBackend.cloudKit()` and `.remote()` already exist for the existing test wiring. `ProfileSession.makeForTest(backend:)` is a test factory that wraps `makeRegistryWiring`; if it doesn't exist, add it as part of this task using the same composition `App/MoolahApp+Setup.swift` uses today.

- [ ] **Step 2: Run test to verify it fails**

```bash
just test ProfileSessionCatalogIntegrationTests 2>&1 | tee .agent-tmp/task6.txt
```

Expected: FAIL — `coinGeckoCatalog` not a member of `ProfileSession`.

- [ ] **Step 3: Implement**

Add to `App/ProfileSession.swift`:

```swift
let coinGeckoCatalog: (any CoinGeckoCatalog)?
```

Add it to the `init` argument list and the existing `RegistryWiring` initialiser path.

In `App/ProfileSession+Factories.swift`, extend `RegistryWiring`:

```swift
struct RegistryWiring {
  let registry: (any InstrumentRegistryRepository)?
  let cryptoTokenStore: CryptoTokenStore?
  let searchService: InstrumentSearchService?
  let coinGeckoCatalog: (any CoinGeckoCatalog)?
}
```

In `makeRegistryWiring`:

```swift
@MainActor
static func makeRegistryWiring(
  backend: BackendProvider,
  cryptoPriceService: CryptoPriceService,
  yahooPriceFetcher: any YahooFinancePriceFetcher,
  coinGeckoApiKey: String?
) -> RegistryWiring {
  guard let cloudBackend = backend as? CloudKitBackend else {
    return RegistryWiring(
      registry: nil, cryptoTokenStore: nil, searchService: nil, coinGeckoCatalog: nil)
  }

  let catalogDirectory = catalogDirectoryURL()
  let catalog: (any CoinGeckoCatalog)?
  do {
    catalog = try SQLiteCoinGeckoCatalog(directory: catalogDirectory)
    Task.detached(priority: .background) { [catalog] in
      await catalog?.refreshIfStale()
    }
  } catch {
    Logger(subsystem: "moolah.instrument-registry", category: "session")
      .error("catalog init failed: \(String(describing: error), privacy: .public)")
    catalog = nil
  }

  let store = CryptoTokenStore(
    registry: cloudBackend.instrumentRegistry,
    cryptoPriceService: cryptoPriceService)
  let searchService = InstrumentSearchService(
    registry: cloudBackend.instrumentRegistry,
    catalog: catalog,
    resolutionClient: CompositeTokenResolutionClient(coinGeckoApiKey: coinGeckoApiKey),
    stockSearchClient: YahooFinanceStockSearchClient(),
    stockValidator: YahooFinanceStockTickerValidator(priceFetcher: yahooPriceFetcher)
  )
  return RegistryWiring(
    registry: cloudBackend.instrumentRegistry,
    cryptoTokenStore: store,
    searchService: searchService,
    coinGeckoCatalog: catalog
  )
}

private static func catalogDirectoryURL() -> URL {
  let support = try? FileManager.default.url(
    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
  return (support ?? URL(fileURLWithPath: NSTemporaryDirectory()))
    .appendingPathComponent("InstrumentRegistry", isDirectory: true)
}
```

The `InstrumentSearchService(...)` and `YahooFinanceStockSearchClient()` shapes used here come from Tasks 6 and 7 — execute those first.

- [ ] **Step 4: Run tests + format**

```bash
just test ProfileSessionCatalogIntegrationTests 2>&1 | tee .agent-tmp/task6.txt
just format
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add App/ProfileSession.swift App/ProfileSession+Factories.swift MoolahTests/App/ProfileSessionCatalogIntegrationTests.swift project.yml
git commit -m "feat(session): wire CoinGeckoCatalog into ProfileSession lifecycle"
rm .agent-tmp/task6.txt
```

---

## Task 6 — `StockSearchClient` protocol + `YahooFinanceStockSearchClient`

**Files:**
- Create: `Domain/Repositories/StockSearchClient.swift`
- Create: `Backends/YahooFinance/YahooFinanceStockSearchClient.swift`
- Create: `MoolahTests/Support/Fixtures/yahoo-finance-search-apple.json`
- Create: `MoolahTests/Backends/YahooFinanceStockSearchClientTests.swift`

- [ ] **Step 1: Write the fixture**

`MoolahTests/Support/Fixtures/yahoo-finance-search-apple.json` — a trimmed copy of an actual Yahoo response (use this exact content):

```json
{
  "explains": [],
  "count": 6,
  "quotes": [
    {"symbol":"AAPL","shortname":"Apple Inc.","exchange":"NMS","quoteType":"EQUITY"},
    {"symbol":"APC.DE","shortname":"Apple Inc.                    R","exchange":"GER","quoteType":"EQUITY"},
    {"symbol":"APLE.TO","shortname":"HARVEST APPLE ENHNCD HIGH INCM  ","exchange":"TOR","quoteType":"ETF"},
    {"symbol":"AAPY.DE","shortname":"Leverage Shares PLC           E","exchange":"GER","quoteType":"OPTION"},
    {"symbol":"^GSPC","shortname":"S&P 500","exchange":"SNP","quoteType":"INDEX"},
    {"symbol":"FXAIX","shortname":"Fidelity 500 Index Fund","exchange":"NAS","quoteType":"MUTUALFUND"}
  ],
  "news": []
}
```

- [ ] **Step 2: Write the failing test**

```swift
// MoolahTests/Backends/YahooFinanceStockSearchClientTests.swift
import XCTest
@testable import Moolah

final class YahooFinanceStockSearchClientTests: XCTestCase {
  override func setUp() { URLProtocol.registerClass(StubURLProtocol.self) }
  override func tearDown() {
    URLProtocol.unregisterClass(StubURLProtocol.self)
    StubURLProtocol.handlers = [:]
  }

  private func session() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
  }

  private func loadFixture() throws -> Data {
    try Data(contentsOf: XCTUnwrap(
      Bundle(for: type(of: self)).url(
        forResource: "yahoo-finance-search-apple", withExtension: "json")))
  }

  func testReturnsEquityEtfMutualFundOnly() async throws {
    let data = try loadFixture()
    StubURLProtocol.handlers["query1.finance.yahoo.com:/v1/finance/search"] = { _ in
      (HTTPURLResponse.ok(etag: ""), data)
    }
    let client = YahooFinanceStockSearchClient(session: session())
    let hits = try await client.search(query: "apple")
    XCTAssertEqual(hits.map(\.symbol), ["AAPL", "APC.DE", "APLE.TO", "FXAIX"])
  }

  func testNamesAreTrimmed() async throws {
    let data = try loadFixture()
    StubURLProtocol.handlers["query1.finance.yahoo.com:/v1/finance/search"] = { _ in
      (HTTPURLResponse.ok(etag: ""), data)
    }
    let client = YahooFinanceStockSearchClient(session: session())
    let hits = try await client.search(query: "apple")
    XCTAssertEqual(hits.first { $0.symbol == "APC.DE" }?.name, "Apple Inc.                    R".trimmingCharacters(in: .whitespaces))
  }

  func testQueryParamsAreSentCorrectly() async throws {
    let data = try loadFixture()
    var captured: URL?
    StubURLProtocol.handlers["query1.finance.yahoo.com:/v1/finance/search"] = { request in
      captured = request.url
      return (HTTPURLResponse.ok(etag: ""), data)
    }
    let client = YahooFinanceStockSearchClient(session: session())
    _ = try await client.search(query: "apple")
    let components = URLComponents(url: try XCTUnwrap(captured), resolvingAgainstBaseURL: false)
    let items = components?.queryItems?.reduce(into: [String: String]()) {
      $0[$1.name] = $1.value
    } ?? [:]
    XCTAssertEqual(items["q"], "apple")
    XCTAssertEqual(items["quotesCount"], "20")
    XCTAssertEqual(items["newsCount"], "0")
  }
}
```

The `StubURLProtocol` and `HTTPURLResponse.ok(etag:)` helpers are the same as in Task 5; either copy them locally or — if Task 5 has landed — extract to `MoolahTests/Support/StubURLProtocol.swift` and update both call sites.

- [ ] **Step 3: Run test to verify it fails**

```bash
just test YahooFinanceStockSearchClientTests 2>&1 | tee .agent-tmp/task7.txt
```

Expected: FAIL — `cannot find 'YahooFinanceStockSearchClient' in scope`.

- [ ] **Step 4: Implement**

```swift
// Domain/Repositories/StockSearchClient.swift
import Foundation

struct StockSearchHit: Sendable, Hashable {
  let symbol: String
  let name: String
  let exchange: String
  let quoteType: QuoteType
}

enum QuoteType: String, Sendable, Hashable, CaseIterable {
  case equity = "EQUITY"
  case etf = "ETF"
  case mutualFund = "MUTUALFUND"
}

protocol StockSearchClient: Sendable {
  func search(query: String) async throws -> [StockSearchHit]
}
```

```swift
// Backends/YahooFinance/YahooFinanceStockSearchClient.swift
import Foundation

struct YahooFinanceStockSearchClient: StockSearchClient {
  private let session: URLSession
  private static let baseURL = URL(
    string: "https://query1.finance.yahoo.com/v1/finance/search")!

  init(session: URLSession = .shared) {
    self.session = session
  }

  func search(query: String) async throws -> [StockSearchHit] {
    var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "quotesCount", value: "20"),
      URLQueryItem(name: "newsCount", value: "0"),
    ]
    guard let url = components?.url else { throw URLError(.badURL) }
    var request = URLRequest(url: url)
    request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    let decoded = try JSONDecoder().decode(Wire.self, from: data)
    return decoded.quotes.compactMap { wire in
      guard let quoteType = QuoteType(rawValue: wire.quoteType) else { return nil }
      let displayName =
        (wire.shortname?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
          ?? wire.longname?.trimmingCharacters(in: .whitespacesAndNewlines))
          ?? wire.symbol
      return StockSearchHit(
        symbol: wire.symbol,
        name: displayName,
        exchange: wire.exchange,
        quoteType: quoteType
      )
    }
  }
}

private struct Wire: Decodable {
  let quotes: [WireQuote]
}

private struct WireQuote: Decodable {
  let symbol: String
  let shortname: String?
  let longname: String?
  let exchange: String
  let quoteType: String
}

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}
```

- [ ] **Step 5: Run tests + format + commit**

```bash
just test YahooFinanceStockSearchClientTests 2>&1 | tee .agent-tmp/task7.txt
just format
git add Domain/Repositories/StockSearchClient.swift Backends/YahooFinance/YahooFinanceStockSearchClient.swift MoolahTests/Backends/YahooFinanceStockSearchClientTests.swift MoolahTests/Support/Fixtures/yahoo-finance-search-apple.json project.yml
git commit -m "feat(stock): Yahoo Finance name-search via /v1/finance/search"
rm .agent-tmp/task7.txt
```

Expected: 3 tests pass.

---

## Task 7 — `InstrumentSearchService`: catalog + stock search, drop `providerSources`

**Files:**
- Modify: `Shared/InstrumentSearchService.swift`
- Modify: `Shared/InstrumentSearchResult.swift` (only if `requiresResolution`-related fields need a docstring update)
- Create / modify: `MoolahTests/Shared/InstrumentSearchServiceTests.swift`

The new init shape:

```swift
init(
  registry: any InstrumentRegistryRepository,
  catalog: (any CoinGeckoCatalog)?,
  resolutionClient: any TokenResolutionClient,
  stockSearchClient: any StockSearchClient,
  stockValidator: any StockTickerValidator
)
```

`CryptoSearchClient` and `ProviderSources` are removed.

- [ ] **Step 1: Write failing tests**

```swift
// MoolahTests/Shared/InstrumentSearchServiceTests.swift
import XCTest
@testable import Moolah

final class InstrumentSearchServiceTests: XCTestCase {
  func testFiatPrefixHitsAreReturned() async {
    let service = makeService()
    let results = await service.search(query: "USD", kinds: [.fiatCurrency])
    XCTAssertTrue(results.contains { $0.instrument.id == "USD" && $0.isRegistered })
  }

  func testCryptoResultsCarryCatalogPlatform() async {
    let catalog = StubCatalog(entries: [
      CatalogEntry(
        coingeckoId: "uniswap", symbol: "UNI", name: "Uniswap",
        platforms: [PlatformBinding(slug: "ethereum", chainId: 1, contractAddress: "0xUNI")]
      )
    ])
    let service = makeService(catalog: catalog)
    let results = await service.search(query: "uni", kinds: [.cryptoToken])
    let uni = try XCTUnwrap(results.first)
    XCTAssertEqual(uni.instrument.id, "1:0xuni")
    XCTAssertTrue(uni.requiresResolution)
    XCTAssertNil(uni.cryptoMapping)
  }

  func testStockResultsAreLoadedFromSearchClient() async throws {
    let client = StubStockSearchClient(hits: [
      StockSearchHit(symbol: "AAPL", name: "Apple Inc.", exchange: "NMS", quoteType: .equity)
    ])
    let service = makeService(stockSearchClient: client)
    let results = await service.search(query: "apple", kinds: [.stock])
    let aapl = try XCTUnwrap(results.first)
    XCTAssertEqual(aapl.instrument.id, "NMS:AAPL")
    XCTAssertFalse(aapl.requiresResolution)
  }

  func testRegisteredCryptoOverridesCatalogResult() async throws {
    let registry = StubRegistry(
      stored: [Instrument.crypto(chainId: 1, contractAddress: "0xuni",
        symbol: "UNI", name: "Uniswap", decimals: 18)],
      mappings: [CryptoProviderMapping(
        instrumentId: "1:0xuni", coingeckoId: "uniswap",
        cryptocompareSymbol: nil, binanceSymbol: nil)]
    )
    let catalog = StubCatalog(entries: [
      CatalogEntry(
        coingeckoId: "uniswap", symbol: "UNI", name: "Uniswap",
        platforms: [PlatformBinding(slug: "ethereum", chainId: 1, contractAddress: "0xuni")])
    ])
    let service = makeService(registry: registry, catalog: catalog)
    let results = await service.search(query: "uni", kinds: [.cryptoToken])
    let uni = try XCTUnwrap(results.first)
    XCTAssertTrue(uni.isRegistered)
    XCTAssertFalse(uni.requiresResolution)
    XCTAssertEqual(uni.cryptoMapping?.coingeckoId, "uniswap")
  }
}

// Test seams (place in same file or `MoolahTests/Support/`).

private func makeService(
  registry: any InstrumentRegistryRepository = StubRegistry(),
  catalog: (any CoinGeckoCatalog)? = StubCatalog(entries: []),
  stockSearchClient: any StockSearchClient = StubStockSearchClient(hits: []),
  resolutionClient: any TokenResolutionClient = NoOpTokenResolutionClient(),
  stockValidator: any StockTickerValidator = StubStockValidator()
) -> InstrumentSearchService {
  InstrumentSearchService(
    registry: registry, catalog: catalog, resolutionClient: resolutionClient,
    stockSearchClient: stockSearchClient, stockValidator: stockValidator)
}

private struct StubCatalog: CoinGeckoCatalog {
  let entries: [CatalogEntry]
  func search(query: String, limit: Int) async -> [CatalogEntry] {
    entries.filter {
      $0.symbol.localizedCaseInsensitiveContains(query)
        || $0.name.localizedCaseInsensitiveContains(query)
    }
    .prefix(limit).map { $0 }
  }
  func refreshIfStale() async {}
}

private struct StubStockSearchClient: StockSearchClient {
  let hits: [StockSearchHit]
  func search(query: String) async throws -> [StockSearchHit] { hits }
}

private final class StubRegistry: InstrumentRegistryRepository, @unchecked Sendable {
  private var stored: [Instrument]
  private var mappings: [CryptoProviderMapping]
  init(stored: [Instrument] = [], mappings: [CryptoProviderMapping] = []) {
    self.stored = stored
    self.mappings = mappings
  }
  func all() async throws -> [Instrument] { stored }
  func allCryptoRegistrations() async throws -> [CryptoRegistration] {
    mappings.compactMap { mapping in
      guard let inst = stored.first(where: { $0.id == mapping.instrumentId }) else { return nil }
      return CryptoRegistration(instrument: inst, mapping: mapping)
    }
  }
  func registerCrypto(_ instrument: Instrument, mapping: CryptoProviderMapping) async throws {
    stored.removeAll { $0.id == instrument.id }
    stored.append(instrument)
    mappings.removeAll { $0.instrumentId == instrument.id }
    mappings.append(mapping)
  }
  func registerStock(_ instrument: Instrument) async throws {
    stored.removeAll { $0.id == instrument.id }
    stored.append(instrument)
  }
  func remove(id: String) async throws {
    stored.removeAll { $0.id == id }
    mappings.removeAll { $0.instrumentId == id }
  }
  @MainActor
  func observeChanges() -> AsyncStream<Void> { AsyncStream { _ in } }
}

private struct StubStockValidator: StockTickerValidator {
  func validate(query: String) async throws -> ValidatedStockTicker? { nil }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test InstrumentSearchServiceTests 2>&1 | tee .agent-tmp/task8.txt
```

Expected: FAIL — `extra argument 'catalog' in call` and similar.

- [ ] **Step 3: Implement**

Replace the body of `InstrumentSearchService.swift` (the design's mapping logic translates almost line-for-line; key sections shown below — preserve any existing fiat helper):

```swift
struct InstrumentSearchService: Sendable {
  private let registry: any InstrumentRegistryRepository
  private let catalog: (any CoinGeckoCatalog)?
  private let resolutionClient: any TokenResolutionClient
  private let stockSearchClient: any StockSearchClient
  private let stockValidator: any StockTickerValidator

  init(
    registry: any InstrumentRegistryRepository,
    catalog: (any CoinGeckoCatalog)?,
    resolutionClient: any TokenResolutionClient,
    stockSearchClient: any StockSearchClient,
    stockValidator: any StockTickerValidator
  ) {
    self.registry = registry
    self.catalog = catalog
    self.resolutionClient = resolutionClient
    self.stockSearchClient = stockSearchClient
    self.stockValidator = stockValidator
  }

  func search(
    query: String,
    kinds: Set<Instrument.Kind> = Set(Instrument.Kind.allCases)
  ) async -> [InstrumentSearchResult] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let registered = (try? await registry.all()) ?? []
    let cryptoMappings = (try? await registry.allCryptoRegistrations()) ?? []
    var results: [InstrumentSearchResult] = []

    if kinds.contains(.fiatCurrency) {
      results.append(contentsOf: searchFiat(query: trimmed, registered: registered))
    }
    if kinds.contains(.stock) {
      results.append(
        contentsOf: await searchStock(query: trimmed, registered: registered))
    }
    if kinds.contains(.cryptoToken) {
      results.append(
        contentsOf: await searchCrypto(
          query: trimmed, registered: registered, mappings: cryptoMappings))
    }
    return results
  }

  // ... `searchFiat` (existing) ...

  private func searchStock(
    query: String, registered: [Instrument]
  ) async -> [InstrumentSearchResult] {
    guard !query.isEmpty else { return [] }
    do {
      let hits = try await stockSearchClient.search(query: query)
      return hits.map { hit in
        let instrument = Instrument.stock(
          exchange: hit.exchange, ticker: hit.symbol, name: hit.name)
        let registeredHit = registered.contains { $0.id == instrument.id }
        return InstrumentSearchResult(
          instrument: instrument,
          cryptoMapping: nil,
          isRegistered: registeredHit,
          requiresResolution: !registeredHit
        )
      }
    } catch {
      return []
    }
  }

  private func searchCrypto(
    query: String,
    registered: [Instrument],
    mappings: [CryptoRegistration]
  ) async -> [InstrumentSearchResult] {
    guard let catalog else { return [] }
    let entries = await catalog.search(query: query, limit: 20)
    return entries.map { entry in
      let instrument: Instrument
      let id: String
      if let platform = entry.preferredPlatform, let chainId = platform.chainId {
        id = "\(chainId):\(platform.contractAddress)"
        instrument = Instrument.crypto(
          chainId: chainId,
          contractAddress: platform.contractAddress,
          symbol: entry.symbol,
          name: entry.name,
          decimals: 18  // unknown until resolve(); 18 is the EVM default and is overwritten on register
        )
      } else {
        id = "native:\(entry.symbol)"
        instrument = Instrument.crypto(
          chainId: 0,
          contractAddress: entry.symbol.lowercased(),
          symbol: entry.symbol,
          name: entry.name,
          decimals: 8
        )
      }
      let registration = mappings.first { $0.instrument.id == id }
      let isRegistered = registration != nil
      return InstrumentSearchResult(
        instrument: registration?.instrument ?? instrument,
        cryptoMapping: registration?.mapping,
        isRegistered: isRegistered,
        requiresResolution: !isRegistered
      )
    }
  }
}
```

The `Instrument.stock(exchange:ticker:name:)` and `Instrument.crypto(chainId:contractAddress:symbol:name:decimals:)` factories are existing — verify their argument labels match the project's current shape and adjust if needed (the factories shipped with the registry-backend work).

- [ ] **Step 4: Run tests + format**

```bash
just test InstrumentSearchServiceTests 2>&1 | tee .agent-tmp/task8.txt
just format
```

Expected: 4 tests pass. Existing call sites that passed `providerSources:` will now fail to compile — the only such call site is in `InstrumentPickerStore` (Task 9). If a temporary blocker appears, drop the `providerSources:` argument at the call site for now; Task 9 finalises that file.

- [ ] **Step 5: Commit**

```bash
git add Shared/InstrumentSearchService.swift Shared/InstrumentPickerStore.swift MoolahTests/Shared/InstrumentSearchServiceTests.swift App/ProfileSession+Factories.swift project.yml
git commit -m "feat(search): InstrumentSearchService uses catalog + stock search"
rm .agent-tmp/task8.txt
```

---

## Task 9 — `InstrumentPickerStore`: register crypto on `select(_:)`, drop `.stocksOnly`

**Files:**
- Modify: `Shared/InstrumentPickerStore.swift`
- Modify / create: `MoolahTests/Shared/InstrumentPickerStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Shared/InstrumentPickerStoreTests.swift
import XCTest
@testable import Moolah

@MainActor
final class InstrumentPickerStoreTests: XCTestCase {
  func testSelectingUnregisteredCryptoRunsResolveAndRegisters() async throws {
    let registry = StubRegistry()
    let resolver = StubResolutionClient(result: TokenResolutionResult(
      coingeckoId: "uniswap",
      cryptocompareSymbol: "UNI",
      binanceSymbol: "UNIUSDT",
      resolvedName: "Uniswap",
      resolvedSymbol: "UNI",
      resolvedDecimals: 18
    ))
    let result = InstrumentSearchResult(
      instrument: Instrument.crypto(
        chainId: 1, contractAddress: "0xuni", symbol: "UNI", name: "Uniswap", decimals: 18),
      cryptoMapping: nil,
      isRegistered: false,
      requiresResolution: true
    )
    let store = InstrumentPickerStore(
      searchService: nil, registry: registry, resolutionClient: resolver,
      kinds: [.cryptoToken])
    let selected = await store.select(result)
    XCTAssertNotNil(selected)
    let stored = try await registry.allCryptoRegistrations()
    XCTAssertEqual(stored.first?.mapping.coingeckoId, "uniswap")
  }

  func testSelectingUnregisteredCryptoWithoutAnyMappingFailsAndDoesNotWrite() async throws {
    let registry = StubRegistry()
    let resolver = StubResolutionClient(result: TokenResolutionResult(
      coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil,
      resolvedName: nil, resolvedSymbol: nil, resolvedDecimals: nil))
    let result = InstrumentSearchResult(
      instrument: Instrument.crypto(
        chainId: 1, contractAddress: "0xfoo", symbol: "FOO", name: "Foo", decimals: 18),
      cryptoMapping: nil,
      isRegistered: false,
      requiresResolution: true
    )
    let store = InstrumentPickerStore(
      searchService: nil, registry: registry, resolutionClient: resolver,
      kinds: [.cryptoToken])
    let selected = await store.select(result)
    XCTAssertNil(selected)
    XCTAssertNotNil(store.error)
    let stored = try await registry.allCryptoRegistrations()
    XCTAssertTrue(stored.isEmpty)
  }

  func testSelectingRegisteredCryptoReturnsImmediately() async throws {
    let registered = Instrument.crypto(
      chainId: 1, contractAddress: "0xuni", symbol: "UNI", name: "Uniswap", decimals: 18)
    let registry = StubRegistry(stored: [registered],
      mappings: [CryptoProviderMapping(
        instrumentId: registered.id, coingeckoId: "uniswap",
        cryptocompareSymbol: nil, binanceSymbol: nil)])
    let resolver = StubResolutionClient(result: TokenResolutionResult(
      coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil,
      resolvedName: nil, resolvedSymbol: nil, resolvedDecimals: nil))
    let result = InstrumentSearchResult(
      instrument: registered,
      cryptoMapping: CryptoProviderMapping(
        instrumentId: registered.id, coingeckoId: "uniswap",
        cryptocompareSymbol: nil, binanceSymbol: nil),
      isRegistered: true,
      requiresResolution: false
    )
    let store = InstrumentPickerStore(
      searchService: nil, registry: registry, resolutionClient: resolver,
      kinds: [.cryptoToken])
    let selected = await store.select(result)
    XCTAssertEqual(selected?.id, registered.id)
    XCTAssertEqual(resolver.callCount, 0)
  }
}

// Stubs
private final class StubResolutionClient: TokenResolutionClient, @unchecked Sendable {
  let result: TokenResolutionResult
  private(set) var callCount = 0
  init(result: TokenResolutionResult) { self.result = result }
  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    callCount += 1
    return result
  }
}
```

`StubRegistry` is the one defined in Task 7's tests; lift it into `MoolahTests/Support/Stubs/StubRegistry.swift` so Task 9 can reuse it without duplicating the implementation.

- [ ] **Step 2: Run test to verify it fails**

```bash
just test InstrumentPickerStoreTests 2>&1 | tee .agent-tmp/task9.txt
```

Expected: FAIL — `select(_:)` currently bails on crypto.

- [ ] **Step 3: Implement**

Modify `Shared/InstrumentPickerStore.swift`:

1. Drop the `providerSources` parameter from the store (and from internal calls into the service).
2. Add `private let resolutionClient: any TokenResolutionClient` to the init and store it.
3. Replace `select(_:)`:

```swift
func select(_ result: InstrumentSearchResult) async -> Instrument? {
  if result.isRegistered {
    return result.instrument
  }
  switch result.instrument.kind {
  case .fiatCurrency:
    return result.instrument
  case .stock:
    do {
      try await registry?.registerStock(result.instrument)
      return result.instrument
    } catch {
      self.error = error.localizedDescription
      return nil
    }
  case .cryptoToken:
    return await registerCrypto(result)
  }
}

private func registerCrypto(_ result: InstrumentSearchResult) async -> Instrument? {
  guard let registry else { return nil }
  isResolving = true
  error = nil
  defer { isResolving = false }
  let instrument = result.instrument
  let isNative = instrument.chainId == 0  // see InstrumentSearchService.searchCrypto
  do {
    let resolution = try await resolutionClient.resolve(
      chainId: instrument.chainId,
      contractAddress: isNative ? nil : instrument.contractAddress,
      symbol: instrument.symbol,
      isNative: isNative
    )
    guard
      resolution.coingeckoId != nil
      || resolution.cryptocompareSymbol != nil
      || resolution.binanceSymbol != nil
    else {
      self.error = "Could not find a price source for this token."
      return nil
    }
    let mapping = CryptoProviderMapping(
      instrumentId: instrument.id,
      coingeckoId: resolution.coingeckoId,
      cryptocompareSymbol: resolution.cryptocompareSymbol,
      binanceSymbol: resolution.binanceSymbol
    )
    try await registry.registerCrypto(instrument, mapping: mapping)
    return instrument
  } catch {
    self.error = error.localizedDescription
    return nil
  }
}
```

Add `var isResolving: Bool = false` to the published state if it does not already exist.

- [ ] **Step 4: Run tests + format**

```bash
just test InstrumentPickerStoreTests 2>&1 | tee .agent-tmp/task9.txt
just format
```

Expected: 3 tests pass. Verify the existing `InstrumentPickerSheet` continues to compile — the `select(_:)` signature is unchanged; only the body grew.

- [ ] **Step 5: Commit**

```bash
git add Shared/InstrumentPickerStore.swift MoolahTests/Shared/InstrumentPickerStoreTests.swift project.yml
git commit -m "feat(picker): register crypto via resolve() on select"
rm .agent-tmp/task9.txt
```

---

## Task 10 — `AddTokenSheet` rewrite + `CryptoTokenStore` trim

**Files:**
- Modify: `Features/Settings/AddTokenSheet.swift`
- Modify: `Features/Settings/CryptoTokenStore.swift`
- Modify: `Features/Settings/CryptoSettingsView.swift` (only if it references the removed methods)
- Modify / create: `MoolahTests/Features/CryptoTokenStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Features/CryptoTokenStoreTests.swift
import XCTest
@testable import Moolah

@MainActor
final class CryptoTokenStoreTests: XCTestCase {
  func testInitializerAcceptsTrimmedDependencies() {
    let registry = StubRegistry()
    let priceService = MockCryptoPriceService()
    let store = CryptoTokenStore(registry: registry, cryptoPriceService: priceService)
    XCTAssertFalse(store.isLoading)
    XCTAssertNil(store.error)
  }

  func testRemoveRegistrationDelegatesToRegistry() async throws {
    let registered = Instrument.crypto(
      chainId: 1, contractAddress: "0xuni", symbol: "UNI", name: "Uniswap", decimals: 18)
    let registry = StubRegistry(
      stored: [registered],
      mappings: [CryptoProviderMapping(
        instrumentId: registered.id, coingeckoId: "uniswap",
        cryptocompareSymbol: nil, binanceSymbol: nil)])
    let priceService = MockCryptoPriceService()
    let store = CryptoTokenStore(registry: registry, cryptoPriceService: priceService)
    await store.loadRegistrations()
    let registration = try XCTUnwrap(store.registrations.first)
    await store.removeRegistration(registration)
    XCTAssertTrue(store.registrations.isEmpty)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test CryptoTokenStoreTests 2>&1 | tee .agent-tmp/task10.txt
```

Expected: FAIL — likely a compile error on still-present `resolveToken`/`confirmRegistration` after the trim, or the trim hasn't happened yet.

- [ ] **Step 3: Trim `CryptoTokenStore`**

Remove these members from `Features/Settings/CryptoTokenStore.swift`:
- `var resolvedRegistration: CryptoRegistration?`
- `var isResolving: Bool`
- `func resolveToken(chainId:contractAddress:symbol:isNative:) async`
- `func confirmRegistration() async`

Keep:
- `loadRegistrations`, `removeRegistration`, `removeInstrument`, `registrations`, `instruments`, `providerMappings`, `isLoading`, `error`, the API-key methods.

- [ ] **Step 4: Rewrite `AddTokenSheet.swift`**

Replace its body with:

```swift
import SwiftUI

struct AddTokenSheet: View {
  @Environment(\.dismiss) private var dismiss
  let onRegistered: () -> Void

  var body: some View {
    InstrumentPickerSheet(kinds: [.cryptoToken]) { instrument in
      if instrument != nil { onRegistered() }
      dismiss()
    }
  }
}
```

`InstrumentPickerSheet` is the existing sheet wrapper. If its signature does not currently expose a callback variant, add one in this task: an initialiser overload that takes `kinds:` and a `(Instrument?) -> Void` completion. The existing initialiser stays.

In `CryptoSettingsView.swift`, change the "Add Token" action's destination to `AddTokenSheet { Task { await store.loadRegistrations() } }` (or equivalent).

- [ ] **Step 5: Run tests + format + commit**

```bash
just test CryptoTokenStoreTests 2>&1 | tee .agent-tmp/task10.txt
just test SettingsViewTests 2>&1 | tee -a .agent-tmp/task10.txt
just format
git add Features/Settings/AddTokenSheet.swift Features/Settings/CryptoTokenStore.swift Features/Settings/CryptoSettingsView.swift MoolahTests/Features/CryptoTokenStoreTests.swift Shared/Views/InstrumentPickerSheet.swift project.yml
git commit -m "feat(settings): search-only Add Token flow"
rm .agent-tmp/task10.txt
```

Expected: 2 new tests pass; existing settings tests unaffected.

---

## Task 11 — `CloudKitInstrumentRegistryRepository.notifyExternalChange()`

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitInstrumentRegistryRepository.swift`
- Modify / create: `MoolahTests/Backends/CloudKit/CloudKitInstrumentRegistryRepositoryTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Backends/CloudKit/CloudKitInstrumentRegistryRepositoryTests.swift
import XCTest
import SwiftData
@testable import Moolah

@MainActor
final class CloudKitInstrumentRegistryRepositoryNotifyTests: XCTestCase {
  func testNotifyExternalChangeYieldsToActiveSubscribers() async throws {
    let container = try ModelContainer(
      for: InstrumentRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let registry = CloudKitInstrumentRegistryRepository(modelContainer: container)
    let stream = registry.observeChanges()
    Task {
      try? await Task.sleep(nanoseconds: 50_000_000)
      registry.notifyExternalChange()
    }
    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()
    XCTAssertNotNil(first)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test CloudKitInstrumentRegistryRepositoryNotifyTests 2>&1 | tee .agent-tmp/task11.txt
```

Expected: FAIL — `cannot find 'notifyExternalChange'`.

- [ ] **Step 3: Implement**

Add to `CloudKitInstrumentRegistryRepository`:

```swift
@MainActor
func notifyExternalChange() {
  for continuation in subscribers.values {
    continuation.yield()
  }
}
```

Verify the `subscribers` dictionary is at MainActor scope (it is, per the existing implementation).

- [ ] **Step 4: Run tests + format**

```bash
just test CloudKitInstrumentRegistryRepositoryNotifyTests 2>&1 | tee .agent-tmp/task11.txt
just format
```

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitInstrumentRegistryRepository.swift MoolahTests/Backends/CloudKit/CloudKitInstrumentRegistryRepositoryTests.swift project.yml
git commit -m "feat(registry): notifyExternalChange() for sync fan-out"
rm .agent-tmp/task11.txt
```

---

## Task 12 — Sync change-fan-out: `ProfileDataSyncHandler` + closure wiring

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift` (init signature)
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler+BatchUpsert.swift` (track instrument-touched flag, fire after commit)
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler+QueueAndDelete.swift` (same on the deletion path)
- Modify: `App/ProfileSession+Factories.swift` (pass closure when constructing handler)
- Create: `MoolahTests/Backends/CloudKit/Sync/ProfileDataSyncHandlerInstrumentChangeTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Backends/CloudKit/Sync/ProfileDataSyncHandlerInstrumentChangeTests.swift
import XCTest
import SwiftData
import CloudKit
@testable import Moolah

@MainActor
final class ProfileDataSyncHandlerInstrumentChangeTests: XCTestCase {
  func testRemoteUpsertOfInstrumentTriggersChangeClosureOnce() async throws {
    let context = try TestSyncContext.makeInMemory()
    var fired = 0
    let handler = ProfileDataSyncHandler(
      modelContext: context.context,
      systemFieldsStore: context.systemFieldsStore,
      onInstrumentRemoteChange: { fired += 1 }
    )
    let record = CKRecord(recordType: "Instrument", recordID: CKRecord.ID(recordName: "1:0xuni"))
    record["coingeckoId"] = "uniswap"
    record["symbol"] = "UNI"
    record["name"] = "Uniswap"
    record["decimals"] = 18
    record["chainId"] = 1
    record["contractAddress"] = "0xuni"
    record["kind"] = "cryptoToken"
    try await handler.batchUpsertInstruments([record])
    XCTAssertEqual(fired, 1)
  }

  func testRemoteUpsertOfNonInstrumentDoesNotTriggerClosure() async throws {
    let context = try TestSyncContext.makeInMemory()
    var fired = 0
    let handler = ProfileDataSyncHandler(
      modelContext: context.context,
      systemFieldsStore: context.systemFieldsStore,
      onInstrumentRemoteChange: { fired += 1 }
    )
    let record = CKRecord(recordType: "Account", recordID: CKRecord.ID(recordName: "acc-1"))
    record["name"] = "Savings"
    record["instrumentId"] = "USD"
    try await handler.batchUpsertAccounts([record])
    XCTAssertEqual(fired, 0)
  }

  func testRemoteDeletionOfInstrumentTriggersClosure() async throws {
    let context = try TestSyncContext.makeInMemory()
    var fired = 0
    let handler = ProfileDataSyncHandler(
      modelContext: context.context,
      systemFieldsStore: context.systemFieldsStore,
      onInstrumentRemoteChange: { fired += 1 }
    )
    try await handler.applyRemoteDeletions([
      CKRecord.ID(recordName: "1:0xuni"): "Instrument"
    ])
    XCTAssertEqual(fired, 1)
  }
}
```

`TestSyncContext.makeInMemory()` is a small helper — add it to `MoolahTests/Support/TestSyncContext.swift` if it doesn't exist; it builds a SwiftData `ModelContainer(isStoredInMemoryOnly: true)` and an in-memory `SystemFieldsStore`.

- [ ] **Step 2: Run test to verify it fails**

```bash
just test ProfileDataSyncHandlerInstrumentChangeTests 2>&1 | tee .agent-tmp/task12.txt
```

Expected: FAIL — `extra argument 'onInstrumentRemoteChange'`.

- [ ] **Step 3: Implement**

In `ProfileDataSyncHandler.swift`, extend the initialiser:

```swift
init(
  modelContext: ModelContext,
  systemFieldsStore: SystemFieldsStore,
  onInstrumentRemoteChange: @Sendable @escaping () -> Void = { }
) {
  self.modelContext = modelContext
  self.systemFieldsStore = systemFieldsStore
  self.onInstrumentRemoteChange = onInstrumentRemoteChange
}

private let onInstrumentRemoteChange: @Sendable () -> Void
```

In `ProfileDataSyncHandler+BatchUpsert.swift` (`batchUpsertInstruments`):

```swift
func batchUpsertInstruments(_ records: [CKRecord]) async throws {
  guard !records.isEmpty else { return }
  var anyTouched = false
  // ... existing per-record upsert loop ...
  // Inside the loop, set anyTouched = true whenever the row is inserted,
  // updated, or has any of {coingeckoId, cryptocompareSymbol, binanceSymbol}
  // change between old and new. Existing code already loads the record before
  // updating; compare the relevant fields there.
  try modelContext.save()
  if anyTouched { onInstrumentRemoteChange() }
}
```

In `ProfileDataSyncHandler+QueueAndDelete.swift` (`applyRemoteDeletions` — actual method name may differ; use the one called on delete paths):

```swift
func applyRemoteDeletions(_ deletions: [CKRecord.ID: String]) async throws {
  // ... existing loop ...
  let deletedAnyInstrument = deletions.values.contains("Instrument")
  // ... save context ...
  if deletedAnyInstrument { onInstrumentRemoteChange() }
}
```

In `App/ProfileSession+Factories.swift`, when constructing the handler that drives sync (look in `makeBackend` or `makeSyncCoordinator`):

```swift
let handler = ProfileDataSyncHandler(
  modelContext: context,
  systemFieldsStore: systemFieldsStore,
  onInstrumentRemoteChange: { [weak registry] in
    Task { @MainActor in registry?.notifyExternalChange() }
  }
)
```

`registry` here is the concrete `CloudKitInstrumentRegistryRepository`. If the factory currently exposes only the protocol-typed `instrumentRegistry`, capture the concrete instance separately at construction time.

- [ ] **Step 4: Run tests + format**

```bash
just test ProfileDataSyncHandlerInstrumentChangeTests 2>&1 | tee .agent-tmp/task12.txt
just format
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileDataSyncHandler.swift Backends/CloudKit/Sync/ProfileDataSyncHandler+BatchUpsert.swift Backends/CloudKit/Sync/ProfileDataSyncHandler+QueueAndDelete.swift App/ProfileSession+Factories.swift MoolahTests/Backends/CloudKit/Sync/ProfileDataSyncHandlerInstrumentChangeTests.swift MoolahTests/Support/TestSyncContext.swift project.yml
git commit -m "feat(sync): fan-out remote instrument changes to registry observers"
rm .agent-tmp/task12.txt
```

---

## Task 13 — `RepositoryError.unmappedCryptoInstrument` case

**Files:**
- Modify: `Domain/Repositories/RepositoryError.swift` (or wherever the project's repository-error enum lives — check via `grep -rn 'enum RepositoryError' Domain/ Backends/`)
- Create: `MoolahTests/Domain/RepositoryErrorTests.swift`

If no shared `RepositoryError` exists, the existing tightening will need its own dedicated error type — name it `UnmappedCryptoInstrumentError` and place it in `Domain/Errors/UnmappedCryptoInstrumentError.swift`.

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Domain/RepositoryErrorTests.swift
import XCTest
@testable import Moolah

final class RepositoryErrorTests: XCTestCase {
  func testUnmappedCryptoInstrumentEqualityByInstrumentId() {
    let a = RepositoryError.unmappedCryptoInstrument(instrumentId: "1:0xuni")
    let b = RepositoryError.unmappedCryptoInstrument(instrumentId: "1:0xuni")
    let c = RepositoryError.unmappedCryptoInstrument(instrumentId: "1:0xother")
    XCTAssertEqual(a, b)
    XCTAssertNotEqual(a, c)
  }

  func testUnmappedCryptoInstrumentLocalizedDescription() {
    let error = RepositoryError.unmappedCryptoInstrument(instrumentId: "1:0xuni")
    XCTAssertTrue(error.localizedDescription.contains("1:0xuni"))
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test RepositoryErrorTests 2>&1 | tee .agent-tmp/task13.txt
```

Expected: FAIL — case not present.

- [ ] **Step 3: Implement**

Add the case to the existing `RepositoryError` enum (or create the new enum if absent):

```swift
case unmappedCryptoInstrument(instrumentId: String)
```

If `RepositoryError` already exists and has a `LocalizedError` extension, add a description for the new case:

```swift
case .unmappedCryptoInstrument(let id):
  return "Crypto instrument \(id) cannot be saved without a price-provider mapping."
```

- [ ] **Step 4: Run tests + format**

```bash
just test RepositoryErrorTests 2>&1 | tee .agent-tmp/task13.txt
just format
```

- [ ] **Step 5: Commit**

```bash
git add Domain/Repositories/RepositoryError.swift MoolahTests/Domain/RepositoryErrorTests.swift
git commit -m "feat(domain): RepositoryError.unmappedCryptoInstrument case"
rm .agent-tmp/task13.txt
```

---

## Task 14 — Tighten `ensureInstrument` in `CloudKitTransactionRepository`

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift:55`
- Create: `MoolahTests/Backends/CloudKit/CloudKitTransactionRepositoryEnsureInstrumentTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Backends/CloudKit/CloudKitTransactionRepositoryEnsureInstrumentTests.swift
import XCTest
import SwiftData
@testable import Moolah

@MainActor
final class CloudKitTransactionRepositoryEnsureInstrumentTests: XCTestCase {
  func testFiatInstrumentSucceeds() throws {
    let repo = makeRepo()
    XCTAssertNoThrow(
      try repo.ensureInstrumentForTesting(
        Instrument.fiatCurrency(code: "USD")))
  }

  func testMappedCryptoInstrumentSucceeds() throws {
    let repo = makeRepo()
    let inst = Instrument.crypto(
      chainId: 1, contractAddress: "0xuni", symbol: "UNI", name: "Uniswap", decimals: 18)
    try repo.seedRegisteredCryptoForTesting(
      instrument: inst,
      mapping: CryptoProviderMapping(
        instrumentId: inst.id, coingeckoId: "uniswap",
        cryptocompareSymbol: nil, binanceSymbol: nil))
    XCTAssertNoThrow(try repo.ensureInstrumentForTesting(inst))
  }

  func testUnmappedCryptoInstrumentThrows() throws {
    let repo = makeRepo()
    let inst = Instrument.crypto(
      chainId: 1, contractAddress: "0xfoo", symbol: "FOO", name: "Foo", decimals: 18)
    XCTAssertThrowsError(try repo.ensureInstrumentForTesting(inst)) { error in
      XCTAssertEqual(
        error as? RepositoryError,
        .unmappedCryptoInstrument(instrumentId: inst.id))
    }
  }

  private func makeRepo() -> CloudKitTransactionRepository { /* Test factory */ }
}
```

The `ensureInstrumentForTesting` and `seedRegisteredCryptoForTesting` are thin internal-visibility wrappers exposing the existing private helper for the test. `makeRepo()` constructs the repository against an in-memory `ModelContainer`.

- [ ] **Step 2: Run test to verify it fails**

```bash
just test CloudKitTransactionRepositoryEnsureInstrumentTests 2>&1 | tee .agent-tmp/task14.txt
```

Expected: FAIL on `testUnmappedCryptoInstrumentThrows` — current behaviour silently inserts.

- [ ] **Step 3: Implement**

In `CloudKitTransactionRepository.swift`, replace the existing `ensureInstrument(_:)`:

```swift
func ensureInstrument(_ instrument: Instrument) throws {
  switch instrument.kind {
  case .fiatCurrency:
    instrumentCache[instrument.id] = instrument
    return
  case .stock:
    // Stock path unchanged in this plan; see design §4.8.
    let iid = instrument.id
    let descriptor = FetchDescriptor<InstrumentRecord>(
      predicate: #Predicate { $0.id == iid })
    if try context.fetch(descriptor).isEmpty {
      context.insert(InstrumentRecord.from(instrument))
      onInstrumentChanged(instrument.id)
    }
    instrumentCache[instrument.id] = instrument
  case .cryptoToken:
    let iid = instrument.id
    let descriptor = FetchDescriptor<InstrumentRecord>(
      predicate: #Predicate { $0.id == iid })
    let existing = try context.fetch(descriptor).first
    let isMapped: Bool = {
      guard let existing else { return false }
      return existing.coingeckoId != nil
        || existing.cryptocompareSymbol != nil
        || existing.binanceSymbol != nil
    }()
    guard isMapped else {
      throw RepositoryError.unmappedCryptoInstrument(instrumentId: instrument.id)
    }
    instrumentCache[instrument.id] = instrument
  }
}
```

The exact field names on `InstrumentRecord` (`coingeckoId`, etc.) are confirmed by the registry-backend design (§1.1). If they differ, follow the existing record schema.

- [ ] **Step 4: Run tests + format**

```bash
just test CloudKitTransactionRepositoryEnsureInstrumentTests 2>&1 | tee .agent-tmp/task14.txt
just format
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift MoolahTests/Backends/CloudKit/CloudKitTransactionRepositoryEnsureInstrumentTests.swift project.yml
git commit -m "fix(repo): ensureInstrument throws on unmapped crypto"
rm .agent-tmp/task14.txt
```

---

## Task 15 — Tighten `ensureInstrument` in `CloudKitAccountRepository`

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift:188`
- Create: `MoolahTests/Backends/CloudKit/CloudKitAccountRepositoryEnsureInstrumentTests.swift`

Mirror Task 14 for the account repository: same three test cases, same implementation pattern. Keep the test file separate so it can land independently.

- [ ] **Step 1**: Write the test (same shape as Task 14, swap repository class).
- [ ] **Step 2**: Run, expect failure on the unmapped-crypto case.
- [ ] **Step 3**: Apply the same `ensureInstrument` body shown in Task 14.
- [ ] **Step 4**: Run tests + format.
- [ ] **Step 5**: Commit:

```bash
git add Backends/CloudKit/Repositories/CloudKitAccountRepository.swift MoolahTests/Backends/CloudKit/CloudKitAccountRepositoryEnsureInstrumentTests.swift project.yml
git commit -m "fix(repo): ensureInstrument throws on unmapped crypto (account repo)"
```

---

## Task 16 — XCUITest: register a crypto token from the picker

**Files:**
- Create: `MoolahUITests_macOS/InstrumentPickerCryptoSearchTests.swift`
- Modify: `UITestSupport/UITestSeeds.swift` (add a `cryptoCatalogPreloaded` seed that injects a deterministic mini catalog snapshot via the test bridge)
- Modify: `UITestSupport/InstrumentPickerScreen.swift` (extend driver as needed)

This is a single happy-path test: open Settings → Crypto → Add Token, search "uni", select Uniswap, confirm the registration appears.

- [ ] **Step 1: Write the test**

```swift
// MoolahUITests_macOS/InstrumentPickerCryptoSearchTests.swift
import XCTest

final class InstrumentPickerCryptoSearchTests: XCTestCase {
  func testRegisterCryptoTokenViaPickerSearch() throws {
    let app = XCUIApplication.launchedForTest(seed: "cryptoCatalogPreloaded")
    let settings = app.openSettings()
    let crypto = settings.openCryptoTab()
    let addToken = crypto.tapAddToken()
    addToken.searchField.type("uni")
    addToken.waitForResult(symbol: "UNI", name: "Uniswap")
    addToken.selectResult(symbol: "UNI")
    addToken.waitForDismiss()
    crypto.waitForRegistration(symbol: "UNI")
  }
}
```

`XCUIApplication.launchedForTest(seed:)`, `openSettings()`, `openCryptoTab()`, `tapAddToken()`, `searchField.type(_:)`, `waitForResult(symbol:name:)`, `selectResult(symbol:)`, `waitForDismiss()`, `waitForRegistration(symbol:)` are screen-driver methods on the existing UITestSupport helpers. Add any that don't yet exist; tests must NOT touch `XCUIElement` directly (per `guides/UI_TEST_GUIDE.md`).

- [ ] **Step 2: Define the deterministic seed**

In `UITestSupport/UITestSeeds.swift`, add a `cryptoCatalogPreloaded` case that the app's test bridge uses to:
- Skip the live `refreshIfStale()`.
- Replace the catalog with a fixed mini snapshot containing exactly one row (`uniswap, UNI, Uniswap, ethereum:0x1F9840…`).
- Pre-stub the resolution client to return `(coingeckoId: "uniswap", cryptocompareSymbol: "UNI", binanceSymbol: "UNIUSDT")` for that input.

The seed mechanism is the same one used elsewhere for deterministic UI tests (search `UITestSeeds.swift` for examples).

- [ ] **Step 3: Run the test**

```bash
just test InstrumentPickerCryptoSearchTests 2>&1 | tee .agent-tmp/task16.txt
```

Expected: PASS. If it fails, investigate via `.xcresult` artefacts as per `guides/UI_TEST_GUIDE.md`. Do not add `sleep` calls.

- [ ] **Step 4: Format + commit**

```bash
just format
git add MoolahUITests_macOS/InstrumentPickerCryptoSearchTests.swift UITestSupport/UITestSeeds.swift UITestSupport/InstrumentPickerScreen.swift project.yml
git commit -m "test(ui): register a crypto token via picker search"
rm .agent-tmp/task16.txt
```

---

## Self-review checklist (after final task)

After landing all 16 tasks, run the full test matrix to catch regressions:

```bash
just test 2>&1 | tee .agent-tmp/full-suite.txt
```

Open the spec ([§ design](./2026-04-27-instrument-registry-ui-design.md)) and check each section has a corresponding task:

| Spec section | Task |
|---|---|
| §3 D1 (search-only Add Token) | 10 |
| §3 D2 (cached `/coins/list`) | 3, 4, 5 |
| §3 D3 (SQLite + FTS5) | 2, 3, 4 |
| §3 D4 (no migration framework) | 3 |
| §3 D5 (`/asset_platforms` in same DB) | 2, 5 |
| §3 D6 (refresh policy + ETag + silent failure) | 5 |
| §3 D7 (`ensureInstrument` tightening) | 13, 14, 15 |
| §3 D8 (Yahoo stock search) | 6 |
| §3 D9 (sync change-fan-out) | 11, 12 |
| §3 D10 (drop `.stocksOnly`, register crypto in picker) | 7, 9 |
| §6 (SQLite schema) | 2 |
| §7 (refresh / ETag) | 5 |
| §9 (testing strategy) | covered per task |

If any decision lacks a task, add one before opening the PR.

Verification before claiming completion:
- `just test` passes locally; CI green on the PR.
- `just format-check` passes — no SwiftLint baseline mutations.
- A manual run of the picker on macOS surfaces fiat / stock / crypto results without bouncing to Settings → Crypto.
- Issue #461 is referenced from every PR description.

When all 16 tasks are merged, queue a final PR that:
1. Updates [`plans/2026-04-27-instrument-registry-ui-design.md`](2026-04-27-instrument-registry-ui-design.md) and this implementation plan with `Status: Completed`.
2. Moves both files to `plans/completed/`.
3. Closes #461.
