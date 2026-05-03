// MoolahTests/Shared/StockPriceServicePersistenceTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Persistence tests live in their own suite so the main behavioural
/// suite (`StockPriceServiceTests`) stays under SwiftLint's
/// `type_body_length` and `file_length` caps. Covers the SQL save/load
/// round-trip, the rollback contract for `StockPriceService.persistDelta`,
/// and the delta-write semantics that keep chart renders off the GRDB
/// serial queue.
@Suite("StockPriceService — Persistence")
struct StockPriceServicePersistenceTests {
  private func makeService(
    responses: [String: StockPriceResponse] = [:],
    shouldFail: Bool = false,
    database: DatabaseQueue? = nil
  ) throws -> StockPriceService {
    let client = FixedStockPriceClient(responses: responses, shouldFail: shouldFail)
    let resolved = try database ?? ProfileDatabase.openInMemory()
    return StockPriceService(client: client, database: resolved)
  }

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  private func bhpResponse() -> StockPriceResponse {
    StockPriceResponse(
      instrument: .AUD,
      prices: [
        "2026-04-07": dec("38.50"),
        "2026-04-08": dec("38.75"),
        "2026-04-09": dec("39.00"),
        "2026-04-10": dec("38.25"),
        "2026-04-11": dec("38.60"),
      ])
  }

  // MARK: - Disk persistence (SQL round-trip)

  /// Two service instances sharing the same `DatabaseQueue` — the second
  /// must load prices and the discovered denomination persisted by the
  /// first without going to the network.
  @Test
  func sqlRoundTripPreservesData() async throws {
    let database = try ProfileDatabase.openInMemory()

    let service1 = try makeService(responses: ["BHP.AX": bhpResponse()], database: database)
    let price = try await service1.price(ticker: "BHP.AX", on: try date("2026-04-07"))
    #expect(price == dec("38.50"))

    let service2 = try makeService(shouldFail: true, database: database)
    let cachedPrice = try await service2.price(ticker: "BHP.AX", on: try date("2026-04-07"))
    #expect(cachedPrice == dec("38.50"))

    let instrument = try await service2.instrument(for: "BHP.AX")
    #expect(instrument == .AUD)
  }

  // MARK: - Rollback for multi-statement save

  /// Rollback contract: `StockPriceService.persistDelta` writes the
  /// delta rows (`INSERT OR REPLACE`) plus the meta row inside a single
  /// `database.write` transaction. If any statement throws, every
  /// statement in the same closure must roll back together so prior
  /// rows survive untouched.
  ///
  /// Drives the **production** save path by installing a trigger that
  /// raises `ABORT` on a sentinel date. A second fetch through the
  /// service merges that sentinel, `persistDelta` writes the row, the
  /// trigger aborts mid-transaction, and SQLite rolls the meta insert
  /// back along with it.
  @Test
  func saveCacheRollsBackOnInsertFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let service = try makeService(responses: ["BHP.AX": bhpResponse()], database: database)
    _ = try await service.price(ticker: "BHP.AX", on: try date("2026-04-07"))

    let beforeCount = try await database.read { database in
      try StockPriceRecord
        .filter(StockPriceRecord.Columns.ticker == "BHP.AX")
        .fetchCount(database)
    }
    #expect(beforeCount > 0)

    // Install a trigger that aborts inserts carrying the sentinel date.
    // The trigger fires inside `persistDelta`'s transaction so the
    // failed `INSERT OR REPLACE` and the meta insert roll back together.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_save_cache
          BEFORE INSERT ON stock_price
          WHEN NEW.date = '9999-12-31'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    // Drive the real `persistDelta` by feeding a price set that
    // contains the sentinel date. The service merges it in, calls
    // `persistDelta`, the trigger raises mid-transaction, and SQLite
    // rolls the whole write back atomically.
    let failingResponse = StockPriceResponse(
      instrument: .AUD, prices: ["9999-12-31": dec("99.99")])
    let failingService = try makeService(
      responses: ["BHP.AX": failingResponse], database: database)
    _ = try? await failingService.price(ticker: "BHP.AX", on: try date("9999-12-31"))

    let afterCount = try await database.read { database in
      try StockPriceRecord
        .filter(StockPriceRecord.Columns.ticker == "BHP.AX")
        .fetchCount(database)
    }
    #expect(afterCount == beforeCount)

    // Probe a specific priming row to prove the original insert
    // survived the aborted transaction. The exact-row check matters
    // because `persistDelta` is upsert-only (no DELETE), so a row-count
    // assertion alone would pass even if the rollback hadn't fired.
    // Re-looking-up `(BHP.AX, 2026-04-07, 38.50)` by value proves the
    // original write is intact.
    let surviving = try await database.read { database in
      try StockPriceRecord
        .filter(StockPriceRecord.Columns.ticker == "BHP.AX")
        .filter(StockPriceRecord.Columns.date == "2026-04-07")
        .fetchOne(database)
    }
    #expect(surviving != nil)
    #expect(surviving?.price == 38.50)
  }

  // MARK: - Persistence efficiency

  /// `fetchAndMerge` must skip persistence when the network call returns
  /// no prices — there is nothing new to write. Without this guard the
  /// pre-fix code rewrote every cached row for the ticker on every
  /// out-of-range probe, saturating the GRDB serial queue during chart
  /// renders. We detect the unwanted write with an `AFTER INSERT ON
  /// stock_price` counter trigger installed after priming.
  @Test
  func emptyFetchResultDoesNotRewriteCache() async throws {
    let database = try ProfileDatabase.openInMemory()
    let service = try makeService(
      responses: [
        "BHP.AX": StockPriceResponse(
          instrument: .AUD, prices: ["2026-04-07": dec("38.50")])
      ],
      database: database)
    _ = try await service.price(ticker: "BHP.AX", on: try date("2026-04-07"))

    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TABLE stock_price_write_counter (n INTEGER NOT NULL);
          INSERT INTO stock_price_write_counter (n) VALUES (0);
          CREATE TRIGGER count_stock_price_writes
          AFTER INSERT ON stock_price
          BEGIN
              UPDATE stock_price_write_counter SET n = n + 1;
          END;
          """)
    }

    // Forward extension: client returns nothing for [Apr 8, Apr 15].
    // `price()` falls through to `fallbackPrice` (Apr 7's 38.50). With
    // the bug, `persistDelta` runs and the counter increments. With the
    // fix, `fetchAndMerge`'s empty-payload guard skips it.
    let price = try await service.price(ticker: "BHP.AX", on: try date("2026-04-15"))
    #expect(price == dec("38.50"))

    let writes = try await database.read { database in
      try Int.fetchOne(database, sql: "SELECT n FROM stock_price_write_counter") ?? -1
    }
    #expect(writes == 0)
  }

  /// `persistDelta` must persist only the rows the latest fetch added or
  /// changed — not the entire ticker partition. The pre-fix
  /// implementation deleted every cached row for the ticker and
  /// re-inserted them one by one, paying O(N) inserts per single-day
  /// extension. After the fix a single new (date) row writes exactly one
  /// row.
  @Test
  func saveCacheWritesOnlyChangedRows() async throws {
    let database = try ProfileDatabase.openInMemory()
    let service = try makeService(
      responses: [
        "BHP.AX": StockPriceResponse(
          instrument: .AUD,
          prices: [
            "2026-04-07": dec("38.50"),
            "2026-04-08": dec("38.75"),
            "2026-04-09": dec("39.00"),
            "2026-04-15": dec("39.20"),
          ])
      ],
      database: database)

    // Prime cache with the three contiguous dates.
    _ = try await service.price(ticker: "BHP.AX", on: try date("2026-04-07"))
    _ = try await service.price(ticker: "BHP.AX", on: try date("2026-04-09"))

    // Sanity: priming wrote at least the three rows we expect.
    let primedCount = try await database.read { database in
      try StockPriceRecord
        .filter(StockPriceRecord.Columns.ticker == "BHP.AX")
        .fetchCount(database)
    }
    #expect(primedCount >= 3)

    // Install the counter only after priming so we measure just the
    // forward-extension save.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TABLE stock_price_write_counter (n INTEGER NOT NULL);
          INSERT INTO stock_price_write_counter (n) VALUES (0);
          CREATE TRIGGER count_stock_price_writes
          AFTER INSERT ON stock_price
          BEGIN
              UPDATE stock_price_write_counter SET n = n + 1;
          END;
          """)
    }

    // Forward extension: client returns one new date for [Apr 10, Apr 15]
    // — Apr 15. The delta is a single (ticker, date) row.
    _ = try await service.price(ticker: "BHP.AX", on: try date("2026-04-15"))

    let writes = try await database.read { database in
      try Int.fetchOne(database, sql: "SELECT n FROM stock_price_write_counter") ?? -1
    }
    #expect(writes == 1)
  }
}
