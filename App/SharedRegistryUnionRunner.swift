// App/SharedRegistryUnionRunner.swift

import Foundation
import GRDB
import OSLog

/// One-shot data-union migration that walks every per-profile
/// `data.sqlite` and merges its `instrument` + price-cache rows into
/// the shared `profile-index.sqlite` tables added by the v3 schema
/// migration. Gated by a `UserDefaults` flag — once set, the runner
/// is a no-op forever.
///
/// **Per-profile isolation.** Each profile is processed in a separate
/// shared-DB write transaction. A read failure on one profile (corrupt
/// file, locked WAL) logs and skips that profile; previously-merged
/// profiles stay merged. The flag is set after every profile has been
/// attempted, so a partial run is observable as "some profiles missing
/// from the shared registry" rather than as "migration retried forever".
///
/// **Merge rules.**
/// * `instrument` rows: delegate to
///   `GRDBInstrumentRegistryRepository.applyRemoteChangesSync`, which
///   already enforces the spam-wins merge via `PricingStatusMerge.merge`.
///   Per-profile sort order (ascending UUID) means later profiles see
///   their rows applied last.
/// * `crypto_price` / `stock_price` / `exchange_rate` body rows are
///   content-addressable (same `(key, date)` ⇒ same value across
///   profiles). `INSERT OR IGNORE` — first writer wins is fine.
/// * `crypto_token_meta` / `stock_ticker_meta` / `exchange_rate_meta`:
///   merge `(earliest_date, latest_date)` to the broadest span via
///   explicit `ON CONFLICT(pk) DO UPDATE`.
///
/// **Concurrency.** `nonisolated`. DB I/O happens on GRDB's serial
/// executor via `await database.write { … }`; the runner returns when
/// every profile has been attempted. The caller awaits the runner from
/// the app boot path before opening any session.
///
/// See `plans/2026-05-09-shared-instrument-registry-design.md` (Step
/// 2 of §Migration) and the implementation plan (Task 11).
enum SharedRegistryUnionRunner {
  /// `UserDefaults` key gating the union. Once `true`, the runner is
  /// a no-op forever.
  static let unionFlagKey =
    "com.moolah.migration.shared-registry-union.v1.completed"

  /// Runs the union once. Calls past the first run are no-ops.
  ///
  /// - Parameters:
  ///   - sharedQueue: The profile-index `DatabaseWriter` (e.g. a
  ///     migrated `DatabaseQueue` from `ProfileIndexDatabase.open`).
  ///   - profileIds: The ids of every profile whose per-profile DB
  ///     should be unioned. Sorted ascending by `uuidString` to
  ///     produce a deterministic merge order across re-runs.
  ///   - perProfileDatabase: Opens the per-profile DB at the supplied
  ///     id. Defaults to `ProfileSession.openProfileDatabase(profileId:)`.
  ///     Tests pass a stub.
  ///   - fileManager: Used to check that the per-profile DB file
  ///     exists before attempting an open (so a missing file silently
  ///     skips that profile rather than throwing).
  ///   - defaults: The `UserDefaults` instance to read / write the
  ///     gating flag.
  static func run(
    sharedQueue: any DatabaseWriter,
    profileIds: [UUID],
    perProfileDatabase: @Sendable (UUID) throws -> DatabaseQueue =
      ProfileSession.openProfileDatabase(profileId:),
    perProfileDatabaseURL: @Sendable (UUID) -> URL = { profileId in
      ProfileSession.profileDatabaseDirectory(for: profileId)
        .appendingPathComponent("data.sqlite")
    },
    fileManager: FileManager = .default,
    defaults: UserDefaults = .standard
  ) async {
    let logger = Logger(
      subsystem: "com.moolah.app", category: "SharedRegistryUnion")

    if defaults.bool(forKey: unionFlagKey) {
      logger.info("Shared-registry union already completed — skipping")
      return
    }

    // Spec §Migration step 2 line 257 — sort ascending by `profile.id`
    // (BLOB UUID; SQLite `ORDER BY id` byte-order). The deterministic
    // tie-breaker for conflicting non-null provider mappings depends on
    // this exact order, so use the raw 16-byte representation rather
    // than the canonical 36-char `uuidString` form (the two orderings
    // can disagree once a hex digit crosses a half-byte boundary).
    let sortedIds = profileIds.sorted { lhs, rhs in
      withUnsafeBytes(of: lhs.uuid) { lhsBytes in
        withUnsafeBytes(of: rhs.uuid) { rhsBytes in
          lhsBytes.lexicographicallyPrecedes(rhsBytes)
        }
      }
    }
    var successfulCount = 0
    var skippedCount = 0
    let registry = GRDBInstrumentRegistryRepository(database: sharedQueue)

    for profileId in sortedIds {
      let url = perProfileDatabaseURL(profileId)
      guard fileManager.fileExists(atPath: url.path) else {
        logger.warning(
          "Profile \(profileId, privacy: .public) has no data.sqlite — skipping"
        )
        skippedCount += 1
        continue
      }

      do {
        let snapshot = try await PerProfileSnapshot(
          profileId: profileId, queue: try perProfileDatabase(profileId))
        try await applySnapshot(
          snapshot, sharedQueue: sharedQueue, registry: registry)
        successfulCount += 1
      } catch {
        logger.error(
          "Profile \(profileId, privacy: .public) union failed (\(error, privacy: .public)) — skipping"
        )
        skippedCount += 1
      }
    }

    defaults.set(true, forKey: unionFlagKey)
    logger.info(
      """
      Shared-registry union complete \
      (successful=\(successfulCount), skipped=\(skippedCount))
      """)
  }

  // MARK: - Apply

  private static func applySnapshot(
    _ snapshot: PerProfileSnapshot,
    sharedQueue: any DatabaseWriter,
    registry: GRDBInstrumentRegistryRepository
  ) async throws {
    // Instruments use the existing apply path so the spam-wins merge
    // rule is shared, not duplicated. Each call opens its own write
    // transaction; that's acceptable here because the per-profile
    // batches are independent and a mid-batch failure is logged + the
    // outer loop moves on to the next profile.
    //
    // **`encoded_system_fields` carryover.** `snapshot.instruments`
    // includes whatever blob the per-profile row carries, copied
    // byte-for-byte (per spec §Migration step 2 line 263 — "copied
    // verbatim, never decoded"). Those blobs encode CKSyncEngine
    // metadata for the **per-profile** zone; replaying them onto a
    // shared-zone row means the first upload to the profile-index
    // zone may receive a `.serverRecordChanged` and self-recover via
    // `applyInstrumentServerRecordChangedMerge`. Acceptable per the
    // spec; the blob stays opaque and never gets decoded across the
    // zone boundary. NULL blobs (rows that were never
    // sync-roundtripped on this device) flow through unchanged and
    // produce a fresh CKRecord create on first upload — covered by
    // `SharedRegistryUnionRunnerTests.unionPreservesNullEncodedSystemFields`.
    try registry.applyRemoteChangesSync(
      saved: snapshot.instruments, deleted: [])

    // Price-cache rows / meta rows in a single write per profile.
    try await sharedQueue.write { database in
      try mergeBodyRows(snapshot: snapshot, database: database)
      try mergeMetaRows(snapshot: snapshot, database: database)
    }
  }

  /// Body tables are content-addressable: `(key, date)` deterministic
  /// ⇒ same value. `INSERT OR IGNORE` — first writer wins.
  private static func mergeBodyRows(
    snapshot: PerProfileSnapshot, database: Database
  ) throws {
    for row in snapshot.cryptoPrices {
      try database.execute(
        sql: """
          INSERT OR IGNORE INTO crypto_price (token_id, date, price_usd)
          VALUES (?, ?, ?)
          """,
        arguments: [row.tokenId, row.date, row.priceUsd])
    }
    for row in snapshot.stockPrices {
      try database.execute(
        sql: """
          INSERT OR IGNORE INTO stock_price (ticker, date, price)
          VALUES (?, ?, ?)
          """,
        arguments: [row.ticker, row.date, row.price])
    }
    for row in snapshot.exchangeRates {
      try database.execute(
        sql: """
          INSERT OR IGNORE INTO exchange_rate (base, quote, date, rate)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [row.base, row.quote, row.date, row.rate])
    }
  }

  /// Meta tables: merge the date span via `ON CONFLICT(pk) DO UPDATE`.
  /// Earliest-date is the `MIN`; latest-date is the `MAX`.
  private static func mergeMetaRows(
    snapshot: PerProfileSnapshot, database: Database
  ) throws {
    for row in snapshot.cryptoTokenMeta {
      try database.execute(
        sql: """
          INSERT INTO crypto_token_meta
          (token_id, symbol, earliest_date, latest_date)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(token_id) DO UPDATE SET
            earliest_date = MIN(earliest_date, excluded.earliest_date),
            latest_date = MAX(latest_date, excluded.latest_date)
          """,
        arguments: [row.tokenId, row.symbol, row.earliestDate, row.latestDate])
    }
    for row in snapshot.stockTickerMeta {
      try database.execute(
        sql: """
          INSERT INTO stock_ticker_meta
          (ticker, instrument_id, earliest_date, latest_date)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(ticker) DO UPDATE SET
            earliest_date = MIN(earliest_date, excluded.earliest_date),
            latest_date = MAX(latest_date, excluded.latest_date)
          """,
        arguments: [
          row.ticker, row.instrumentId, row.earliestDate, row.latestDate,
        ])
    }
    for row in snapshot.exchangeRateMeta {
      try database.execute(
        sql: """
          INSERT INTO exchange_rate_meta
          (base, earliest_date, latest_date)
          VALUES (?, ?, ?)
          ON CONFLICT(base) DO UPDATE SET
            earliest_date = MIN(earliest_date, excluded.earliest_date),
            latest_date = MAX(latest_date, excluded.latest_date)
          """,
        arguments: [row.base, row.earliestDate, row.latestDate])
    }
  }
}

/// Snapshot of one per-profile DB. `Database` handles never escape
/// the read closure; the snapshot is a `Sendable` value type.
struct PerProfileSnapshot: Sendable {
  let profileId: UUID
  let instruments: [InstrumentRow]
  let cryptoPrices: [CryptoPriceRecord]
  let stockPrices: [StockPriceRecord]
  let exchangeRates: [ExchangeRateRecord]
  let cryptoTokenMeta: [CryptoTokenMetaRecord]
  let stockTickerMeta: [StockTickerMetaRecord]
  let exchangeRateMeta: [ExchangeRateMetaRecord]

  /// Reads every relevant table from the per-profile queue into Swift
  /// value types so the snapshot can be passed to the shared-DB write
  /// transaction without a live `Database` handle escaping.
  init(profileId: UUID, queue: DatabaseQueue) async throws {
    self.profileId = profileId
    let snapshot = try await queue.read { database in
      try (
        InstrumentRow.fetchAll(database),
        CryptoPriceRecord.fetchAll(database),
        StockPriceRecord.fetchAll(database),
        ExchangeRateRecord.fetchAll(database),
        CryptoTokenMetaRecord.fetchAll(database),
        StockTickerMetaRecord.fetchAll(database),
        ExchangeRateMetaRecord.fetchAll(database)
      )
    }
    self.instruments = snapshot.0
    self.cryptoPrices = snapshot.1
    self.stockPrices = snapshot.2
    self.exchangeRates = snapshot.3
    self.cryptoTokenMeta = snapshot.4
    self.stockTickerMeta = snapshot.5
    self.exchangeRateMeta = snapshot.6
  }
}
