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

  /// Rollback contract: the service's save path is a single
  /// `database.write` transaction (delete prior rows + re-insert + upsert
  /// meta). If any statement inside the transaction throws, prior state
  /// must survive untouched. This test seeds a successful save through the
  /// service, then runs a write that mirrors the same shape but trips a
  /// `PRIMARY KEY` constraint mid-transaction; the prior rows must remain.
  ///
  /// Mirrors `SQLiteCoinGeckoCatalogStorageTests.replaceAllRollsBackOnConstraintFailure`.
  @Test
  func saveRollsBackOnConstraintFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let primingClient = FixedRateClient(rates: [
      "2025-01-10": ["USD": dec("0.6400"), "EUR": dec("0.5900")]
    ])
    let service = ExchangeRateService(client: primingClient, database: database)
    _ = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-10"))
    _ = try await service.rate(from: .AUD, to: .USD, on: date("2025-01-10"))
    _ = try await service.rate(
      from: .AUD, to: Instrument.fiat(code: "EUR"), on: date("2025-01-10"))

    // Sanity: rows landed.
    let beforeCount = try await database.read { database in
      try ExchangeRateRecord
        .filter(ExchangeRateRecord.Columns.base == "AUD")
        .fetchCount(database)
    }
    #expect(beforeCount >= 2)

    // Force a constraint violation inside the same transaction shape that
    // `saveCache` uses: delete prior rows for AUD, re-insert one, then
    // re-insert a duplicate (base, date, quote) — the second insert trips
    // the PK and the whole transaction must roll back.
    await #expect(throws: (any Error).self) {
      try await database.write { database in
        try ExchangeRateRecord
          .filter(ExchangeRateRecord.Columns.base == "AUD")
          .deleteAll(database)
        try ExchangeRateRecord(base: "AUD", quote: "USD", date: "2026-01-01", rate: 0.5)
          .insert(database)
        try ExchangeRateRecord(base: "AUD", quote: "USD", date: "2026-01-01", rate: 0.6)
          .insert(database)
      }
    }

    // Prior state survived: original rows are still in the table, the
    // failed transaction's deletes did not commit.
    let afterCount = try await database.read { database in
      try ExchangeRateRecord
        .filter(ExchangeRateRecord.Columns.base == "AUD")
        .fetchCount(database)
    }
    #expect(afterCount == beforeCount)
  }
}
