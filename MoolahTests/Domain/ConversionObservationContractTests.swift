import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("InstrumentConversionService.observeRates contract")
struct ConversionObservationContractTests {

  enum CacheTable: String, CaseIterable, Sendable {
    case exchangeRate = "exchange_rate"
    case stockPrice = "stock_price"
    case cryptoPrice = "crypto_price"
  }

  /// Writes one minimum-viable row into a named cache table using a SQL
  /// literal (per `DATABASE_CODE_GUIDE.md` — `db.execute(sql:)` with a
  /// String variable is forbidden; only `literal:` accepts user-tracked
  /// SQL safely). Mirrors the column names defined in
  /// `Backends/GRDB/ProfileSchema+RateCaches.swift`.
  ///
  /// Each branch follows the production write contract for `WITHOUT ROWID`
  /// rate-cache tables: insert, then `notifyRateCacheChange(...)` so the
  /// `ValueObservation` region sees the write. Without the notify the
  /// SQLite update hook never fires for these tables and every
  /// `observeRates()` subscriber would hang on the initial tick. See
  /// `Backends/GRDB/Observation/RateCacheTable.swift`.
  private static func write(_ table: CacheTable, into database: any DatabaseWriter) async throws {
    try await database.write { database in
      switch table {
      case .exchangeRate:
        try database.execute(literal: insertExchangeRateFixture())
        try database.notifyRateCacheChange(.exchangeRate)
      case .stockPrice:
        try database.execute(literal: insertStockPriceFixture())
        try database.notifyRateCacheChange(.stockPrice)
      case .cryptoPrice:
        try database.execute(literal: insertCryptoPriceFixture())
        try database.notifyRateCacheChange(.cryptoPrice)
      }
    }
  }

  @Test("write to cache table emits a tick", arguments: CacheTable.allCases)
  func writeEmitsTick(table: CacheTable) async throws {
    let (backend, database) = try TestBackend.create()
    var iterator = backend.conversionService.observeRates().makeAsyncIterator()
    _ = await iterator.next()  // initial tick on subscription

    try await Self.write(table, into: database)

    let next: Void? = await iterator.next()
    #expect(next != nil, "observeRates() did not emit after writing to \(table.rawValue)")
  }

  @Test("subscribes-before-data still emits on first write", arguments: CacheTable.allCases)
  func subscribeBeforeDataEmits(table: CacheTable) async throws {
    // Catches the empty-table region-inference bug: if the implementation
    // used `tracking { db in /* SELECT 1 FROM table LIMIT 1 */ }`, the
    // table would only register on first row access — so a fresh-install
    // profile (empty cache tables) never emits on the first sync write.
    // The fix is `tracking(regions:)` with an explicit table list. This
    // test catches a regression to the inference form.
    let (backend, database) = try TestBackend.create()  // empty cache tables
    var iterator = backend.conversionService.observeRates().makeAsyncIterator()
    _ = await iterator.next()  // initial tick

    try await Self.write(table, into: database)

    let next: Void? = await iterator.next()
    #expect(
      next != nil,
      "observeRates() missed the first write to \(table.rawValue) (empty-table region bug)")
  }

  @Test("observeErrors stays quiet on healthy service")
  func observeErrorsQuiet() async throws {
    // Mirrors `AccountRepoObservationContractTests.observeErrorsOnHealthyRepository`:
    // we have no clean way to inject a programmer-bug into the live
    // service from the contract layer (the bridge unit tests in Stage 1
    // cover error propagation); this test asserts only that
    // `observeErrors()` is callable and that, on a healthy service, the
    // stream stays quiet for at least a short grace window. Cancelling
    // the polling `Task` is what makes the iterator return promptly —
    // the `AsyncStream`'s `onTermination` tears down the inner channel.
    let (backend, _) = try TestBackend.create()
    let stream = backend.conversionService.observeErrors()
    let pollTask = Task<(any Error)?, Never> {
      var iterator = stream.makeAsyncIterator()
      return await iterator.next()
    }
    try await Task.sleep(for: .milliseconds(100))
    pollTask.cancel()
    let surfaced = await pollTask.value
    #expect(surfaced == nil)
  }
}

// MARK: - SQL literal fixtures
//
// File-scope (not nested in the suite) so other test suites that need
// to write into the same cache tables — notably the upcoming
// `AccountStoreSyncRefreshTests.convertedTotalRecomputesOnRateTick` —
// can reuse the same fixture helpers without duplicating the column
// list. Marked `internal` (default) so the test target shares them
// without needing a re-export.

func insertExchangeRateFixture() -> SQL {
  """
  INSERT INTO exchange_rate (base, quote, date, rate)
  VALUES ('USD', 'AUD', '2026-05-06', 1.5)
  """
}

func insertStockPriceFixture() -> SQL {
  """
  INSERT INTO stock_price (ticker, date, price)
  VALUES ('AAPL', '2026-05-06', 180.0)
  """
}

func insertCryptoPriceFixture() -> SQL {
  """
  INSERT INTO crypto_price (token_id, date, price_usd)
  VALUES ('bitcoin', '2026-05-06', 60000.0)
  """
}
