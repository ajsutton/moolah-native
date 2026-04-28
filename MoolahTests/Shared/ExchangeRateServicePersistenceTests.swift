// MoolahTests/Shared/ExchangeRateServicePersistenceTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Persistence tests live in their own suite so the main behavioural suite
/// (`ExchangeRateServiceTests`) stays under the `type_body_length` cap.
/// Covers the SQL save/load round-trip and the multi-statement rollback
/// contract for `ExchangeRateService.saveCache`.
@Suite("ExchangeRateService — Persistence")
struct ExchangeRateServicePersistenceTests {
  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    // swiftlint:disable:next force_unwrapping
    return formatter.date(from: string)!
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
    let rate = try await service.rate(from: .AUD, to: .USD, on: date("2026-04-11"))
    #expect(rate == dec("0.632"))

    // New service reading from the same database (fresh in-memory state)
    let failingClient = FixedRateClient(shouldFail: true)
    let service2 = ExchangeRateService(client: failingClient, database: database)

    // Should load from the SQL cache, not network
    let cachedRate = try await service2.rate(from: .AUD, to: .USD, on: date("2026-04-11"))
    #expect(approximatelyEqual(cachedRate, dec("0.632")))

    let cachedEur = try await service2.rate(
      from: .AUD, to: Instrument.fiat(code: "EUR"), on: date("2026-04-11"))
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

  /// Rollback contract: `ExchangeRateService.saveCache` is a single
  /// `database.write` transaction (delete prior rows + re-insert + upsert
  /// meta). If any statement inside the transaction throws, prior state
  /// must survive untouched.
  ///
  /// To drive the **production** save path (rather than asserting on a
  /// hand-rolled mirror of `saveCache`'s shape), this test installs a
  /// SQLite `BEFORE INSERT` trigger that raises `ABORT` whenever a
  /// sentinel quote (`"___FAIL___"`) is inserted. A second fetch through
  /// the service yields a rate set containing that sentinel, which makes
  /// the real `saveCache` throw mid-transaction. Prior rows must remain
  /// because SQLite rolls the transaction back atomically.
  @Test
  func saveCacheRollsBackOnInsertFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    // Pick a specific (date, quote, rate) triple we can re-look-up after
    // the failed save so the assertion proves the DELETE was rolled back
    // — not just that the row count happens to match.
    let primingClient = FixedRateClient(rates: [
      "2026-04-07": ["USD": dec("1.234"), "EUR": dec("0.5900")]
    ])
    let service = ExchangeRateService(client: primingClient, database: database)
    _ = try await service.rate(from: .AUD, to: .USD, on: date("2026-04-07"))
    _ = try await service.rate(
      from: .AUD, to: Instrument.fiat(code: "EUR"), on: date("2026-04-07"))

    // Sanity: rows landed via the production save path.
    let beforeCount = try await database.read { database in
      try ExchangeRateRecord
        .filter(ExchangeRateRecord.Columns.base == "AUD")
        .fetchCount(database)
    }
    #expect(beforeCount >= 2)

    // Install a trigger that aborts any insert with the sentinel quote.
    // The trigger fires inside `saveCache`'s transaction so the entire
    // save (including the upfront DELETE for the AUD partition) must
    // roll back together.
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

    // Drive the real `saveCache` by feeding a new rate set whose payload
    // contains the sentinel quote. The service's save path executes the
    // same delete-then-reinsert sequence as in production; the trigger
    // raises mid-transaction, so the whole disk write must roll back.
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
      from: .AUD, to: Instrument.fiat(code: "___FAIL___"), on: date("2025-02-15"))

    // Prior state survived: row count matches AND the specific priming
    // row is still present. The exact-row probe defends against future
    // regressions where `saveCache` might switch to upsert-only (no
    // DELETE) — the count would then match for the wrong reason. Asking
    // for the (AUD, USD, 2026-04-07) rate by value proves the original
    // insert survived the rollback.
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
}
