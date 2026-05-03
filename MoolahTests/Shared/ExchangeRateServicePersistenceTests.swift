// MoolahTests/Shared/ExchangeRateServicePersistenceTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Persistence tests live in their own suite so the main behavioural suite
/// (`ExchangeRateServiceTests`) stays under the `type_body_length` cap.
/// Covers the SQL save/load round-trip, the rollback contract for
/// `ExchangeRateService.persistDelta`, and the delta-write semantics that
/// keep chart renders off the GRDB serial queue.
@Suite("ExchangeRateService — Persistence")
struct ExchangeRateServicePersistenceTests {
  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  /// Two service instances sharing the same `DatabaseQueue` — the second
  /// must load rates persisted by the first without going to the network.
  /// Renamed from `gzipRoundTripPreservesData` after the migration from
  /// gzipped JSON cache files to GRDB.
  ///
  /// Rates are stored as `REAL` (`Double`) per the schema; the boundary
  /// conversion `Decimal → Double → Decimal` preserves source precision
  /// for values that have an exact binary representation but may add a
  /// trailing precision tail otherwise. The test asserts approximate
  /// equality (1e-9) rather than exact match — the FX path's user-facing
  /// precision (4 dp on Frankfurter) is far above this tolerance.
  @Test
  func sqlRoundTripPreservesData() async throws {
    let database = try ProfileDatabase.openInMemory()

    let client = FixedRateClient(rates: [
      "2026-04-11": ["USD": dec("0.632"), "EUR": dec("0.581")]
    ])
    let service = ExchangeRateService(client: client, database: database)

    // Fetch to populate cache and write to SQL
    let rate = try await service.rate(from: .AUD, to: .USD, on: try date("2026-04-11"))
    #expect(rate == dec("0.632"))

    // New service reading from the same database (fresh in-memory state)
    let failingClient = FixedRateClient(shouldFail: true)
    let service2 = ExchangeRateService(client: failingClient, database: database)

    // Should load from the SQL cache, not network
    let cachedRate = try await service2.rate(from: .AUD, to: .USD, on: try date("2026-04-11"))
    #expect(approximatelyEqual(cachedRate, dec("0.632")))

    let cachedEur = try await service2.rate(
      from: .AUD, to: Instrument.fiat(code: "EUR"), on: try date("2026-04-11"))
    #expect(approximatelyEqual(cachedEur, dec("0.581")))
  }

  private func approximatelyEqual(
    _ lhs: Decimal,
    _ rhs: Decimal,
    tolerance: Decimal = Decimal(string: "0.000000001") ?? Decimal(0)
  ) -> Bool {
    let delta = lhs - rhs
    let absDelta = delta < 0 ? -delta : delta
    return absDelta <= tolerance
  }

  /// Rollback contract: `ExchangeRateService.persistDelta` writes the
  /// delta rows (`INSERT OR REPLACE`) plus the meta row inside a single
  /// `database.write` transaction. If any statement throws, every
  /// statement in the same closure must roll back together so prior
  /// rows survive untouched.
  ///
  /// To drive the **production** save path (rather than asserting on a
  /// hand-rolled mirror of `persistDelta`'s shape), this test installs a
  /// SQLite `BEFORE INSERT` trigger that raises `ABORT` whenever a
  /// sentinel quote (`"___FAIL___"`) is inserted. A second fetch through
  /// the service yields a rate set containing that sentinel, which makes
  /// `persistDelta` throw mid-transaction. Prior rows must remain because
  /// SQLite rolls the transaction back atomically.
  @Test
  func saveCacheRollsBackOnInsertFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    // Pick a specific (date, quote, rate) triple we can re-look-up after
    // the failed save so the assertion proves the prior rows survived —
    // not just that the row count happens to match.
    let primingClient = FixedRateClient(rates: [
      "2026-04-07": ["USD": dec("1.234"), "EUR": dec("0.5900")]
    ])
    let service = ExchangeRateService(client: primingClient, database: database)
    _ = try await service.rate(from: .AUD, to: .USD, on: try date("2026-04-07"))
    _ = try await service.rate(
      from: .AUD, to: Instrument.fiat(code: "EUR"), on: try date("2026-04-07"))

    // Sanity: rows landed via the production save path.
    let beforeCount = try await database.read { database in
      try ExchangeRateRecord
        .filter(ExchangeRateRecord.Columns.base == "AUD")
        .fetchCount(database)
    }
    #expect(beforeCount >= 2)

    // Install a trigger that aborts any insert with the sentinel quote.
    // The trigger fires inside `persistDelta`'s transaction, so the
    // failed `INSERT OR REPLACE` of the sentinel row and the subsequent
    // meta `insert` must roll back together.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_save_cache
          BEFORE INSERT ON exchange_rate
          WHEN NEW.quote = '___FAIL___'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    // Drive the real `persistDelta` by feeding a new rate set whose
    // payload contains the sentinel quote. The trigger aborts the
    // `INSERT OR REPLACE` mid-transaction, so the whole disk write
    // (including the meta row) rolls back.
    //
    // The public `rate(...)` call may still return successfully because
    // `fetchToCoverDate` swallows the error and the in-memory cache holds
    // the merged value — `try?` reflects "we don't care about the return
    // value here; we only care about the rollback observed on disk".
    let failingClient = FixedRateClient(rates: [
      "2025-02-15": ["___FAIL___": dec("1.0")]
    ])
    let failingService = ExchangeRateService(client: failingClient, database: database)
    _ = try? await failingService.rate(
      from: .AUD, to: Instrument.fiat(code: "___FAIL___"), on: try date("2025-02-15"))

    // Prior state survived: row count matches AND the specific priming
    // row is still present with its original value. The exact-row probe
    // matters because `persistDelta` already uses upsert-only semantics
    // (no DELETE) — a row-count check on its own would pass even if the
    // rollback hadn't fired. Asking for the (AUD, USD, 2026-04-07) rate
    // by value proves the original insert survived the aborted
    // transaction.
    let afterCount = try await database.read { database in
      try ExchangeRateRecord
        .filter(ExchangeRateRecord.Columns.base == "AUD")
        .fetchCount(database)
    }
    #expect(afterCount == beforeCount)

    let surviving = try await database.read { database in
      try ExchangeRateRecord
        .filter(ExchangeRateRecord.Columns.base == "AUD")
        .filter(ExchangeRateRecord.Columns.quote == "USD")
        .filter(ExchangeRateRecord.Columns.date == "2026-04-07")
        .fetchOne(database)
    }
    #expect(surviving != nil)
    #expect(
      approximatelyEqual(
        Decimal(surviving?.rate ?? 0), dec("1.234"),
        tolerance: Decimal(string: "0.0001") ?? Decimal(0)))
  }

  /// `fetchAndMerge` must skip persistence when the network call
  /// returned no rates — there's nothing new to write. This is the
  /// second half of the chart-render bottleneck fix: even after `rate()`
  /// short-circuits in-range misses, out-of-range probes (Frankfurter
  /// not yet posted, a holiday at the cache boundary) still happen and
  /// must not touch the database when they bring back nothing.
  ///
  /// We detect the unwanted write by installing an `AFTER INSERT ON
  /// exchange_rate` counter trigger after priming. With the guard in
  /// place the counter stays at zero. Without the guard, the legacy
  /// `saveCache` rewrote every cached rate row on every fetch and the
  /// counter would increment by one per primed row. The current
  /// delta-based `persistDelta` would still increment the counter for
  /// the same scenario only if a non-empty fetch produced a non-empty
  /// delta — which is exactly what the sibling
  /// `saveCacheWritesOnlyChangedRows` test pins.
  @Test
  func emptyFetchResultDoesNotRewriteCache() async throws {
    let database = try ProfileDatabase.openInMemory()
    let client = FixedRateClient(rates: [
      "2025-01-17": ["USD": dec("0.6500")]
    ])
    let service = ExchangeRateService(client: client, database: database)

    // Prime cache with a single Friday rate.
    _ = try await service.rate(from: .AUD, to: .USD, on: try date("2025-01-17"))

    // Install a counter that fires on every insert into `exchange_rate`.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TABLE exchange_rate_write_counter (n INTEGER NOT NULL);
          INSERT INTO exchange_rate_write_counter (n) VALUES (0);
          CREATE TRIGGER count_exchange_rate_writes
          AFTER INSERT ON exchange_rate
          BEGIN
              UPDATE exchange_rate_write_counter SET n = n + 1;
          END;
          """)
    }

    // Forward extension fetch into a date the client cannot satisfy. The
    // client returns `[:]` for `[2025-01-18, 2025-01-25]`; merge() is a
    // no-op; saveCache must be skipped. The lookup itself should still
    // resolve via `fallbackRate` to Friday's 0.6500.
    let rate = try await service.rate(from: .AUD, to: .USD, on: try date("2025-01-25"))
    #expect(rate == dec("0.6500"))

    let writes = try await database.read { database in
      try Int.fetchOne(database, sql: "SELECT n FROM exchange_rate_write_counter") ?? -1
    }
    #expect(writes == 0)
  }

  /// `saveCache` must persist only the rows that the latest fetch added
  /// or changed — not the entire cache. Before this contract was added
  /// the implementation deleted every cached row for the base and
  /// re-inserted them one by one on every save, so a chart with N cached
  /// rates paid O(N) inserts per single-day extension. The user-visible
  /// effect was the GRDB serial queue saturating on `ExchangeRateRecord`
  /// inserts during chart renders against a populated cache.
  ///
  /// The test primes a cache of three rates, then drives one forward
  /// extension that adds one new (date, quote) row. With a delta-write
  /// implementation the `AFTER INSERT` counter sees exactly 1 — the new
  /// row. With the legacy delete-and-rewrite path it would see 4 (the
  /// three priming rows plus the new one).
  @Test
  func saveCacheWritesOnlyChangedRows() async throws {
    let database = try ProfileDatabase.openInMemory()
    let client = FixedRateClient(rates: [
      "2025-01-13": ["USD": dec("0.6480")],  // Mon
      "2025-01-14": ["USD": dec("0.6490")],  // Tue
      "2025-01-15": ["USD": dec("0.6500")],  // Wed
      "2025-01-20": ["USD": dec("0.6510")],  // Mon (one week later)
    ])
    let service = ExchangeRateService(client: client, database: database)

    // Prime cache with the three contiguous Jan dates.
    _ = try await service.rate(from: .AUD, to: .USD, on: try date("2025-01-13"))
    _ = try await service.rate(from: .AUD, to: .USD, on: try date("2025-01-15"))

    // Verify priming actually populated the rows we expect to be present.
    let primedCount = try await database.read { database in
      try ExchangeRateRecord
        .filter(ExchangeRateRecord.Columns.base == "AUD")
        .fetchCount(database)
    }
    #expect(primedCount >= 3)

    // Install the counter only AFTER priming so we measure just the
    // forward-extension save.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TABLE exchange_rate_write_counter (n INTEGER NOT NULL);
          INSERT INTO exchange_rate_write_counter (n) VALUES (0);
          CREATE TRIGGER count_exchange_rate_writes
          AFTER INSERT ON exchange_rate
          BEGIN
              UPDATE exchange_rate_write_counter SET n = n + 1;
          END;
          """)
    }

    // Forward extension: client returns one new date for [Jan 16, Jan 20]
    // — Jan 20. Merge adds exactly one (date, quote) row. saveCache must
    // write only that one row, not re-insert the whole cache.
    _ = try await service.rate(from: .AUD, to: .USD, on: try date("2025-01-20"))

    let writes = try await database.read { database in
      try Int.fetchOne(database, sql: "SELECT n FROM exchange_rate_write_counter") ?? -1
    }
    #expect(writes == 1)
  }
}
